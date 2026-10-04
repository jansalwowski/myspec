#!/usr/bin/env bash
# ShellCheck the shell this plugin ships (#209): hooks/ and lib/, tests
# included. `bash -n` only proves a script parses; ShellCheck catches unused
# variables, quoting and $? mistakes. The plugins/myspec/ mirrors are skipped:
# sync-check.yml keeps them byte-identical, so linting them only doubles every
# finding.
#
# Runs at ShellCheck's default severity (style). Suppressions are inline
# `# shellcheck disable=SCxxxx # reason` directives, plus the .shellcheckrc in
# each tests/ directory for the assertion idioms the suites are written in.
#
# CI (.github/workflows/test.yml) runs it with a pinned, checksummed
# ShellCheck; .githooks/pre-commit checks staged scripts with whichever
# ShellCheck is on PATH.
#
# Before ShellCheck, one rule of its own (sigpipe_check below): in a script
# that sets pipefail, a pipeline whose consumer exits early (`head`,
# `grep -q`) where its status is used. The consumer stops reading, a
# producer still writing dies of SIGPIPE, and pipefail makes the pipeline's
# status the producer's 141: an `if` reads a match as a miss, and set -e
# exits mid-hook (#33, #249). Tests are exempt: their fixtures pipe short
# literals. Opt a line out with a trailing `# lint: sigpipe-ok`.
#
# Usage: scripts/lint-sh.sh [--sigpipe-only] [file...]
#        default: every *.sh in the trees above. --sigpipe-only runs the
#        SIGPIPE rule alone (no ShellCheck needed).
# Env:   SHELLCHECK  the binary to run (default: shellcheck)
# Exit:  ShellCheck's own (0 clean, 1 findings, 2+ usage or internal error);
#        1 when only the SIGPIPE rule found something.

set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 2
sc=${SHELLCHECK:-shellcheck}
sigpipe_only=0
if [ "${1:-}" = --sigpipe-only ]; then
  sigpipe_only=1
  shift
fi

# sigpipe_check <file>... -> prints file:line for each early-exit consumer
# whose pipeline status is used, in a script that sets pipefail; fails when
# it printed any. Used means: anywhere under set -e, else inside $( ), an
# if/while/until/elif condition, a ! negation, or an && / || list.
sigpipe_check() {
  local f hits=0
  for f in "$@"; do
    case "$f" in */tests/*|tests/*) continue ;; esac
    [ -f "$f" ] || continue
    awk -v file="$f" '
      /^[[:space:]]*set[[:space:]]+-[[:alpha:]]*o[[:space:]]+pipefail/ { pipefail = 1 }
      /^[[:space:]]*set[[:space:]]+-[[:alpha:]]*e/ { errexit = 1 }
      { lines[NR] = $0 }
      END {
        if (!pipefail) exit 0
        consumer = "(^|[^|])[|][[:space:]]*(head([[:space:]]|$|[)])|grep[[:space:]]+(-[[:alnum:]-]+[[:space:]]+)*-[[:alpha:]]*q)"
        used = "[$][(]|(^|[[:space:];])(if|while|until|elif|!)[[:space:]]|&&|[|][|]"
        for (i = 1; i <= NR; i++) {
          l = lines[i]
          if (l ~ /^[[:space:]]*#/ || l ~ /#[[:space:]]*lint:[[:space:]]*sigpipe-ok/) continue
          if (l !~ consumer) continue
          if (errexit || l ~ used) {
            printf "%s:%d: early-exit pipeline consumer under pipefail (SIGPIPE turns its status into 141); read all the input (here-string, awk, a captured $(...)) or add # lint: sigpipe-ok\n", file, i
            hits++
          }
        }
        exit (hits > 0)
      }' "$f" || hits=1
  done
  [ "$hits" -eq 0 ]
}

if [ $# -eq 0 ]; then
  while IFS= read -r f; do
    set -- "$@" "$f"
  done < <(find hooks lib -name '*.sh' -type f 2>/dev/null | LC_ALL=C sort)
fi
[ $# -gt 0 ] || { echo "lint-sh: no shell scripts found" >&2; exit 2; }

sigpipe_status=0
sigpipe_check "$@" || sigpipe_status=1
[ "$sigpipe_only" -eq 0 ] || exit "$sigpipe_status"

"$sc" --version | sed -n 2p >&2
sc_status=0
"$sc" "$@" || sc_status=$?
[ "$sc_status" -ne 0 ] && exit "$sc_status"
exit "$sigpipe_status"
