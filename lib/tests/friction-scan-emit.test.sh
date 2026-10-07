#!/usr/bin/env bash
# Regression fixture for friction-scan --emit (lib/friction-scan/metrics.mjs).
#
# The records are shipped behaviour that runs after every session, so four
# things have to hold:
#   - shape: one record per skill window and one per session, with the
#     counts attributed to the right window (nested skills inside their
#     parent, subagent tokens and verdicts on the window that dispatched them)
#     and tokens counted once per message id;
#   - no content: prompts, skill arguments, tool results, subagent
#     descriptions and absolute paths never reach the file;
#   - idempotency: a second run on the same session adds nothing, a resumed
#     session adds only what changed;
#   - fail-open: every opt-out, a missing transcript, an unknown format and an
#     unwritable target exit 0 with at most one stderr line and never leave a
#     partial line behind.
#
# Usage: friction-scan-emit.test.sh [path-to-scan.mjs]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../friction-scan/scan.mjs}"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
PROJECTS="$ROOT/projects"
WORK="$ROOT/work"
OUT="$ROOT/metrics-out.jsonl"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$PROJECTS/-enc-proj" "$WORK/.ai/features/billing-export"
unset MYSPEC_DISABLE_METRICS DO_NOT_TRACK MYSPEC_DISABLE_FRICTION_REPORT
echo '{ "aiDir": ".ai", "frameworkVersion": "9.9.9" }' > "$WORK/.myspec.json"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
check() { if jq -e "$1" >/dev/null 2>&1 <<<"$2"; then ok; else fail "$3 (jq: $1)"; fi; }
emit() { OUTPUT=$(cd "${EMIT_CWD:-$WORK}" && node "$SCRIPT" --projects-dir="$PROJECTS" "$@" 2>"$ROOT/stderr"); STATUS=$?; ERR=$(cat "$ROOT/stderr"); }
record() { jq -c "select($1)" "${2:-$OUT}" | tail -1; }
lines() { if [ -f "${1:-$OUT}" ]; then wc -l < "${1:-$OUT}" | tr -d ' '; else echo 0; fi; }

# ── entry builders (the transcript shape) ──

# The counter lives in a file: stamp runs inside $(...), where a variable
# increment would be lost.
echo 0 > "$ROOT/clock"
stamp() { local T; T=$(( $(cat "$ROOT/clock") + 1 )); echo "$T" > "$ROOT/clock"; printf '2026-09-27T%02d:%02d:%02d.000Z' $((10 + T / 3600)) $((T / 60 % 60)) $((T % 60)); }
prompt() { printf '{"type":"user","timestamp":"%s","version":"2.1.999","message":{"role":"user","content":%s}}\n' "$(stamp)" "$(jq -Rs . <<<"$1")"; }
slash() { prompt "<command-message>$1</command-message>
<command-name>/$1</command-name>
<command-args>$2</command-args>"; }
skill_body() { printf '{"type":"user","isMeta":true,"timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: %s/plugin/skills/x\\n\\n# Skill body SECRET-BODY"}]}}\n' "$(stamp)" "$ROOT"; }
# amsg <message id> <output tokens> <content blocks JSON>
amsg() { printf '{"type":"assistant","timestamp":"%s","version":"2.1.999","message":{"id":"%s","model":"claude-test","role":"assistant","content":%s,"usage":{"input_tokens":1,"output_tokens":%s,"cache_read_input_tokens":100,"cache_creation_input_tokens":10}}}\n' "$(stamp)" "$1" "$3" "$2"; }
tool() { local input='{}'; [ $# -ge 3 ] && input=$3; printf '[{"type":"tool_use","id":"%s","name":"%s","input":%s}]' "$1" "$2" "$input"; }
result() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"ok SECRET-RESULT"}]}}\n' "$(stamp)" "$1"; }
linked() { printf '{"type":"user","timestamp":"%s","toolUseResult":{"agentId":"%s","status":"completed"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"done SECRET-RESULT"}]}}\n' "$(stamp)" "$2" "$1"; }
denied() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"PreToolUse:Edit hook error: BLOCKED: no work-isolation decision recorded for this session."}]}}\n' "$(stamp)" "$1"; }

