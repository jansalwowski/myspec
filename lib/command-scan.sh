#!/usr/bin/env bash
# command-scan.sh
# Shared helpers for PreToolUse Bash hooks that need to decide "does this
# command RUN X?" rather than "does this string CONTAIN X?".
#
# The distinction is the whole point. A substring match fires on a verb inside
# a commit message, a PR body, or doc prose in a heredoc, and blocks a command
# that mutates nothing. Sourced by guard-worktree-context.sh and
# mark-code-changed.sh so the two cannot drift apart.
#
# Public API:
#   sanitize_command <<< "$cmd"        # blanks quoted spans + heredoc bodies
#   sanitize_command keep <<< "$cmd"   # same shape, quoted text kept (encoded)
#   split_segments                     # one "<sep><TAB><segment>" line each
#   decode_word "$word"                # undoes the keep-mode encoding
#   strip_command_prefix "$segment"    # drops then/do/else, FOO=bar, sudo
#   decode_word_to VAR "$word"         # the same two, into VAR: no subshell
#   strip_command_prefix_to VAR "$segment"
#   find_matching_segment "$cmd" pattern...   # echoes offending segment, if any
#
# A double-quoted word is one span however its quoting nests: `"$(printf '%s'
# "a > b")"`, `"${x:-"y"}"` and backticks in it pair their inner quotes, at any
# depth (#382). The span is still opaque: a command substitution inside double
# quotes is not analysed as command text, so `"$(git branch -D x)"` does not
# match a verb pattern. An unquoted `$( … )` is split open like a subshell.

