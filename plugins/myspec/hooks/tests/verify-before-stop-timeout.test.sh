#!/usr/bin/env bash
# Regression fixture for the per-check time cap in verify-before-stop.sh.
#
# A check that outlives the cap must be reported as timed out (result
# unknown), never as an ordinary failure, and the cap must bound the wait:
# the whole process tree is killed, so a grandchild still holding the output
# pipe cannot keep the hook waiting until it finishes on its own. The
# reported output must keep its end, the part that names the result.
#
# This suite keeps the paths that need the whole hook. The runner's other
# cases (a fast exit 124, long output, a leftover child, a setsid grandchild,
# cleanup failing or timing out or not running, a detached writer, the
# no-perl fallback, and the cap that cannot be raised) are function tests in
# lib/tests/stop-gate-run.test.sh.
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
GRANDCHILD_PID="$ROOT/grandchild.pid"
trap '[ -f "$GRANDCHILD_PID" ] && kill "$(cat "$GRANDCHILD_PID")" 2>/dev/null; rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# arm: a code write in the checkout, recorded the way mark-code-changed.sh
# records it (lib/session-event.sh), so each run has something to verify.
SESSION_EVENT="$(cd "$(dirname "$HOOK")" && pwd)/../lib/session-event.sh"
arm() {
  bash "$SESSION_EVENT" --root "$REPO" append "$SID" "$(jq -nc --arg r "$REPO" '{t: "write", root: $r, rel: "src/edited.ts", kind: "code"}')"
}

checks() {  # checks <verification.json checks array>
  printf '{"checks":%s}\n' "$1" > "$REPO/.claude/verification.json"
}

run_hook() {  # run_hook -> hook stdout; cap lowered to 2 s
  arm
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

# --- cleanup runs after a timeout, with the check's run ID ---------------------
checks "[{\"name\":\"remote\",\"command\":\"printf %s \\\"\$MYSPEC_CHECK_RUN_ID\\\" > $ROOT/check.id; sleep 30\",\"cleanup\":\"printf %s \\\"\$MYSPEC_CHECK_RUN_ID\\\" > $ROOT/cleanup.id\",\"required\":true}]"
OUT=$(run_hook)
[ -s "$ROOT/check.id" ] && ok || fail "the check sees MYSPEC_CHECK_RUN_ID"
[ -s "$ROOT/cleanup.id" ] && [ "$(cat "$ROOT/check.id" 2>/dev/null)" = "$(cat "$ROOT/cleanup.id")" ] \
  && ok || fail "cleanup runs with the check's MYSPEC_CHECK_RUN_ID"
reason "$OUT" | grep -q 'Cleanup ran' && ok || fail "the reason says cleanup ran (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'No cleanup declared' && fail "a declared cleanup is not reported as missing" || ok

printf 'verify-before-stop-timeout: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