S=emit-shape
TRANSCRIPT="$PROJECTS/-enc-proj/$S.jsonl"
mkdir -p "$PROJECTS/-enc-proj/$S/subagents"
{
  slash myspec:feature-plan 'billing-export SECRET-ARG'
  skill_body
  # One API message written as two entries: its usage counts once.
  amsg m1 20 '[{"type":"text","text":"Planning SECRET-TEXT"}]'
  amsg m1 20 "$(tool t1 Bash '{"command":"ls SECRET-CMD"}')"
  result t1
  amsg m2 30 "$(tool a1 Agent '{"description":"Implement Task 1 SECRET-DESC","prompt":"SECRET-PROMPT"}')"
  linked a1 sub1
  amsg m3 40 "$(tool s1 Skill '{"skill":"myspec:memory-preflight","args":"not-a-feature"}')"
  result s1
  amsg m4 50 "$(tool e1 Edit '{"file_path":"/abs/SECRET-PATH.ts"}')"
  denied e1
  prompt 'thanks SECRET-PROMPT, now wrap up'
  amsg m5 60 "$(tool s2 Skill '{"skill":"myspec:session-complete"}')"
  result s2
  amsg m6 70 "$(tool x1 mcp__my_srv__do_thing)"
  result x1
} > "$TRANSCRIPT"
{
  prompt 'Task 1 SECRET-PROMPT'
  amsg sm1 7 '[{"type":"text","text":"working"}]'
  prompt 'The coordinator sent a message: fix finding 1'
  amsg sm2 3 '[{"type":"text","text":"Report\n\n**Status:** BLOCKED"}]'
} > "$PROJECTS/-enc-proj/$S/subagents/agent-sub1.jsonl"
echo '{"agentType":"general-purpose","description":"Implement Task 1 SECRET-DESC"}' > "$PROJECTS/-enc-proj/$S/subagents/agent-sub1.meta.json"

# ── 1. record shape ──
emit --session=$S --emit="$OUT" --json --reason=prompt_input_exit
[ "$STATUS" -eq 0 ] && ok || fail "emit exits 0 (got $STATUS)"
check '.written == 4 and .skipped == 0' "$OUTPUT" "four records written"
[ "$(lines)" = 4 ] && ok || fail "four lines in the file (got $(lines))"
if jq -e . "$OUT" >/dev/null 2>&1; then ok; else fail "every line is JSON"; fi

R=$(record '.skill == "myspec:feature-plan"')
check '.schema == 1 and .kind == "skill" and .trigger == "user-slash" and .myspec == "9.9.9" and .cc == "2.1.999"' "$R" "slash window: identity fields"
check '.feature == "billing-export"' "$R" "feature derived from an existing feature directory"
check '.tokens == {"in":6,"out":150,"cache_read":600,"cache_write":60}' "$R" "tokens: split message counted once, subagent tokens added (got $(jq -c .tokens <<<"$R"))"
check '.subagents == 1 and .subagent_status == {"BLOCKED":1} and .fix_rounds == 1' "$R" "dispatched subagent: verdict and fix round on the parent window"
check '.hook_blocks == {"isolation-undecided":1}' "$R" "hook block by signature id"
check '.tools == {"Agent":1,"Bash":1,"Edit":1,"Skill":1}' "$R" "tool counts by tool"
check '.turns == 1 and .active_ms > 0 and .start < .end' "$R" "turns (the user prompt before the next skill) and timing"

R=$(record '.skill == "myspec:memory-preflight"')
check '.trigger == "nested" and .feature == null' "$R" "nested skill; free-text arg is not a feature"
check '.tokens.out == 90' "$R" "nested window runs to its parent's end (got $(jq -c .tokens.out <<<"$R"))"

R=$(record '.skill == "myspec:session-complete"')
check '.trigger == "model" and .tokens.out == 130' "$R" "a Skill call after a user turn is top-level"
check '.tools["mcp__my_srv"] == 1' "$R" "MCP tools counted per server"

