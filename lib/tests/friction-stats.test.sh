#!/usr/bin/env bash
# Regression fixture for friction-scan/stats.mjs, the runs.jsonl summariser.
#
# The summary is only worth reading if a resumed session counts once, a
# range excludes what is outside it, and a damaged line cannot take the
# report down. Records are written by hand here so each number below can be
# checked against the input.
#
# Usage: friction-stats.test.sh [path-to-stats.mjs]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../friction-scan/stats.mjs}"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$REPO/.claude/state/metrics"
git -C "$REPO" init -q -b main
echo '{ "aiDir": ".ai" }' > "$REPO/.myspec.json"
RUNS="$REPO/.claude/state/metrics/runs.jsonl"
unset MYSPEC_DISABLE_METRICS DO_NOT_TRACK

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
run() { OUTPUT=$(cd "$REPO" && node "$SCRIPT" "$@" 2>&1); STATUS=$?; }
check() { if jq -e "$1" >/dev/null 2>&1 <<<"$OUTPUT"; then ok; else fail "$2 (jq: $1)"; fi; }
expect_line() { if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi; }

NOW=$(node -e 'console.log(new Date().toISOString())')
OLD=2020-01-01T00:00:00.000Z

# skill <id> <skill> <active_ms> <out tokens> <status json> <fix rounds> <hook blocks json> [end]
skill() { printf '{"schema":1,"kind":"skill","id":"%s","session":"s","start":"%s","end":"%s","active_ms":%s,"skill":"%s","tokens":{"in":1,"out":%s,"cache_read":10,"cache_write":0},"subagent_status":%s,"fix_rounds":%s,"hook_blocks":%s}\n' "$1" "${8:-$NOW}" "${8:-$NOW}" "$3" "$2" "$4" "$5" "$6" "$7"; }
session() { printf '{"schema":1,"kind":"session","id":"%s:session","session":"%s","start":"%s","end":"%s","active_ms":%s,"tokens":{"in":1,"out":%s,"cache_read":0,"cache_write":0},"fix_rounds":%s,"hook_blocks":%s}\n' "$1" "$1" "${6:-$NOW}" "${6:-$NOW}" "$2" "$3" "$4" "$5"; }

# ── 0. nothing recorded yet ──
run
[ "$STATUS" -eq 0 ] && ok || fail "no file: exit 0"
expect_line '^No field metrics recorded yet \(\.claude/state/metrics/runs\.jsonl\)' "no file: says so, path repo-relative"

{
  # feature-implement: 4 runs, active 1..4 min; one run BLOCKED, one PROBES_BLOCKED.
  skill a:1 myspec:feature-implement 60000 100 '{"DONE":2}' 1 '{}'
  skill a:2 myspec:feature-implement 120000 200 '{"BLOCKED":1}' 2 '{"reuse-audit":1}'
  skill a:3 myspec:feature-implement 180000 300 '{"PROBES_BLOCKED":1}' 0 '{}'
  skill a:4 myspec:feature-implement 240000 400 '{"NEEDS_CONTEXT":1}' 0 '{}'
  # A resumed session re-emitted a:4 with a later end: the later one wins.
  skill a:4 myspec:feature-implement 600000 999 '{}' 0 '{}' 2099-01-01T00:00:00.000Z
  # Outside the default 30-day range.
  skill b:1 myspec:feature-plan 5000 1 '{}' 0 '{}' "$OLD"
  skill c:1 myspec:feature-plan 30000 50 '{}' 0 '{}'
  session s1 1000 10 3 '{"isolation-undecided":2,"reuse-audit":1}'
  session s2 3000 30 0 '{"isolation-undecided":1}'
  session s0 9 9 9 '{"old-block":9}' "$OLD"
  echo 'not json {'
  printf '{"schema":1,"kind":"skill","id":"torn'
} > "$RUNS"

# ── 1. JSON summary ──
run --json
[ "$STATUS" -eq 0 ] && ok || fail "json: exit 0"
check '.unreadable == 2' "damaged lines counted, not fatal"
check '.sessions.count == 2 and .sessions.fix_rounds == 3' "sessions in range"
check '.skills | map(.skill) == ["myspec:feature-implement","myspec:feature-plan"]' "skills ordered by runs"
check '.skills[0].runs == 4' "a re-emitted window counts once"
check '.skills[0].active_ms == {"p50":120000,"p90":600000}' "active p50 and p90 (nearest rank), latest record per id"
check '.skills[0].tokens_out_p50 == 200 and .skills[0].tokens_in_p50 == 11' "token medians"
check '.skills[0].blocked_runs == 2 and .skills[0].blocked_rate == 0.5' "BLOCKED and PROBES_BLOCKED count as blocked; NEEDS_CONTEXT does not"
check '.skills[0].fix_rounds == 3 and .skills[0].hook_blocks == 1' "fix rounds and hook blocks summed"
check '.skills[1].runs == 1' "a record older than the range is excluded"
check '.hook_blocks == [{"name":"isolation-undecided","count":3},{"name":"reuse-audit","count":1}]' "top hook blocks from session records in range"
check '.recording == "on"' "recording state"

# ── 2. ranges ──
run --since=all --json
check '.skills[1].runs == 2 and .sessions.count == 3' "--since=all includes old records"
run --since=2019-12-31 --json
check '.sessions.count == 3' "--since takes an ISO date"
run --since=soon
[ "$STATUS" -eq 1 ] && ok || fail "bad --since: exit 1"

# ── 3. text ──
run
expect_line '^myspec field metrics, since [0-9-]+: 2 sessions, 5 skill runs \(\.claude/state/metrics/runs\.jsonl\)' "header"
expect_line '^\| myspec:feature-implement \| 4 \| 2m \| 10m \| 11 \| 200 \| 2/4 \| 3 \| 1 \|$' "per-skill row"
expect_line '^Hook blocks: isolation-undecided 3, reuse-audit 1$' "hook block line"
expect_line '^2 unreadable line\(s\) skipped\.$' "unreadable note"

# ── 4. opt-out is reported, data still shown ──
OUTPUT=$(cd "$REPO" && DO_NOT_TRACK=1 node "$SCRIPT" 2>&1)
expect_line '^Recording is off: DO_NOT_TRACK\.$' "opt-out is named"
expect_line '^\| myspec:feature-implement' "existing data still summarised"

# ── 5. --file ──
cp "$RUNS" "$ROOT/metrics-copy.jsonl"
run --file="$ROOT/metrics-copy.jsonl" --json
check '.skills[0].runs == 4' "--file reads another file"

printf 'friction-stats: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
