#!/usr/bin/env bash
# Fixture for the SIGPIPE rule in scripts/lint-sh.sh (--sigpipe-only, so no
# ShellCheck is needed). In a script that sets pipefail, `producer | head`
# or `producer | grep -q` whose status is used turns into the producer's
# SIGPIPE exit 141 once the input outgrows a pipe buffer: a match reads as a
# miss in an `if`, and set -e exits mid-hook (#33, #249). The rule must fire
# on each such shape, stay quiet on the safe ones, and the shipped scripts
# must pass it.
#
# Usage: lint-sh.test.sh [path-to-lint-sh.sh]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../lint-sh.sh}"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

lint() {  # lint <file> -> OUT, STATUS
  OUT=$(bash "$SCRIPT" --sigpipe-only "$1" 2>&1)
  STATUS=$?
}
flags_line() {  # flags_line <file> <line> <desc>
  if grep -qF "$1:$2:" <<< "$OUT"; then ok; else fail "$3 (no finding at $1:$2; got: $OUT)"; fi
}

# shellcheck disable=SC2016 # fixture text, written literally
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'ctx=$(printf "%s" "$cmd" | tr "\n" " " | head -c 120)' \
  'printf "%s" "$x" | grep -q needle' \
  'if git status --porcelain | grep -qE . ; then :; fi' \
  'newest=$(ls -t ./*.json | head -1)' \
  > "$TMP/errexit.sh"
lint "$TMP/errexit.sh"
[ "$STATUS" -ne 0 ] && ok || fail "errexit fixture fails the lint"
flags_line "$TMP/errexit.sh" 3 "head -c inside \$( )"
flags_line "$TMP/errexit.sh" 4 "a plain grep -q statement under set -e"
flags_line "$TMP/errexit.sh" 5 "grep -qE in an if"
flags_line "$TMP/errexit.sh" 6 "head -1 inside \$( )"

# shellcheck disable=SC2016 # fixture text, written literally
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  'git log | head -5' \
  'while printf "%s" "$x" | grep -Eq y; do :; done' \
  'printf "%s" "$x" | grep -q y && echo hit' \
  '! printf "%s" "$x" | grep -q y' \
  > "$TMP/no-errexit.sh"
lint "$TMP/no-errexit.sh"
[ "$STATUS" -ne 0 ] && ok || fail "no-errexit fixture fails the lint"
grep -qF "$TMP/no-errexit.sh:3:" <<< "$OUT" && fail "without set -e, a plain statement's status is unused" || ok
flags_line "$TMP/no-errexit.sh" 4 "grep -Eq in a while condition"
flags_line "$TMP/no-errexit.sh" 5 "grep -q in an && list"
flags_line "$TMP/no-errexit.sh" 6 "grep -q under !"

# shellcheck disable=SC2016 # fixture text, written literally
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '# a comment: printf x | grep -q y' \
  'if grep -q needle <<< "$x"; then :; fi' \
  'first=$(ls -t | awk "NR == 1")' \
  'ctx=${cmd:0:120}' \
  'ok=$(printf "%s" "$x" | head -1) # lint: sigpipe-ok' \
  'a=$(false || head -1 file)' \
  'grep -c x file | sort' \
  > "$TMP/clean.sh"
lint "$TMP/clean.sh"
[ "$STATUS" -eq 0 ] && ok || fail "clean fixture passes (got $STATUS: $OUT)"

# shellcheck disable=SC2016 # fixture text, written literally
printf '%s\n' '#!/usr/bin/env bash' 'set -eu' 'x=$(printf y | head -1)' > "$TMP/no-pipefail.sh"
lint "$TMP/no-pipefail.sh"
[ "$STATUS" -eq 0 ] && ok || fail "a script without pipefail is out of scope (got $STATUS: $OUT)"

# A sourced module declares the options it runs under.
# shellcheck disable=SC2016 # fixture text, written literally
printf '%s\n' '#!/usr/bin/env bash' '# lint: sourced under set -euo pipefail' 'f() { x=$(printf y | head -1); }' > "$TMP/sourced.sh"
lint "$TMP/sourced.sh"
flags_line "$TMP/sourced.sh" 3 "a module sourced under pipefail is in scope"

mkdir -p "$TMP/hooks/tests"
cp "$TMP/errexit.sh" "$TMP/hooks/tests/fixture.test.sh"
lint "$TMP/hooks/tests/fixture.test.sh"
[ "$STATUS" -eq 0 ] && ok || fail "a script under tests/ is exempt (got $STATUS: $OUT)"

# The shipped hooks and lib scripts pass.
OUT=$(bash "$SCRIPT" --sigpipe-only 2>&1)
STATUS=$?
[ "$STATUS" -eq 0 ] && ok || fail "hooks/ and lib/ pass the SIGPIPE rule (got: $OUT)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