R=$(record '.kind == "session"')
check '.id == "emit-shape:session" and .session == "emit-shape" and .reason == "prompt_input_exit"' "$R" "session record identity"
check '.tokens == {"in":8,"out":280,"cache_read":800,"cache_write":80}' "$R" "session tokens: main plus subagents, deduped (got $(jq -c .tokens <<<"$R"))"
check '.turns == 2 and .skills == 3 and .subagents == 1 and .model == "claude-test"' "$R" "session counts"

# ── 2. no content ──
if grep -q 'SECRET' "$OUT"; then fail "no prompt, argument, result, description or path text in the records"; else ok; fi
if grep -qF "$ROOT" "$OUT"; then fail "no absolute path in the records"; else ok; fi

# ── 3. idempotency ──
emit --session=$S --emit="$OUT" --json
check '.written == 0 and .skipped == 4' "$OUTPUT" "second run writes nothing"
[ "$(lines)" = 4 ] && ok || fail "second run leaves four lines (got $(lines))"

# A resumed session grows: only the windows that changed get a newer record.
{
  prompt 'one more thing SECRET-PROMPT'
  amsg m7 5 '[{"type":"text","text":"done"}]'
} >> "$TRANSCRIPT"
emit --session=$S --emit="$OUT" --json
check '.written == 2 and .skipped == 2' "$OUTPUT" "resume: the last window and the session are re-recorded, the rest skipped"
[ "$(jq -c 'select(.kind == "session")' "$OUT" | wc -l | tr -d ' ')" = 2 ] && ok || fail "resume: a newer session record with the same id"

# ── 4. default location: the main checkout, from a linked worktree ──
REPO="$ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
echo '{ "aiDir": ".ai", "frameworkVersion": "9.9.9" }' > "$REPO/.myspec.json"
git -C "$REPO" add .myspec.json
git -C "$REPO" commit -q -m init
git -C "$REPO" worktree add -q "$ROOT/linked" -b metrics-linked 2>/dev/null
# Not gitignored: refused, so one commit cannot publish every session's metrics.
EMIT_CWD="$ROOT/linked" emit --session=$S --emit
[ "$STATUS" -eq 0 ] && ok || fail "not gitignored: exit 0"
[ ! -e "$REPO/.claude/state/metrics/runs.jsonl" ] && ok || fail "not gitignored: nothing written"
grep -q 'is not gitignored' <<<"$ERR" && [ "$(printf '%s\n' "$ERR" | grep -c .)" -eq 1 ] && ok || fail "not gitignored: one stderr line saying so (got: $ERR)"
echo '.claude/state/' > "$REPO/.gitignore"
EMIT_CWD="$ROOT/linked" emit --session=$S --emit
[ "$STATUS" -eq 0 ] && ok || fail "bare --emit exits 0"
[ "$(lines "$REPO/.claude/state/metrics/runs.jsonl")" -ge 4 ] && ok || fail "bare --emit writes to the main checkout's .claude/state/metrics/runs.jsonl"
[ ! -e "$ROOT/linked/.claude/state" ] && ok || fail "nothing lands in the linked worktree"

mkdir -p "$ROOT/plain"
EMIT_CWD="$ROOT/plain" emit --session=$S --emit
[ "$STATUS" -eq 0 ] && ok || fail "outside a myspec project: exit 0"
[ ! -e "$ROOT/plain/.claude" ] && ok || fail "outside a myspec project: no state tree created"
[ "$(printf '%s' "$ERR" | wc -l | tr -d ' ')" -le 1 ] && [ -n "$ERR" ] && ok || fail "outside a myspec project: one stderr line (got: $ERR)"

