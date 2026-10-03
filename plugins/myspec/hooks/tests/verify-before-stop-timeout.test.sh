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
GRANDCHILD_PID="$ROOT/grandchild.pid"
LEFTOVER_PID="$ROOT/leftover.pid"
DETACHED_PID="$ROOT/detached.pid"
WRITER_PID="$ROOT/writer.pid"
# shellcheck disable=SC2154 # p is the trap body's own loop variable
trap 'for p in "$GRANDCHILD_PID" "$LEFTOVER_PID" "$DETACHED_PID" "$WRITER_PID"; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done; rm -rf "$ROOT"' EXIT

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

# --- a check that fails fast is still a failure, not a timeout ---------------
checks '[{"name":"red","command":"echo boom; exit 124","required":true}]'
OUT=$(run_hook)
reason "$OUT" | grep -q 'red\] echo boom; exit 124 failed' && ok || fail "a fast exit 124 is reported as a failure (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'timed out' && fail "a fast exit 124 is not called a timeout" || ok

# --- long output keeps its end ------------------------------------------------
checks '[{"name":"long","command":"head -c 5000 /dev/zero | tr \"\\\\0\" x; echo; echo TAIL-MARKER; exit 1","required":true}]'
OUT=$(run_hook)
reason "$OUT" | grep -q 'TAIL-MARKER' && ok || fail "truncated output keeps its last line (got: $(reason "$OUT" | tail -c 200))"

# --- a passing check that leaves a background child ---------------------------
# The child holds the output pipe after the check exits; the hook must not wait
# for it, and must not leave it running.
checks "[{\"name\":\"leaky\",\"command\":\"sh -c 'echo \$\$ > $LEFTOVER_PID; exec sleep 30' & echo done\",\"required\":true}]"
START=$(date +%s)
OUT=$(run_hook)
ELAPSED=$(( $(date +%s) - START ))
[ "$(printf '%s' "$OUT" | jq -r '.decision')" = "approve" ] && ok || fail "a passing check that leaves a child still passes (got: $OUT)"
[ "$ELAPSED" -lt 10 ] && ok || fail "a leftover child does not hold the hook (took ${ELAPSED}s)"
sleep 1
if [ -f "$LEFTOVER_PID" ] && kill -0 "$(cat "$LEFTOVER_PID")" 2>/dev/null; then
  fail "a passing check's leftover child is killed"
else
  ok
fi

# --- a timed-out check whose grandchild left the process group ----------------
# setsid puts it out of reach of the group kill; the wait must stay bounded.
checks "[{\"name\":\"detached\",\"command\":\"perl -MPOSIX -e 'setsid; open(my \$f, q(>), q($DETACHED_PID)); print \$f \$\$; close \$f; exec q(sleep), 30' & wait\",\"required\":true}]"
START=$(date +%s)
OUT=$(run_hook)
ELAPSED=$(( $(date +%s) - START ))
reason "$OUT" | grep -q 'detached timed out after 2s' && ok || fail "the detached check times out (got: $(reason "$OUT"))"
[ "$ELAPSED" -lt 10 ] && ok || fail "a grandchild outside the group does not hold the hook (took ${ELAPSED}s)"
reason "$OUT" | grep -q 'No cleanup declared' && ok || fail "a timeout without cleanup says what may still run (got: $(reason "$OUT"))"

# --- cleanup runs after a timeout, with the check's run ID ---------------------
checks "[{\"name\":\"remote\",\"command\":\"printf %s \\\"\$MYSPEC_CHECK_RUN_ID\\\" > $ROOT/check.id; sleep 30\",\"cleanup\":\"printf %s \\\"\$MYSPEC_CHECK_RUN_ID\\\" > $ROOT/cleanup.id\",\"required\":true}]"
OUT=$(run_hook)
[ -s "$ROOT/check.id" ] && ok || fail "the check sees MYSPEC_CHECK_RUN_ID"
[ -s "$ROOT/cleanup.id" ] && [ "$(cat "$ROOT/check.id" 2>/dev/null)" = "$(cat "$ROOT/cleanup.id")" ] \
  && ok || fail "cleanup runs with the check's MYSPEC_CHECK_RUN_ID"
reason "$OUT" | grep -q 'Cleanup ran' && ok || fail "the reason says cleanup ran (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'No cleanup declared' && fail "a declared cleanup is not reported as missing" || ok

