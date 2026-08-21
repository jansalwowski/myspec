#!/usr/bin/env bash
# command-scan.sh
# Shared helpers for PreToolUse Bash hooks that need to decide "does this
# command RUN X?" rather than "does this string CONTAIN X?".
#
# The distinction is the whole point. A substring match fires on a verb inside
# a commit message, a PR body, or doc prose in a heredoc, and blocks a command
# that mutates nothing. Sourced by guard-git-branch.sh and
# guard-worktree-context.sh so the two cannot drift apart.
#
# Public API:
#   sanitize_command <<< "$cmd"        # blanks quoted spans + heredoc bodies
#   strip_command_prefix "$segment"    # drops then/do/else, FOO=bar, sudo
#   find_matching_segment "$cmd" pattern...   # echoes offending segment, if any

# Blank out every span whose contents can never be a command: single-quoted
# spans, double-quoted spans, escaped characters, and heredoc bodies. Each
# becomes a placeholder token, so separators inside them (`;`, `&&`) cannot
# split a segment open and expose their text as a command position.
sanitize_command() {
  awk '
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
          while (i <= n && substr(buf, i, 1) != "'"'"'") { i++ }
          i++
          out = out "Q"
          continue
        }

        if (c == "\"") {
          i++
          while (i <= n && substr(buf, i, 1) != "\"") {
            if (substr(buf, i, 1) == "\\") { i++ }
            i++
          }
          i++
          out = out "Q"
          continue
        }

        if (substr(buf, i, 2) == "<<") {
          j = i + 2
          if (substr(buf, j, 1) == "-") { j++ }
          delim = substr(buf, j, 1)
          term = ""
          if (delim == "'"'"'" || delim == "\"") {
            j++
            while (j <= n && substr(buf, j, 1) != delim) { term = term substr(buf, j, 1); j++ }
            j++
          } else {
            while (j <= n && substr(buf, j, 1) ~ /[A-Za-z0-9_]/) { term = term substr(buf, j, 1); j++ }
          }

          # A bare `<<` with no word is a shift operator, not a heredoc.
          if (term == "") { out = out c; i++; continue }

          while (j <= n && substr(buf, j, 1) != "\n") { j++ }
          j++

          while (j <= n) {
            line = ""
            k = j
            while (k <= n && substr(buf, k, 1) != "\n") { line = line substr(buf, k, 1); k++ }
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            j = k + 1
            if (line == term) { break }
          }

          out = out " Q "
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

# Strips whatever can precede a command name without changing which command
# runs: leading whitespace, `then`/`do`/`else`, env assignments, and `sudo`.
# Done in bash rather than sed — BSD sed rejects inline labels (`:a; ...; ta`)
# and lacks `\b`, so the portable sed for this is unreadable.
strip_command_prefix() {
  local segment="$1" previous=""

  while [ "$segment" != "$previous" ]; do
    previous="$segment"
    segment="${segment#"${segment%%[![:space:]]*}"}"

    if [[ "$segment" =~ ^(then|do|else)[[:space:]]+(.*)$ ]]; then
      segment="${BASH_REMATCH[2]}"
    fi

    if [[ "$segment" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; then
      segment="${BASH_REMATCH[1]}"
    fi

    if [[ "$segment" =~ ^sudo[[:space:]]+(.*)$ ]]; then
      segment="${BASH_REMATCH[1]}"
    fi
  done

  printf '%s' "$segment"
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
  sanitized=$(printf '%s' "$command" | sanitize_command | tr '|&;(){}`' '\n\n\n\n\n\n\n\n')

  while IFS= read -r segment; do
    segment=$(strip_command_prefix "$segment")

    for pattern in "$@"; do
      if printf '%s' "$segment" | grep -qE "$pattern"; then
        printf '%s' "$segment"
        return 0
      fi
    done
  done <<EOF
$sanitized
EOF

  return 0
}
