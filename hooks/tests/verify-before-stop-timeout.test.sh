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
# lib/tests/stop-gate-run.test.sh. The gate-wide budget (R13) is here end to
# end; that it cannot be raised is a function test there.
#
# MYSPEC_CHECK_CAP_SECONDS lowers the cap so this runs in seconds; the hook
# ignores values above its default, so the variable can never raise it.
#
# Usage: verify-before-stop-timeout.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../verify-before-stop.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

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

# --- the gate budget runs out after check 1 of 3 (R13) ------------------------
# A lowered budget of 4 s: the first check is cut at what is left of it, and
# checks 2 and 3 never start. A check that did not run is not a pass, so the
# stop blocks and names what ran and what did not.
checks "[{\"name\":\"one\",\"command\":\"sleep 30\",\"required\":true},{\"name\":\"two\",\"command\":\"touch $ROOT/two.ran\",\"required\":true},{\"name\":\"three\",\"command\":\"touch $ROOT/three.ran\",\"required\":true}]"
arm
START=$(date +%s)
OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | MYSPEC_GATE_BUDGET_SECONDS=4 bash "$HOOK")
ELAPSED=$(( $(date +%s) - START ))
[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "block" ] && ok || fail "budget: a spent budget blocks (got: $OUT)"
reason "$OUT" | grep -q 'not run, gate budget of 4s spent: two, three' && ok || fail "budget: the headline names checks 2 and 3 as not run (got: $(reason "$OUT" | head -1))"
reason "$OUT" | grep -q 'Checks that ran: one\.' && ok || fail "budget: the reason names the check that ran (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'one (at the gate budget' && ok || fail "budget: check 1 is a timeout at the budget (got: $(reason "$OUT" | head -1))"
[ ! -e "$ROOT/two.ran" ] && [ ! -e "$ROOT/three.ran" ] && ok || fail "budget: checks 2 and 3 never start"
[ "$ELAPSED" -lt 10 ] && ok || fail "budget: a lowered budget is honoured (took ${ELAPSED}s with a 4s budget)"

# --- the headline names the cap the budget applied, not the default (R13) ------
# Budget 4 s, default cap 120 s, a 10 s check: the check is cut at what is
# left of the budget, and the summary line must say so, not "after 120s".
checks "[{\"name\":\"ten\",\"command\":\"sleep 10\",\"required\":true}]"
arm
OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | MYSPEC_GATE_BUDGET_SECONDS=4 bash "$HOOK")
HEAD=$(reason "$OUT" | head -1)
printf '%s' "$HEAD" | grep -q 'after 120s' && fail "budget cap: the headline names the default cap (got: $HEAD)" || ok
printf '%s' "$HEAD" | grep -qE 'ten \(at the gate budget, [1-4]s\)' && ok || fail "budget cap: the headline names a cap of at most 4s and the budget (got: $HEAD)"

printf 'verify-before-stop-timeout: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
