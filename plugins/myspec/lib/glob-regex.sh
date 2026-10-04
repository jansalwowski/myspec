#!/usr/bin/env bash
# glob-regex.sh
# The one compiler from a repo-relative settings glob to an anchored ERE.
# Sourced by hooks/verify-before-stop.sh (checks[].paths),
# hooks/mark-code-changed.sh (hooks.markCodeChanged.ignorePaths) and
# lib/worktree-provision.sh (isolation.provision.clean), so one glob means one
# thing in every setting. Source this file; do not execute it.
#
# Semantics (docs/stop-gate.md, "Globs"):
#   - a glob matches the whole repo-relative path, from the repository root:
#     `*.php` is a file at the root only, `**/*.php` one at any depth;
#   - `*` matches any run of characters within one path segment, `?` one
#     character other than `/`;
#   - `**` as a whole segment matches zero or more segments (`api/**` is
#     everything under api/, `a/**/b.ts` matches a/b.ts and a/x/y/b.ts);
#     `**` inside a segment (`src/**.ts`) is a plain `*`;
#   - a trailing `/` means everything under it (`api/` is `api/**`), and a
#     leading `./` is dropped;
#   - every other character is literal, `[`, `{`, `\`, `+` and `$` included:
#     there are no classes and no braces;
#   - an empty glob, an absolute one, or one with a `..` segment is unusable.
#
# glob_regex <glob> -> prints the ERE (`^...$`) for [[ =~ ]]; returns 1,
# printing nothing, when the glob is unusable.
glob_regex() {
  local g="$1" re="" c seg=1
  while [ "${g#./}" != "$g" ]; do g="${g#./}"; done
  case "$g" in ''|/*) return 1 ;; esac
  case "/$g/" in */../*) return 1 ;; esac
  case "$g" in */) g="$g**" ;; esac
  while [ -n "$g" ]; do
    # A whole-segment ** : the rest of the path, or any number of segments.
    if [ "$seg" -eq 1 ] && [ "$g" = '**' ]; then
      re="$re.*"
      break
    fi
    if [ "$seg" -eq 1 ] && [ "${g#'**/'}" != "$g" ]; then
      re="$re(.*/)?"
      g="${g#'**/'}"
      continue
    fi
    c="${g:0:1}"
    g="${g:1}"
    seg=0
    case "$c" in
      # A run of * inside a segment is one *.
      '*') while [ "${g:0:1}" = '*' ]; do g="${g:1}"; done; re="${re}[^/]*" ;;
      '?') re="${re}[^/]" ;;
      /) re="$re/"; seg=1 ;;
      # The ERE metacharacters, one backslash-quoted literal each: a bracket
      # expression matched none of them on bash 3.2 or 5 (PR #243 review).
      .|'['|\\|'('|')'|+|'{'|'}'|'|'|^|'$') re="$re\\$c" ;;
      *) re="$re$c" ;;
    esac
  done
  printf '^%s$\n' "$re"
}