# Blank out every span whose contents can never be a command: single-quoted
# spans, double-quoted spans, escaped characters, and heredoc bodies. Each
# becomes a placeholder token, so separators inside them (`;`, `&&`) cannot
# split a segment open and expose their text as a command position.
#
# `keep` mode is for reading ARGUMENTS (a `cd` target, a `bash -c` payload),
# never for matching verbs. It keeps each quoted span's text instead of the Q
# placeholder, but encodes whitespace and separator characters inside it as
# control bytes and prefixes the span with \035. Both modes therefore split
# into the same segments and the same words, so word N of a segment in one
# stream is word N in the other; decode_word turns an encoded word back into
# its text.
# shellcheck disable=SC2120 # the keep argument is optional; the hooks that source this pass it
sanitize_command() {
  awk -v keep="${1:-}" '
    function enc(ch) {
      if (ch == " " || ch == "\t") return "\037"
      if (ch == "\n") return "\036"
      if (ch == "|") return "\021"
      if (ch == "&") return "\022"
      if (ch == ";") return "\023"
      if (ch == "(") return "\024"
      if (ch == ")") return "\025"
      if (ch == "{") return "\026"
      if (ch == "}") return "\027"
      if (ch == "`") return "\030"
      return ch
    }
    # has_term(s, from, term): a line after <from> is <term>, trimmed.
    function has_term(s, from, term,    rest, ln, m, q) {
      rest = substr(s, from)
      m = split(rest, ln, "\n")
      for (q = 2; q <= m; q++) {
        gsub(/^[ \t]+|[ \t]+$/, "", ln[q])
        if (ln[q] == term) return 1
      }
      return 0
    }
    # heredoc_at(i): the `<<` at <i> opens a heredoc. Sets HT to its
    # terminator and HJ to the index after the marker. A bare `<<` with no
    # word is a shift operator, not a heredoc; so is `a << b` in arithmetic
    # when no line ends the body.
    function heredoc_at(i,    j, d, spaced) {
      j = i + 2
      if (substr(buf, j, 1) == "-") { j++ }
      spaced = 0
      while (substr(buf, j, 1) == " " || substr(buf, j, 1) == "\t") { j++; spaced = 1 }
      d = substr(buf, j, 1)
      HT = ""
      if (d == "'"'"'" || d == "\"") {
        j++
        while (j <= n && substr(buf, j, 1) != d) { HT = HT substr(buf, j, 1); j++ }
        j++
      } else {
        if (d == "\\") { j++ }
        while (j <= n && substr(buf, j, 1) ~ /[A-Za-z0-9_]/) { HT = HT substr(buf, j, 1); j++ }
      }
      HJ = j
      return !(HT == "" || (spaced && !has_term(buf, j, HT)))
    }
    # add(s): appends <s>, encoded, to the keep-mode span. The blanking
    # mode prints Q for the whole span, so it collects nothing.
    function add(s,    k, m) {
      if (keep == "") return
      m = length(s)
      for (k = 1; k <= m; k++) span = span enc(substr(s, k, 1))
    }
    # The skip_* functions walk one quoted or substituted construct from
    # just after its opener and return the index after its closer, adding
    # its text to span. Quoting nests through $( ), ${ } and backticks,
    # so a `"` inside `"$(… "…" …)"` opens an inner span instead of closing
    # the outer one, at any depth (#382). <raw> keeps a backslash before
    # the character it escapes; the outermost double-quoted span drops it.
    function skip_dq(i, raw,    c) {
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == "\"") { if (raw) add(c); return i + 1 }
        if (c == "\\") {
          if (raw) add(c)
          add(substr(buf, i + 1, 1)); i += 2; continue
        }
        if (c == "$" && substr(buf, i + 1, 1) == "(") { add("$("); i = skip_sub(i + 2, ")", 0); continue }
        if (c == "$" && substr(buf, i + 1, 1) == "{") { add("${"); i = skip_sub(i + 2, "}", 1); continue }
        if (c == "`") { add(c); i = skip_bq(i + 1); continue }
        add(c); i++
      }
      return i
    }
    # skip_bq(i): a backtick substitution ends at the next unescaped backtick.
    function skip_bq(i,    c) {
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == "\\") { add(substr(buf, i, 2)); i += 2; continue }
        add(c); i++
        if (c == "`") return i
      }
      return i
    }
    # skip_sub(i, closer, indq): the body of $( ) (closer ")", which also
    # covers $(( ))) or ${ } (closer "}"). Inside $( ) the full quoting
    # applies again: single quotes, comments and heredoc bodies. A ${ }
    # inside double quotes (<indq>) leaves a single quote literal.
    function skip_sub(i, closer, indq,    c, open, depth, base, p, k, line, prev) {
      open = (closer == ")") ? "(" : "{"
      depth = 0
      base = hn
      prev = " "
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == "\\") { add(substr(buf, i, 2)); i += 2; prev = "x"; continue }
        if (c == "\"") { add(c); i = skip_dq(i + 1, 1); prev = "x"; continue }
        if (c == "'"'"'" && !indq) {
          add(c); i++
          while (i <= n && substr(buf, i, 1) != "'"'"'") { add(substr(buf, i, 1)); i++ }
          if (i <= n) { add(c); i++ }
          prev = "x"
          continue
        }
        if (c == "`") { add(c); i = skip_bq(i + 1); prev = "x"; continue }
        if (c == "$" && substr(buf, i + 1, 1) == "(") { add("$("); i = skip_sub(i + 2, ")", 0); prev = "x"; continue }
        if (c == "$" && substr(buf, i + 1, 1) == "{") { add("${"); i = skip_sub(i + 2, "}", 0); prev = "x"; continue }
        if (closer == ")") {
          if (c == "#" && index(" \t\n;|&(", prev) > 0) {
            while (i <= n && substr(buf, i, 1) != "\n") { add(substr(buf, i, 1)); i++ }
            continue
          }
          if (substr(buf, i, 3) == "<<<") { add("<<<"); i += 3; prev = "x"; continue }
          if (substr(buf, i, 2) == "<<" && heredoc_at(i)) {
            hp[++hn] = HT
            add(substr(buf, i, HJ - i)); i = HJ; prev = "x"
            continue
          }
          if (c == "\n" && hn > base) {
            add(c); i++
            for (p = base + 1; p <= hn; p++) {
              while (i <= n) {
                k = i
                while (k <= n && substr(buf, k, 1) != "\n") { k++ }
                line = substr(buf, i, k - i)
                add(substr(buf, i, k - i + 1))
                i = k + 1
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line == hp[p]) { break }
              }
            }
            hn = base
            prev = "\n"
            continue
          }
        }
        if (c == closer) {
          if (depth == 0) { add(c); hn = base; return i + 1 }
          depth--
        } else if (c == open) {
          depth++
        }
        add(c); i++; prev = c
      }
      hn = base
      return i
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf)
      i = 1
      out = ""
      while (i <= n) {
        c = substr(buf, i, 1)

        if (c == "\\") { out = out " "; i += 2; continue }

        if (c == "'"'"'") {
          i++
          span = ""
          while (i <= n && substr(buf, i, 1) != "'"'"'") { span = span enc(substr(buf, i, 1)); i++ }
          i++
          if (keep != "") { out = out "\035" span } else { out = out "Q" }
          continue
        }

        if (c == "\"") {
          span = ""
          i = skip_dq(i + 1, 0)
          if (keep != "") { out = out "\035" span } else { out = out "Q" }
          continue
        }

        # A here-string (`<<<word`) has no body.
        if (substr(buf, i, 3) == "<<<") { out = out "<<<"; i += 3; continue }

        # A heredoc marker becomes Q and the rest of its line is scanned like
        # any other text, so a redirect or pipe after the marker (`cat <<EOF
        # > f`, `cat <<EOF | tee f`) is still seen. The body is skipped at
        # the end of the line, one per pending marker, in order.
        if (substr(buf, i, 2) == "<<") {
          if (!heredoc_at(i)) { out = out c; i++; continue }
          pend[++npend] = HT
          out = out " Q "
          i = HJ
          continue
        }

        if (c == "\n" && npend > 0) {
          out = out "\n"
          j = i + 1
          for (p = 1; p <= npend; p++) {
            while (j <= n) {
              line = ""
              k = j
              while (k <= n && substr(buf, k, 1) != "\n") { line = line substr(buf, k, 1); k++ }
              gsub(/^[ \t]+|[ \t]+$/, "", line)
              j = k + 1
              if (line == pend[p]) { break }
            }
          }
          npend = 0
          i = j
          continue
        }

        out = out c
        i++
      }
      print out
    }
  '
}