# ── 5. opt-outs ──
OPT="$ROOT/metrics-opt.jsonl"
echo '{ "aiDir": ".ai", "feedback": { "metrics": false } }' > "$WORK/.myspec.json"
emit --session=$S --emit="$OPT" --json
check '.disabled == true' "$OUTPUT" "feedback.metrics false: disabled"
[ ! -e "$OPT" ] && ok || fail "feedback.metrics false: nothing written"
echo '{ "aiDir": ".ai", "feedback": { "frictionReport": false } }' > "$WORK/.myspec.json"
emit --session=$S --emit="$OPT"
[ "$(lines "$OPT")" -gt 0 ] && ok || fail "frictionReport false does not turn metrics off"
rm -f "$OPT"
echo '{ "aiDir": ".ai" }' > "$WORK/.myspec.json"
OUTPUT=$(cd "$WORK" && MYSPEC_DISABLE_METRICS=1 node "$SCRIPT" --projects-dir="$PROJECTS" --session=$S --emit="$OPT" 2>&1); STATUS=$?
[ "$STATUS" -eq 0 ] && [ ! -e "$OPT" ] && [ -z "$OUTPUT" ] && ok || fail "MYSPEC_DISABLE_METRICS=1: silent, nothing written"
OUTPUT=$(cd "$WORK" && DO_NOT_TRACK=1 node "$SCRIPT" --projects-dir="$PROJECTS" --session=$S --emit="$OPT" 2>&1); STATUS=$?
[ "$STATUS" -eq 0 ] && [ ! -e "$OPT" ] && [ -z "$OUTPUT" ] && ok || fail "DO_NOT_TRACK=1: silent, nothing written"
OUTPUT=$(cd "$WORK" && DO_NOT_TRACK=0 node "$SCRIPT" --projects-dir="$PROJECTS" --session=$S --emit="$OPT" 2>&1)
[ "$(lines "$OPT")" -gt 0 ] && ok || fail "DO_NOT_TRACK=0 does not opt out"
# A hand-edited opt-out with a syntax error still opts out.
rm -f "$OPT"
printf '{ "aiDir": ".ai", "feedback": { "metrics": false, } }\n' > "$WORK/.myspec.json"
emit --session=$S --emit="$OPT" --json
check '.disabled == true' "$OUTPUT" "unparseable .myspec.json: treated as opted out"
[ ! -e "$OPT" ] && ok || fail "unparseable .myspec.json: nothing written"
echo '{ "aiDir": ".ai" }' > "$WORK/.myspec.json"

# ── 6. fail-open ──
one_line_exit0() { if [ "$STATUS" -eq 0 ] && [ "$(printf '%s\n' "$ERR" | grep -c .)" -eq 1 ] && ! grep -q '    at ' <<<"$ERR"; then ok; else fail "$1 (exit $STATUS, stderr: $ERR)"; fi; }
emit --session=does-not-exist --emit="$ROOT/metrics-none.jsonl"
one_line_exit0 "missing transcript: exit 0, one stderr line"
echo '{"type":"summary","summary":"x"}' > "$PROJECTS/-enc-proj/emit-unknown.jsonl"
emit --session=emit-unknown --emit="$ROOT/metrics-none.jsonl"
one_line_exit0 "unrecognized format: exit 0, one stderr line"
[ ! -e "$ROOT/metrics-none.jsonl" ] && ok || fail "nothing written when there is nothing to record"
mkdir -p "$ROOT/metrics-dir.jsonl"
emit --session=$S --emit="$ROOT/metrics-dir.jsonl"
one_line_exit0 "unwritable target: exit 0, one stderr line, no stack trace"

# A writer killed mid-line left a torn last line: new records start on their own line.
TORN="$ROOT/metrics-torn.jsonl"
printf '{"schema":1,"kind":"skill","id":"x:1","end":"2026-01-01T00:00:00.000Z","sess' > "$TORN"
emit --session=$S --emit="$TORN"
[ "$(grep -c . "$TORN")" -eq 5 ] && ok || fail "torn line stays one line, four records follow (got $(grep -c . "$TORN") lines)"
[ "$(tail -n +2 "$TORN" | jq -c . 2>/dev/null | wc -l | tr -d ' ')" -eq 4 ] && ok || fail "every new line parses after a torn one"

