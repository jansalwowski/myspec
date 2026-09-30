#!/usr/bin/env bash
# ShellCheck the shell this plugin ships (#209): hooks/ and lib/ plus their
# plugins/myspec/ mirrors, tests included. `bash -n` only proves a script
# parses; ShellCheck catches unused variables, quoting and $? mistakes.
#
# Runs at ShellCheck's default severity (style). Suppressions are inline
# `# shellcheck disable=SCxxxx # reason` directives, plus the .shellcheckrc in
# each tests/ directory for the assertion idioms the suites are written in.
#
# CI (.github/workflows/test.yml) runs it with a pinned, checksummed
# ShellCheck; .githooks/pre-commit checks staged scripts with whichever
# ShellCheck is on PATH.
#
# Usage: scripts/lint-sh.sh [file...]   default: every *.sh in the trees above
# Env:   SHELLCHECK  the binary to run (default: shellcheck)
# Exit:  ShellCheck's own (0 clean, 1 findings, 2+ usage or internal error).

set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 2
sc=${SHELLCHECK:-shellcheck}

if [ $# -eq 0 ]; then
  while IFS= read -r f; do
    set -- "$@" "$f"
  done < <(find hooks lib plugins/myspec/hooks plugins/myspec/lib -name '*.sh' -type f 2>/dev/null | LC_ALL=C sort)
fi
[ $# -gt 0 ] || { echo "lint-sh: no shell scripts found" >&2; exit 2; }

"$sc" --version | sed -n 2p >&2
exec "$sc" "$@"