# Reads sanitized text on stdin and prints one line per command segment:
# the separator that opened it, a TAB, then the segment. The separator is `(`
# or `)` for a subshell boundary (a caller tracking `cd` scopes pushes and pops
# on them), `^` for the first segment, and `|` for every other separator
# (`|`, `&`, `;`, `{`, `}`, backtick, newline). Splits exactly where
# find_matching_segment's `tr` does, so both see the same segments.
split_segments() {
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf)
      sep = "^"
      cur = ""
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        # `>|` (clobber) is a redirect, not a pipe: drop the bar so the
        # target stays in the segment as `> file`.
        if (c == "|" && i > 1 && substr(buf, i - 1, 1) == ">") continue
        if (index("|&;(){}`\n", c) > 0) {
          print sep "\t" cur
          cur = ""
          if (c == "(" || c == ")") { sep = c } else { sep = "|" }
          continue
        }
        cur = cur c
      }
      print sep "\t" cur
    }
  '
}

# decode_word <word> — the text of a word from `sanitize_command keep`.
decode_word() {
  local _dw
  decode_word_to _dw "$1"
  printf '%s' "$_dw"
}

# decode_word_to <var> <word> — decode_word into <var>. Parameter expansion,
# not `tr`: a hook decodes every operand of a long command, and a pipeline
# per word cost seconds on a 200-statement one (#277).
decode_word_to() {
  local _dw_w="$2"
  # Every replacement is quoted: from bash 5.2 an unquoted & in it stands
  # for the matched text (patsub_replacement), and a backslash escapes.
  _dw_w=${_dw_w//$'\037'/' '}
  _dw_w=${_dw_w//$'\036'/$'\n'}
  _dw_w=${_dw_w//$'\021'/'|'}
  _dw_w=${_dw_w//$'\022'/'&'}
  _dw_w=${_dw_w//$'\023'/';'}
  _dw_w=${_dw_w//$'\024'/'('}
  _dw_w=${_dw_w//$'\025'/')'}
  _dw_w=${_dw_w//$'\026'/'{'}
  _dw_w=${_dw_w//$'\027'/'}'}
  _dw_w=${_dw_w//$'\030'/'`'}
  _dw_w=${_dw_w//$'\035'/}
  printf -v "$1" '%s' "$_dw_w"
}

# Strips whatever can precede a command name without changing which command
# runs: leading whitespace, `then`/`do`/`else`, env assignments, and `sudo`.
# Done in bash rather than sed — BSD sed rejects inline labels (`:a; ...; ta`)
# and lacks `\b`, so the portable sed for this is unreadable.
strip_command_prefix() {
  local _sp
  strip_command_prefix_to _sp "$1"
  printf '%s' "$_sp"
}

# strip_command_prefix_to <var> <segment> — strip_command_prefix into <var>,
# for a caller looping over every segment of a command.
# Its locals carry a _scp_ prefix so no <var> a caller picks is shadowed.
strip_command_prefix_to() {
  local _scp_seg="$2" _scp_prev=""

  while [ "$_scp_seg" != "$_scp_prev" ]; do
    _scp_prev="$_scp_seg"
    _scp_seg="${_scp_seg#"${_scp_seg%%[![:space:]]*}"}"

    if [[ "$_scp_seg" =~ ^(then|do|else)[[:space:]]+(.*)$ ]]; then
      _scp_seg="${BASH_REMATCH[2]}"
    fi

    if [[ "$_scp_seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; then
      _scp_seg="${BASH_REMATCH[1]}"
    fi

    if [[ "$_scp_seg" =~ ^sudo[[:space:]]+(.*)$ ]]; then
      _scp_seg="${BASH_REMATCH[1]}"
    fi
  done

  printf -v "$1" '%s' "$_scp_seg"
}

# find_matching_segment <command> <pattern>...
# Echoes the first command segment matching any pattern; empty output = clean.
# Patterns are anchored extended regexes tested against the segment's start.
find_matching_segment() {
  local command="$1"
  shift
  local sanitized segment pattern

  # `tr` maps each separator character to a newline, so `&&` and `||` split the
  # same way single separators do.
  # shellcheck disable=SC2119,SC2020 # blanking mode takes no argument; tr maps each separator character to a newline, as intended
  sanitized=$(printf '%s' "$command" | sanitize_command | tr '|&;(){}`' '\n\n\n\n\n\n\n\n')

  while IFS= read -r segment; do
    strip_command_prefix_to segment "$segment"

    # [[ =~ ]] is the same POSIX ERE as `grep -E`, without a process per
    # segment and pattern.
    for pattern in "$@"; do
      if [[ "$segment" =~ $pattern ]]; then
        printf '%s' "$segment"
        return 0
      fi
    done
  done <<EOF
$sanitized
EOF

  return 0
}