# ── 7. things that are not the user taking a turn ──
# Background jobs finishing (queued task notifications), auto-compaction's
# summary, and messages from other agents must not end the running skill: the
# model's next Skill call stays nested, and turns stay at the real prompts.
S=emit-not-turns
{
  slash myspec:feature-implement ''
  skill_body
  amsg n1 10 "$(tool a1 Agent '{"description":"bg"}')"
  printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>done</task-notification>"}}\n' "$(stamp)"
  printf '{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"%s","message":{"role":"user","content":"This session is being continued from a previous conversation."}}\n' "$(stamp)"
  printf '{"type":"user","origin":{"kind":"peer"},"timestamp":"%s","message":{"role":"user","content":"Another session says hello"}}\n' "$(stamp)"
  amsg n2 20 "$(tool s1 Skill '{"skill":"myspec:memory-preflight"}')"
  result s1
  # Positive control: a prompt the user queued is a turn and ends the parent.
  printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"queued_command","commandMode":"prompt","prompt":"also do X"}}\n' "$(stamp)"
  amsg n3 30 "$(tool s2 Skill '{"skill":"myspec:code-review"}')"
  result s2
} > "$PROJECTS/-enc-proj/$S.jsonl"
mkdir -p "$PROJECTS/-enc-proj/$S/subagents"
{
  prompt 'Task SECRET-PROMPT'
  amsg sa1 1 '[{"type":"text","text":"working"}]'
  printf '{"type":"user","isMeta":true,"timestamp":"%s","message":{"role":"user","content":"(No effort level given, reusing high)"}}\n' "$(stamp)"
  printf '{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"%s","message":{"role":"user","content":"This session is being continued from a previous conversation."}}\n' "$(stamp)"
  printf '{"type":"user","isMeta":true,"origin":{"kind":"coordinator"},"timestamp":"%s","message":{"role":"user","content":"The coordinator sent a message: fix finding 1"}}\n' "$(stamp)"
  amsg sa2 1 '[{"type":"text","text":"**Status:** DONE"}]'
} > "$PROJECTS/-enc-proj/$S/subagents/agent-bg1.jsonl"
NT="$ROOT/metrics-not-turns.jsonl"
emit --session=$S --emit="$NT"
check '.trigger == "nested"' "$(record '.skill == "myspec:memory-preflight"' "$NT")" "a Skill call after a task notification, compaction summary or peer message stays nested"
check '.turns == 1 and .tokens.out == 30' "$(record '.skill == "myspec:feature-implement"' "$NT")" "the parent keeps its work until the user's queued prompt"
check '.trigger == "model"' "$(record '.skill == "myspec:code-review"' "$NT")" "positive control: a queued user prompt makes the next Skill call top-level"
check '.turns == 2 and .fix_rounds == 1' "$(record '.kind == "session"' "$NT")" "session: two real turns; one fix round (coordinator), not the injected body or the summary"

# ── 8. feature directory that exists only in the linked worktree ──
S=emit-wt-feature
mkdir -p "$ROOT/linked/.ai/features/wt-only"
{
  slash myspec:feature-spec 'wt-only'
  skill_body
  amsg w1 1 '[{"type":"text","text":"ok"}]'
} > "$PROJECTS/-enc-proj/$S.jsonl"
EMIT_CWD="$ROOT/linked" emit --session=$S --emit="$ROOT/metrics-wt.jsonl"
check '.feature == "wt-only"' "$(record '.kind == "skill"' "$ROOT/metrics-wt.jsonl")" "feature found in the session's own checkout"

