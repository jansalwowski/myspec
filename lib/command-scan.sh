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
#   split_segments                     # one "<link><TAB><segment>" line each
#   decode_word "$word"                # undoes the keep-mode encoding
#   strip_command_prefix "$segment"    # drops then/do/else, FOO=bar, sudo
#   decode_word_to VAR "$word"         # the same two, into VAR: no subshell
#   strip_command_prefix_to VAR "$segment"
#   find_matching_segment "$cmd" pattern...   # echoes offending segment, if any
#
# Quoting nests through command substitution, as in the shell: in `x="$(echo
# "a > b")"` the inner quotes pair up inside the `$( … )`, at any depth
# (#382). A `$( … )` or backtick substitution inside double quotes is split
# open like an unquoted one, so the command in it is still scanned
# (`"$(git branch -D x)"`, `"$(bash -c "…")"`), while its own quoted text is
# blanked. `$(( … ))` and the rest of the double-quoted word stay one span.

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
#
# Past MAXLVL nested quotes and substitutions the scan stops and prints the
# command with its quote characters blanked, every word exposed: it fails
# closed instead of recursing until awk crashes with no output.
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
    # A quoted span collects its text in span (keep mode only) and ends in
    # flush, which prints the placeholder: Q, or \035 and the encoded text.
    function addspan(ch) { if (keep != "") span = span enc(ch) }
    function flush() {
      if (keep != "") { out = out "\035" span } else { out = out "Q" }
      span = ""
    }
    # sq(i, esc): a single-quoted span from just after its quote; <esc> for
    # $'"'"'…'"'"', where a backslash escapes the next character.
    function sq(i, esc,    c) {
      span = ""
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == "'"'"'") { i++; break }
        if (esc && c == "\\") { addspan(c); i++; c = substr(buf, i, 1) }
        addspan(c)
        i++
      }
      flush()
      return i
    }
    # dq(i, lvl, nested): a double-quoted span from just after its quote.
    # A ${ } in it may hold a nested double-quoted span (<nested>: same
    # span, no placeholder of its own), and a single quote is literal
    # there. A $( ) or backtick substitution ends the span so far, is
    # printed and scanned as commands, and a new span starts after it.
    function dq(i, lvl, nested,    c, bd) {
      if (lvl > MAXLVL) { ovf = 1; return n + 1 }
      if (!nested) span = ""
      bd = 0
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == "\"") {
          if (bd == 0) { i++; break }
          addspan(c)
          i = dq(i + 1, lvl + 1, 1)
          if (ovf) return n + 1
          addspan(c)
          continue
        }
        if (c == "\\") { addspan(substr(buf, i + 1, 1)); i += 2; continue }
        if (c == "$" && substr(buf, i + 1, 2) == "((") { i = arith(i); continue }
        if ((c == "$" && substr(buf, i + 1, 1) == "(") || c == "`") {
          flush()
          if (c == "`") { out = out c; i = scan(i + 1, c, lvl + 1) }
          else { out = out "$("; i = scan(i + 2, ")", lvl + 1) }
          if (ovf) return n + 1
          out = out substr(buf, i, 1)
          i++
          continue
        }
        if (c == "$" && substr(buf, i + 1, 1) == "{") { bd++; addspan(c); addspan("{"); i += 2; continue }
        if (c == "}" && bd > 0) { bd-- }
        addspan(c)
        i++
      }
      if (!nested) flush()
      return i
    }
    # arith(i): $(( … )) inside double quotes stays in the span: `>` and
    # `<<` there are operators, not redirects.
    function arith(i,    c, d) {
      addspan("$")
      i++
      d = 0
      while (i <= n) {
        c = substr(buf, i, 1)
        addspan(c)
        i++
        if (c == "(") { d++ } else if (c == ")") { d--; if (d == 0) break }
      }
      return i
    }
    # scan(i, closer, lvl): command text from <i>, printed to out, up to
    # <closer> (")" for $( ), a backtick, or "" for the whole command).
    # Returns the index of the closer, which the caller prints. Inside $( )
    # a case pattern`s ")" is printed as ";" and a comment is dropped, so
    # neither closes the substitution early.
    function scan(i, closer, lvl,    c, depth, incase, b, j, spaced, delim, term, p, line, k) {
      if (lvl > MAXLVL) { ovf = 1; return n + 1 }
      depth = 0
      incase = 0
      while (i <= n) {
        c = substr(buf, i, 1)

        if (closer == "`" && c == "`") return i
        if (closer == ")") {
          b = (index(" \t\n;|&()", substr(buf, i - 1, 1)) > 0)
          if (b && substr(buf, i, 4) == "case" && substr(buf, i + 4, 1) ~ /[ \t\n]/) { incase++ }
          if (b && incase > 0 && substr(buf, i, 4) == "esac" && substr(buf, i + 4, 1) !~ /[A-Za-z0-9_]/) { incase-- }
          if (b && c == "#") {
            while (i <= n && substr(buf, i, 1) != "\n") { i++ }
            continue
          }
          if (c == "(") { depth++ }
          if (c == ")") {
            if (depth == 0 && incase == 0) return i
            if (depth == 0) { out = out ";"; i++; continue }
            depth--
          }
        }

        if (c == "\\") { out = out " "; i += 2; continue }

        if (c == "$" && substr(buf, i + 1, 1) == "'"'"'") { out = out c; i = sq(i + 2, 1); continue }
        if (c == "'"'"'") { i = sq(i + 1, 0); continue }

        if (c == "\"") {
          i = dq(i + 1, lvl + 1, 0)
          if (ovf) return n + 1
          continue
        }

        # A here-string (`<<<word`) has no body.
        if (substr(buf, i, 3) == "<<<") { out = out "<<<"; i += 3; continue }

        # A heredoc marker becomes Q and the rest of its line is scanned like
        # any other text, so a redirect or pipe after the marker (`cat <<EOF
        # > f`, `cat <<EOF | tee f`) is still seen. The body is skipped at
        # the end of the line, one per pending marker, in order, at any
        # substitution depth.
        if (substr(buf, i, 2) == "<<") {
          j = i + 2
          if (substr(buf, j, 1) == "-") { j++ }
          spaced = 0
          while (substr(buf, j, 1) == " " || substr(buf, j, 1) == "\t") { j++; spaced = 1 }
          delim = substr(buf, j, 1)
          term = ""
          if (delim == "'"'"'" || delim == "\"") {
            j++
            while (j <= n && substr(buf, j, 1) != delim) { term = term substr(buf, j, 1); j++ }
            j++
          } else {
            if (delim == "\\") { j++ }
            while (j <= n && substr(buf, j, 1) ~ /[A-Za-z0-9_]/) { term = term substr(buf, j, 1); j++ }
          }

          # A bare `<<` with no word is a shift operator, not a heredoc; so
          # is `a << b` in arithmetic when no line ends the body.
          if (term == "" || (spaced && !has_term(buf, j, term))) { out = out c; i++; continue }

          pend[++npend] = term
          out = out " Q "
          i = j
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
      return i
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf)
      MAXLVL = 100
      out = ""
      scan(1, "", 0)
      if (ovf) { out = buf; gsub(/["'"'"']/, " ", out) }
      print out
    }
  '
}

# Reads sanitized text on stdin and prints one line per command segment:
# "<link><TAB><segment>", where <link> is the separator in front of the
# segment, as written:
#   ^                 the first segment
#   && || | & ;       a list or pipeline operator
#   ( ) { } `         a subshell, group or backtick boundary (a caller
#                     tracking `cd` scopes pushes and pops on ( and ))
#   n                 a newline
#   r                 the & of a redirect (2>&1, >&2, &>, <&0): no link
#   +                 a split that is no link of its own: the second
#                     character of && || |&, or a newline right after
#                     && || | (the command continues on the next line)
# The segment after a + or r continues the command before it. Splits exactly
# where find_matching_segment's `tr` does, so both see the same segments, and
# the keep scan gives the same links as the plain one.
split_segments() {
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf)
      sep = "^"
      cur = ""
      glue = 0
      last = ""
      lastpos = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        # `>|` (clobber) is a redirect, not a pipe: drop the bar so the
        # target stays in the segment as `> file`.
        if (c == "|" && i > 1 && substr(buf, i - 1, 1) == ">") continue
        if (index("|&;(){}`\n", c) > 0) {
          print sep "\t" cur
          cur = ""
          p = (i > 1) ? substr(buf, i - 1, 1) : ""
          q = substr(buf, i + 1, 1)
          if (glue) { sep = "+"; glue = 0 }
          else if (c == "&" && (p == ">" || p == "<" || q == ">")) sep = "r"
          else if (c == "&" && q == "&") { sep = "&&"; glue = 1 }
          else if (c == "|" && q == "|") { sep = "||"; glue = 1 }
          else if (c == "|" && q == "&") { sep = "|"; glue = 1 }
          else if (c == "\n") {
            gap = substr(buf, lastpos + 1, i - lastpos - 1)
            if (lastpos > 0 && gap ~ /^[ \t]*$/ && (last == "&&" || last == "||" || last == "|")) sep = "+"
            else sep = "n"
          }
          else sep = c
          if (sep != "+") last = sep
          lastpos = i
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
