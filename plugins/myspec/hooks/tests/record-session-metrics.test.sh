#!/usr/bin/env bash
# Regression fixture for the SessionEnd hook record-session-metrics.sh.
#
# The hook runs as every session closes, inside Claude Code's shared 1.5 s
# SessionEnd budget, so it must never be felt: it returns at once, prints
# nothing, exits 0 on any input, and bounds the scan it starts. It is tested
# in the layout init installs (.claude/hooks/ beside .claude/lib/friction-scan/)
# so the lookup of the scan is covered too.
#
# MYSPEC_METRICS_CAP_SECONDS lowers the cap so the timeout case runs in
# seconds; the hook ignores values above its default.
#
# Usage: record-session-metrics.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_SRC="${1:-$HERE/../record-session-metrics.sh}"
LIB_SRC="$HERE/../../lib/friction-scan"
[ -f "$HOOK_SRC" ] || { echo "FATAL: hook not found: $HOOK_SRC" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
SHIM_PID="$ROOT/shim.pid"
trap 'if [ -f "$SHIM_PID" ]; then kill "$(cat "$SHIM_PID")" 2>/dev/null; fi; rm -rf "$ROOT"' EXIT
unset MYSPEC_DISABLE_METRICS DO_NOT_TRACK MYSPEC_METRICS_CAP_SECONDS

mkdir -p "$REPO/.claude/hooks" "$REPO/.claude/lib/friction-scan"
git -C "$REPO" init -q -b main
echo '.claude/state/' > "$REPO/.gitignore"
echo '{ "aiDir": ".ai", "frameworkVersion": "9.9.9" }' > "$REPO/.myspec.json"
cp "$HOOK_SRC" "$REPO/.claude/hooks/record-session-metrics.sh"
chmod +x "$REPO/.claude/hooks/record-session-metrics.sh"
cp "$LIB_SRC/scan.mjs" "$LIB_SRC/metrics.mjs" "$REPO/.claude/lib/friction-scan/"
HOOK="$REPO/.claude/hooks/record-session-metrics.sh"
RUNS="$REPO/.claude/state/metrics/runs.jsonl"

TRANSCRIPT="$ROOT/hook-session.jsonl"
{
  printf '{"type":"user","timestamp":"2026-09-27T10:00:00.000Z","message":{"role":"user","content":"go"}}\n'
  printf '{"type":"assistant","timestamp":"2026-09-27T10:00:05.000Z","version":"2.1.999","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"s1","name":"Skill","input":{"skill":"myspec:bootstrap"}}],"usage":{"input_tokens":1,"output_tokens":2}}}\n'
} > "$TRANSCRIPT"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

payload() { jq -cn --arg s "${1:-hook-session}" --arg t "$TRANSCRIPT" --arg c "$REPO" '{session_id:$s,transcript_path:$t,cwd:$c,hook_event_name:"SessionEnd",reason:"other"}'; }

# run_hook <stdin> [env...]: sets OUT (stdout+stderr), STATUS, MS (wall time)
run_hook() {
  local input=$1; shift
  local start end
  start=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
  OUT=$(printf '%s' "$input" | env "$@" "$BASH" "$HOOK" 2>&1); STATUS=$?
  end=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
  MS=$((end - start))
}

wait_for() {  # wait_for <file> <seconds>
  for _ in $(seq 1 $(($2 * 10))); do
    [ -s "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

quiet_fast() {  # quiet_fast <label>
  [ "$STATUS" -eq 0 ] && ok || fail "$1: exit 0 (got $STATUS)"
  [ -z "$OUT" ] && ok || fail "$1: prints nothing (got: $OUT)"
  [ "$MS" -lt 1500 ] && ok || fail "$1: returns inside the 1.5 s SessionEnd budget (took ${MS} ms)"
}

# ── 1. records the session, in the background, from the installed layout ──
run_hook "$(payload)"
quiet_fast "normal run"
if wait_for "$RUNS" 10; then ok; else fail "runs.jsonl written by the detached scan"; fi
jq -e -s 'map(select(.kind == "session" and .session == "hook-session" and .reason == "other")) | length == 1' "$RUNS" >/dev/null 2>&1 && ok || fail "session record carries the SessionEnd reason"
jq -e -s 'map(select(.kind == "skill" and .skill == "myspec:bootstrap")) | length == 1' "$RUNS" >/dev/null 2>&1 && ok || fail "skill record written"

# Claude Code fires SessionEnd again for a resumed session: nothing duplicates.
BEFORE=$(wc -l < "$RUNS")
run_hook "$(payload)"
sleep 2
[ "$(wc -l < "$RUNS")" -eq "$BEFORE" ] && ok || fail "a second SessionEnd for the same transcript adds nothing"

# ── 2. any input is fail-open ──
rm -f "$RUNS"
run_hook 'not json'
quiet_fast "garbage stdin"
run_hook ''
quiet_fast "empty stdin"
run_hook "$(jq -cn --arg c "$REPO" '{session_id:"x/../../y",transcript_path:"/nonexistent",cwd:$c}')"
quiet_fast "hostile session id, missing transcript"
sleep 1
[ ! -e "$RUNS" ] && ok || fail "bad payloads record nothing"

# ── 3. opt-outs ──
run_hook "$(payload opt-env)" MYSPEC_DISABLE_METRICS=1
quiet_fast "MYSPEC_DISABLE_METRICS=1"
run_hook "$(payload opt-dnt)" DO_NOT_TRACK=1
quiet_fast "DO_NOT_TRACK=1"
echo '{ "aiDir": ".ai", "feedback": { "metrics": false } }' > "$REPO/.myspec.json"
run_hook "$(payload opt-config)"
quiet_fast "feedback.metrics false"
sleep 2
[ ! -e "$RUNS" ] && ok || fail "no opt-out records anything"
echo '{ "aiDir": ".ai", "frameworkVersion": "9.9.9" }' > "$REPO/.myspec.json"

# Without node the hook is a no-op, not an error.
BIN="$ROOT/bin-no-node"
mkdir -p "$BIN"
for c in cat dirname jq perl; do ln -s "$(command -v "$c")" "$BIN/$c"; done
run_hook "$(payload no-node)" PATH="$BIN"
quiet_fast "node missing"

# ── 4. the cap bounds a scan that hangs ──
SHIM="$ROOT/bin-slow"
mkdir -p "$SHIM"
# The shim records its process group before its pid, so both exist once the
# pid file does.
printf '#!/bin/sh\nps -o pgid= -p $$ | tr -d " " > "%s"\necho $$ > "%s"\nexec sleep 30\n' "$ROOT/shim.pgid" "$SHIM_PID" > "$SHIM/node"
chmod +x "$SHIM/node"
run_hook "$(payload slow)" PATH="$SHIM:$PATH" MYSPEC_METRICS_CAP_SECONDS=1
quiet_fast "hanging scan"
wait_for "$SHIM_PID" 5 || fail "the slow scan was started"
# Detached: the scan leads its own session (setsid), so a terminal closing
# with Claude Code does not take it down. Without setsid it would share the
# hook's process group and its pgid would not be its own pid.
[ "$(cat "$ROOT/shim.pgid" 2>/dev/null)" = "$(cat "$SHIM_PID")" ] && ok || fail "the scan runs in its own session (pgid $(cat "$ROOT/shim.pgid" 2>/dev/null), pid $(cat "$SHIM_PID"))"
sleep 3
if [ -f "$SHIM_PID" ] && kill -0 "$(cat "$SHIM_PID")" 2>/dev/null; then
  fail "a scan that outlives the cap is killed"
else
  ok
fi

# The variable can lower the cap, never raise it.
# shellcheck disable=SC2016 # literal text, not an expansion
grep -q '"$MYSPEC_METRICS_CAP_SECONDS" -lt "$CAP_SECONDS"' "$HOOK" && ok || fail "the cap variable only lowers the cap"
bash -n "$HOOK" && ok || fail "bash -n"

printf 'record-session-metrics: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