# ── 9. memory stays bounded on a large transcript ──
# Lines carrying megabytes of file content are streamed and cut down one at a
# time; reading the whole file first peaked at about 5x its size.
S=emit-big
node -e '
  const fs = require("fs"); const fd = fs.openSync(process.argv[1], "w");
  const big = "x".repeat(1024 * 1024);
  fs.writeSync(fd, JSON.stringify({ type: "user", timestamp: "2026-09-27T10:00:00.000Z", message: { role: "user", content: "go" } }) + "\n");
  for (let i = 0; i < 40; i++) {
    const ts = new Date(Date.parse("2026-09-27T10:00:00Z") + i * 1000).toISOString();
    fs.writeSync(fd, JSON.stringify({ type: "assistant", timestamp: ts, message: { id: "b" + i, role: "assistant", content: [{ type: "tool_use", id: "t" + i, name: "Read", input: {} }], usage: { input_tokens: 1, output_tokens: 1 } } }) + "\n");
    fs.writeSync(fd, JSON.stringify({ type: "user", timestamp: ts, message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t" + i, content: big }] }, toolUseResult: { file: { content: big } } }) + "\n");
  }
  fs.closeSync(fd);' "$PROJECTS/-enc-proj/$S.jsonl"
RSS_MB=$(cd "$WORK" && node -e '
  process.on("exit", () => console.error("RSS " + Math.round(process.resourceUsage().maxRSS / 1024)));
  process.argv = [process.argv[0], process.argv[1], "--transcript=" + process.argv[2], "--emit=" + process.argv[3]];
  import(process.argv[1]);' "$SCRIPT" "$PROJECTS/-enc-proj/$S.jsonl" "$ROOT/metrics-big.jsonl" 2>&1 | sed -n 's/^RSS //p')
[ "$(lines "$ROOT/metrics-big.jsonl")" -eq 1 ] && ok || fail "large transcript recorded"
[ -n "$RSS_MB" ] && [ "$RSS_MB" -lt 250 ] && ok || fail "peak memory on an 80 MB transcript stays under 250 MB (got ${RSS_MB:-?} MB)"

# ── 10. a resumed session: several ids, one record for the chain (#297) ──
# The resumed transcript repeats the entries before it (same uuid); they count
# once. Each id's subagents are read. The record is keyed by the first id.
uuid() { jq -c --arg u "$1" '. + {uuid: $u}'; }
CA=emit-chain-a
CB=emit-chain-b
mkdir -p "$PROJECTS/-enc-proj/$CA/subagents" "$PROJECTS/-enc-proj/$CB/subagents"
HEAD_LINES=$(prompt 'start the chain' | uuid u1; amsg c1 10 '[{"type":"text","text":"first"}]' | uuid u2)
printf '%s\n' "$HEAD_LINES" > "$PROJECTS/-enc-proj/$CA.jsonl"
{
  printf '%s\n' "$HEAD_LINES"
  prompt 'continue after resume' | uuid u3
  amsg c2 20 '[{"type":"text","text":"second"}]' | uuid u4
} > "$PROJECTS/-enc-proj/$CB.jsonl"
amsg ca1 3 '[{"type":"text","text":"a"}]' > "$PROJECTS/-enc-proj/$CA/subagents/agent-ca.jsonl"
amsg cb1 4 '[{"type":"text","text":"b"}]' > "$PROJECTS/-enc-proj/$CB/subagents/agent-cb.jsonl"

CHAIN="$ROOT/metrics-chain.jsonl"
emit --session=$CA,$CB --emit="$CHAIN" --json
[ "$STATUS" -eq 0 ] && ok || fail "chain: exit 0"
check '.written == 1' "$OUTPUT" "chain: one session record written (got $OUTPUT; stderr: $ERR)"
R=$(record '.kind == "session"' "$CHAIN")
check '.id == "emit-chain-a:session" and .session == "emit-chain-a"' "$R" "chain: keyed by the first id"
check '.turns == 2' "$R" "chain: the repeated prompt counts once, the resumed one counts (got $(jq -c .turns <<<"$R"))"
check '.tokens.out == 37 and .subagents == 2' "$R" "chain: both links and both links' subagents (got $(jq -c '[.tokens.out, .subagents]' <<<"$R"))"

# The SessionEnd hook passes its own transcript: it stands for the id it is named after.
CHAIN2="$ROOT/metrics-chain2.jsonl"
emit --session=$CA,$CB --transcript="$PROJECTS/-enc-proj/$CB.jsonl" --emit="$CHAIN2" --json
R2=$(record '.kind == "session"' "$CHAIN2")
[ -n "$R2" ] && [ "$(jq -c 'del(.start, .end)' <<<"$R2")" = "$(jq -c 'del(.start, .end)' <<<"$R")" ] && ok || fail "chain: --transcript for one link gives the same record"

# One id without a transcript is named on stderr; the rest is still recorded.
CHAIN3="$ROOT/metrics-chain3.jsonl"
emit --session=$CA,emit-chain-gone --emit="$CHAIN3" --json
check '.written == 1' "$OUTPUT" "chain: a missing id does not stop the others"
grep -q 'no transcript for emit-chain-gone' <<<"$ERR" && ok || fail "chain: the missing id is named on stderr (got: $ERR)"

printf 'friction-scan-emit: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
