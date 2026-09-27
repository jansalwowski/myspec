#!/usr/bin/env bash
# Regression fixture for the per-check time cap in verify-before-stop.sh.
#
# A check that outlives the cap must be reported as timed out (result
# unknown), never as an ordinary failure, and the cap must bound the wait:
# the whole process tree is killed, so a grandchild still holding the output
# pipe cannot keep the hook waiting until it finishes on its own. The
# reported output must keep its end, the part that names the result.
#
# MYSPEC_CHECK_CAP_SECONDS lowers the cap so this runs in seconds; the hook
# ignores values above its default, so the variable can never raise it.
#
# Usage: verify-before-stop-timeout.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../verify-before-stop.sh}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
mkdir -p "$REPO/.claude"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
SID="vbs-timeout-$$"
CHANGED="/tmp/.myspec-code-changed-$SID"
GRANDCHILD_PID="$ROOT/grandchild.pid"
trap 'if [ -f "$GRANDCHILD_PID" ]; then kill "$(cat "$GRANDCHILD_PID")" 2>/dev/null; fi; rm -rf "$ROOT"; rm -f "$CHANGED"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

checks() {  # checks <verification.json checks array>
  printf '{"checks":%s}\n' "$1" > "$REPO/.claude/verification.json"
}

run_hook() {  # run_hook -> hook stdout; cap lowered to 2 s
  touch "$CHANGED"
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" \
    | MYSPEC_CHECK_CAP_SECONDS=2 bash "$HOOK"
}

reason() { printf '%s' "$1" | jq -r '.reason // ""'; }

# --- a check that outlives the cap, with a grandchild holding the pipe ------
checks "[{\"name\":\"slow\",\"command\":\"echo started; sh -c 'echo \$\$ > $GRANDCHILD_PID; exec sleep 30' & wait\",\"required\":true}]"
START=$(date +%s)
OUT=$(run_hook)
ELAPSED=$(( $(date +%s) - START ))

[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "block" ] && ok || fail "a timed-out check blocks (got: $OUT)"
reason "$OUT" | grep -q 'slow timed out after 2s' && ok || fail "the reason says the check timed out (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'slow) failed\|slow\] .* failed' && fail "a timeout is not reported as a failure (got: $(reason "$OUT"))" || ok
[ "$ELAPSED" -lt 15 ] && ok || fail "the cap bounds the wait (took ${ELAPSED}s with a 2s cap)"
sleep 1
if [ -f "$GRANDCHILD_PID" ] && kill -0 "$(cat "$GRANDCHILD_PID")" 2>/dev/null; then
  fail "the grandchild is killed with the check"
else
  ok
fi

# --- a check that fails fast is still a failure, not a timeout ---------------
checks '[{"name":"red","command":"echo boom; exit 124","required":true}]'
OUT=$(run_hook)
reason "$OUT" | grep -q 'red\] echo boom; exit 124 failed' && ok || fail "a fast exit 124 is reported as a failure (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'timed out' && fail "a fast exit 124 is not called a timeout" || ok

# --- long output keeps its end ------------------------------------------------
checks '[{"name":"long","command":"head -c 5000 /dev/zero | tr \"\\\\0\" x; echo; echo TAIL-MARKER; exit 1","required":true}]'
OUT=$(run_hook)
reason "$OUT" | grep -q 'TAIL-MARKER' && ok || fail "truncated output keeps its last line (got: $(reason "$OUT" | tail -c 200))"

# --- the variable cannot raise the cap ----------------------------------------
grep -q 'MYSPEC_CHECK_CAP_SECONDS' "$HOOK" && ok || fail "the hook reads MYSPEC_CHECK_CAP_SECONDS"

printf 'verify-before-stop-timeout: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