checks '[{"name":"remote","command":"sleep 30","cleanup":"echo cleanup-said-no; exit 3","required":true}]'
OUT=$(run_hook)
reason "$OUT" | grep -q 'Cleanup failed (exit 3)' && ok || fail "a failing cleanup is reported with its exit code (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'cleanup-said-no' && ok || fail "a failing cleanup's output is shown"

# The cleanup cap is lowered with the check cap, so this times out at 2s.
checks '[{"name":"remote","command":"sleep 30","cleanup":"sleep 30","required":true}]'
START=$(date +%s)
OUT=$(run_hook)
ELAPSED=$(( $(date +%s) - START ))
reason "$OUT" | grep -q 'Cleanup timed out after 2s' && ok || fail "a slow cleanup is capped and reported (got: $(reason "$OUT"))"
[ "$ELAPSED" -lt 15 ] && ok || fail "the cleanup cap bounds the wait (took ${ELAPSED}s)"

# --- cleanup does not run when the check finished ------------------------------
rm -f "$ROOT/cleanup.ran"
checks "[{\"name\":\"red\",\"command\":\"exit 1\",\"cleanup\":\"touch $ROOT/cleanup.ran\",\"required\":true},{\"name\":\"green\",\"command\":\"true\",\"cleanup\":\"touch $ROOT/cleanup.ran\",\"required\":true}]"
OUT=$(run_hook)
[ -e "$ROOT/cleanup.ran" ] && fail "cleanup does not run for a check that exited on its own" || ok

# --- a detached writer from one check stays out of the next check's output ----
checks "[{\"name\":\"a\",\"command\":\"perl -MPOSIX -e 'exit 0 if fork; setsid; open(my \$f, q(>), q($WRITER_PID)); print \$f \$\$; close \$f; \$| = 1; for (1 .. 100) { print qq(LEAK-\$_\\\\n); select(undef, undef, undef, 0.1) }'; echo a-ok\",\"required\":true},{\"name\":\"b\",\"command\":\"sleep 1; echo b-own-output; exit 1\",\"required\":true}]"
OUT=$(run_hook)
reason "$OUT" | grep -q 'b-own-output' && ok || fail "the failing check's own output is reported (got: $(reason "$OUT"))"
reason "$OUT" | grep -q 'LEAK' && fail "a detached writer from an earlier check does not reach a later check's output (got: $(reason "$OUT"))" || ok

# --- without perl, the timeout fallback also kills a finished check's leftovers -
# PATH gets every command except perl, so the hook takes the timeout branch.
TIMEOUT_BIN=$(command -v gtimeout || command -v timeout || true)
if [ -n "$TIMEOUT_BIN" ] && "$TIMEOUT_BIN" --version 2>/dev/null | grep -q 'GNU coreutils'; then
  NOPERL="$ROOT/noperl-bin"
  mkdir -p "$NOPERL"
  IFS=: read -ra PATH_DIRS <<< "$PATH"
  for d in "${PATH_DIRS[@]}"; do
    for f in "$d"/*; do
      name=${f##*/}
      case "$name" in perl*) continue ;; esac
      [ -x "$f" ] && [ ! -e "$NOPERL/$name" ] && ln -s "$f" "$NOPERL/$name"
    done
  done
  checks "[{\"name\":\"leaky\",\"command\":\"sh -c 'echo \$\$ > $LEFTOVER_PID; exec sleep 30' & echo done\",\"required\":true}]"
  rm -f "$LEFTOVER_PID"
  arm
  START=$(date +%s)
  OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | PATH="$NOPERL" MYSPEC_CHECK_CAP_SECONDS=2 "$NOPERL/bash" "$HOOK")
  ELAPSED=$(( $(date +%s) - START ))
  [ "$(printf '%s' "$OUT" | jq -r '.decision')" = "approve" ] && ok || fail "no-perl: a passing check that leaves a child still passes (got: $OUT)"
  [ "$ELAPSED" -lt 10 ] && ok || fail "no-perl: a leftover child does not hold the hook (took ${ELAPSED}s)"
  sleep 1
  if [ -f "$LEFTOVER_PID" ] && kill -0 "$(cat "$LEFTOVER_PID")" 2>/dev/null; then
    fail "no-perl: a passing check's leftover child is killed"
  else
    ok
  fi
else
  printf 'SKIP  no-perl fallback: GNU timeout not installed\n' >&2
fi

# --- the variable cannot raise the cap ----------------------------------------
grep -q 'MYSPEC_CHECK_CAP_SECONDS' "$HOOK" && ok || fail "the hook reads MYSPEC_CHECK_CAP_SECONDS"

printf 'verify-before-stop-timeout: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
