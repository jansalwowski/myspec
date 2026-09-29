#!/usr/bin/env bash
# Regression fixture for friction-scan/scan.mjs.
#
# The scan is only useful if a row means something, so two things have to
# hold: a repeated pattern is reported with the right owner, and nothing
# expected or merely quoted is reported. One isolation prompt per session is
# the hook working; a report that mentions a hook error is not the error.
# Each exclusion below sits next to a positive control.
#
# The last block pins the signature table to the hook sources: renaming a
# hook's block message without updating HOOK_SIGNATURES fails here.
#
# Usage: friction-scan.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../friction-scan/scan.mjs}"
HOOKS_DIR="$HERE/../../hooks"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
PROJECTS="$ROOT/projects"
WORK="$ROOT/work"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$PROJECTS/-enc-proj" "$WORK"
unset MYSPEC_DISABLE_FRICTION_REPORT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect_line()    { if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi; }
expect_no_line() { if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi; }
expect_empty()   { if [ -z "$OUTPUT" ]; then ok; else fail "$1 (output not empty: $(head -c 200 <<<"$OUTPUT"))"; fi; }
expect_exit()    { if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1)"; fi; }
run() { OUTPUT=$(cd "$WORK" && node "$SCRIPT" --projects-dir="$PROJECTS" "$@" 2>&1); STATUS=$?; [ -z "${DEBUG:-}" ] || printf "%s\n" "$OUTPUT" >&2; }

# ── entry builders (one JSON object per line, the transcript shape) ──

N=0
stamp() { N=$((N + 1)); printf '2026-09-27T10:%02d:%02d.000Z' $((N / 60 % 60)) $((N % 60)); }
prompt()    { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":%s}}\n' "$(stamp)" "$(jq -Rs . <<<"$1")"; }
say()       { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":%s}]}}\n' "$(stamp)" "$(jq -Rs . <<<"$1")"; }
tool_use()  { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"%s","input":{}}]}}\n' "$(stamp)" "$1" "$2"; }
tool_err()  { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":%s}]}}\n' "$(stamp)" "$1" "$(jq -Rs . <<<"$2")"; }
# hook_block <hookName> <command> <reason>  (object shape, current versions)
hook_block() { printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"hook_blocking_error","hookName":"%s","hookEvent":"%s","blockingError":{"blockingError":%s,"command":%s}}}\n' "$(stamp)" "$1" "${1%%:*}" "$(jq -Rs . <<<"$3")" "$(jq -n --arg c "$2" '$c')"; }
# hook_block_str: the same, with blockingError as a JSON-encoded string
hook_block_str() { local inner; inner=$(jq -cn --arg r "$3" --arg c "$2" '{blockingError:$r,command:$c}'); printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"hook_blocking_error","hookName":"%s","blockingError":%s}}\n' "$(stamp)" "$1" "$(jq -Rs . <<<"$inner")"; }
hook_err()  { printf '{"type":"attachment","timestamp":"%s","attachment":{"type":"hook_non_blocking_error","hookName":"%s","command":%s,"exitCode":%s,"stderr":%s}}\n' "$(stamp)" "$1" "$(jq -n --arg c "$2" '$c')" "$3" "$(jq -n --arg e "${4:-}" '$e')"; }

session() { printf '%s' "$PROJECTS/-enc-proj/$1.jsonl"; }
subagent() { mkdir -p "$PROJECTS/-enc-proj/$1/subagents"; printf '%s' "$PROJECTS/-enc-proj/$1/subagents/agent-$2.jsonl"; }
meta() { printf '{"agentType":"general-purpose","description":"%s"}\n' "$3" > "$PROJECTS/-enc-proj/$1/subagents/agent-$2.meta.json"; }

ISO='BLOCKED: no work-isolation decision recorded for this session.'

# ── 1. a single isolation prompt is the hook working: nothing reported ──
S=s1-single-block
{
  prompt 'fix the bug'
  tool_use t1 Write
  tool_err t1 "PreToolUse:Write hook error: $ISO"
  say 'Asked where to work; continuing.'
} > "$(session $S)"
run --session=$S
expect_exit 0 "single block: exit 0"
expect_empty "single block: text mode prints nothing"

# ── 2. the same prompt three times is friction, owned by myspec ──
S=s2-repeated-block
{
  prompt 'fix the bug'
  for i in 1 2 3; do tool_use "t$i" Edit; tool_err "t$i" "<tool_use_error>PreToolUse:Edit hook error: $ISO</tool_use_error>"; done
} > "$(session $S)"
run --session=$S
expect_line '^\| hook block: isolation-undecided \| myspec \| 3 \| hooks/require-isolation-decision.sh' "repeated isolation block: myspec row"
expect_line 'look framework-side' "repeated isolation block: framework-side footer"

# ── 3. Stop and PostToolUse blocks from attachments, both value shapes ──
S=s3-attachments
{
  prompt 'wrap up'
  for i in 1 2; do hook_block Stop '"${CLAUDE_PLUGIN_ROOT}/hooks/verify-before-stop.sh"' 'Memory conformance check failed for changes under .ai/memory. Fix these'; done
  hook_block_str Stop '.claude/hooks/verify-before-stop.sh' 'Memory conformance check failed for changes under .ai/memory. Fix these'
  for i in 1 2 3; do hook_block PostToolUse:Write '.claude/hooks/verify-before-stop.sh' 'Verification did not pass (test). Fix failures'; done
  for i in 1 2 3; do hook_block PostToolUse:Edit '.claude/hooks/validate-frontmatter.sh' 'Some new message the table does not know'; done
  for i in 1 2 3; do hook_block PostToolUse:Edit '.claude/hooks/lint-on-save.sh' 'lint found 2 problems'; done
} > "$(session $S)"
run --session=$S
expect_line '^\| hook block: memory-conformance \| myspec \| 3 \|' "attachment blocks: both shapes counted together"
expect_line '^\| hook block: project-verification \| project \| 3 \|' "verification failures: project"
expect_line '^\| hook block: validate-frontmatter.sh \| unknown \| 3 \| hooks/validate-frontmatter.sh' "unknown message from a myspec hook: unknown, not guessed"
expect_line '^\| hook block: lint-on-save.sh \| project \| 3 \|' "the project's own hook: project"

# ── 4. quoting is not happening: text that mentions hooks is not counted ──
S=s4-quoted
{
  prompt 'summarize'
  say "The report says hook_blocking_error fired and: $ISO"
  say "$ISO"
  say "PreToolUse:Bash hook error: $ISO"
  tool_use t1 Bash
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"PreToolUse:Bash hook error: %s"}]}}\n' "$(stamp)" "$ISO"
} > "$(session $S)"
run --session=$S
expect_empty "quoted hook text and a non-error result are not events"

# ── 5. hooks that could not run ──
S=s5-hook-errors
{
  prompt 'go'
  hook_err PreToolUse:Bash '.claude/hooks/guard-git-branch.sh' 127 'Failed with non-blocking status code: /bin/sh: .claude/hooks/guard-git-branch.sh: No such file or directory'
  hook_err Stop '"${CLAUDE_PLUGIN_ROOT}/hooks/verify-before-stop.sh"' 1 'jq: error'
  hook_err PreToolUse:Bash '.claude/hooks/guard-bulk-read.sh' 127 'Failed with non-blocking status code: /bin/sh: .claude/hooks/guard-bulk-read.sh: No such file or directory'
  hook_err PostToolUse:Write '.claude/hooks/no-absolute-paths.sh' 127 '.claude/hooks/no-absolute-paths.sh: line 12: jq: command not found'
} > "$(session $S)"
run --session=$S
expect_line '^\| hook not found: guard-git-branch.sh \| setup \| 1 \|' "retired myspec hook still registered: setup"
expect_line '^\| hook failed \(exit 1\): verify-before-stop.sh \| myspec \|' "myspec hook crashing: myspec"
expect_line '^\| hook not found: guard-bulk-read.sh \| project \|' "project's missing hook: project"
expect_line '^\| hook failed \(exit 127\): no-absolute-paths.sh \| setup \| 1 \| hooks/no-absolute-paths.sh \| a command the hook calls is missing' "exit 127 from a command inside the hook: not 'script missing'"
expect_no_line 'hook not found: no-absolute-paths.sh' "a missing jq is not a missing script"
expect_line 'owner setup\): run /myspec:doctor' "setup footer"

# ── 6. subagent verdicts, continuations, and harness refusals ──
S=s6-subagents
{
  prompt 'implement the plan'
  for i in 1 2 3; do tool_use "h$i" Bash; tool_err "h$i" "This agent is isolated in the worktree /tmp/wt-$i, but this command runs elsewhere"; done
  tool_use x1 Bash; tool_err x1 'Exit code 1'
} > "$(session $S)"
F=$(subagent $S a1); meta $S a1 'Implement Task 2'
{ prompt 'Task 2'; say $'Work log\n\n**Status:** BLOCKED\nCannot reach the database.'; } > "$F"
F=$(subagent $S a2); meta $S a2 'Implement Task 3'
{ prompt 'Task 3'; say $'**Status:** NEEDS_CONTEXT\nThe spec does not say which role.'; } > "$F"
F=$(subagent $S a3); meta $S a3 'Probe executor'
{ prompt 'probes'; say $'P1 FAIL\nPROBES_FAILED'; } > "$F"
F=$(subagent $S a4); meta $S a4 'Implement Task 4'
{
  prompt 'Task 4'
  prompt '<system-reminder>harness note</system-reminder>'
  prompt '[handback-send-enforce] deliver your report'
  prompt 'The coordinator sent a message: fix finding 1'
  prompt 'The coordinator sent a message: fix finding 2'
  prompt 'The coordinator sent a message: fix finding 3'
  say '**Status:** DONE'
} > "$F"
F=$(subagent $S a5); meta $S a5 'Implement Task 5'
{ prompt 'Task 5'; prompt '<system-reminder>x</system-reminder>'; prompt '[tag] y'; prompt '[tag] z'; say '**Status:** DONE'; } > "$F"
run --session=$S
expect_line '^\| harness refusal: harness-worktree-guard \| harness \| 3 \|' "harness refusals grouped, owner harness"
expect_line '^\| subagent-blocked \| unknown \| 1 \| - \| Implement Task 2' "BLOCKED: unknown"
expect_line '^\| subagent-needs-context \| project \| 1 \|' "NEEDS_CONTEXT: project"
expect_line '^\| probes-failed \| project \| 1 \|' "PROBES_FAILED: project"
expect_line '^\| subagent continued 3 times \| unknown \| 1 \| - \| Implement Task 4' "fix rounds counted"
expect_no_line 'Implement Task 5 \|' "harness injections are not fix rounds"
expect_no_line 'repeated Bash error' "a one-off tool error is not reported"
expect_line '^Slowest subagents: ' "slowest subagents listed"

# ── 6b. review regressions ──
S=s6b-regressions
{
  prompt 'go'
  # A failing test run that prints a hook message is the tool's output.
  for i in 1 2 3; do tool_use "r$i" Bash; tool_err "r$i" $'Exit code 1\nhooks/tests/x.sh: FAIL expected: no work-isolation decision recorded'; done
  # Three parallel edits denied in one turn are one prompt, not three.
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_par","role":"assistant","content":[{"type":"tool_use","id":"p1","name":"Edit","input":{}}]}}\n' "$(stamp)"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_par","role":"assistant","content":[{"type":"tool_use","id":"p2","name":"Edit","input":{}}]}}\n' "$(stamp)"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_par","role":"assistant","content":[{"type":"tool_use","id":"p3","name":"Edit","input":{}}]}}\n' "$(stamp)"
  for i in 1 2 3; do tool_err "p$i" "PreToolUse:Edit hook error: $ISO"; done
  # Paths under a sibling of HOME keep their full name.
  for i in 1 2 3; do tool_use "h$i" Bash; tool_err "h$i" "cat: ${HOME}et/x: No such file"; done
} > "$(session $S)"
F=$(subagent $S b1); meta $S b1 'Conformance review'
{ prompt 'review'; say $'Earlier the executor returned PROBES_FAILED; that is now fixed.\n\n**Status:** DONE, not BLOCKED'; } > "$F"
run --session=$S
expect_no_line 'isolation-undecided' "hook text inside a tool's output is not a hook block; parallel denials are one turn"
expect_line "^\\| repeated Bash error \\| unknown \\| 3 \\| - \\| Exit code 1: hooks/tests/x.sh" "the failing test run stays a tool error"
expect_line "${HOME}et/x" "HOME is only shortened at a path boundary"
expect_no_line 'probes-failed|subagent-blocked' "verdict words mentioned in prose are not verdicts"

# ── 6c. harness entries are not fix rounds ──
# Auto-compaction's summary and isMeta injections (a forked skill's body) are
# not the controller sending the subagent back; a SendMessage continuation
# is, and arrives as isMeta with origin.kind "coordinator".
S=s6c-not-rounds
{ prompt 'go'; } > "$(session $S)"
compact() { printf '{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"%s","message":{"role":"user","content":"This session is being continued from a previous conversation."}}\n' "$(stamp)"; }
injected() { printf '{"type":"user","isMeta":true,"timestamp":"%s","message":{"role":"user","content":"(No effort level given, reusing high)"}}\n' "$(stamp)"; }
coordinator() { printf '{"type":"user","isMeta":true,"origin":{"kind":"coordinator"},"timestamp":"%s","message":{"role":"user","content":"The coordinator sent a message: %s"}}\n' "$(stamp)" "$1"; }
F=$(subagent $S c1); meta $S c1 'Long task'
{ prompt 'Task 1'; compact; injected; compact; injected; compact; say '**Status:** DONE'; } > "$F"
F=$(subagent $S c2); meta $S c2 'Reworked task'
{ prompt 'Task 2'; coordinator 'fix 1'; coordinator 'fix 2'; coordinator 'fix 3'; say '**Status:** DONE'; } > "$F"
run --session=$S
expect_no_line '^\| subagent continued .* Long task' "compaction summaries and injected bodies are not fix rounds"
expect_line '^\| subagent continued 3 times \| unknown \| 1 \| - \| Reworked task' "coordinator continuations are fix rounds"

# ── 7. JSON mode ──
run --session=s6-subagents --json
if jq -e '.findings | length == 5' >/dev/null <<<"$OUTPUT"; then ok; else fail "json: five findings"; fi
if jq -e '.summary.subagents == 5' >/dev/null <<<"$OUTPUT"; then ok; else fail "json: subagent count"; fi

# ── 8. opt-out ──
echo '{ "aiDir": ".ai", "feedback": { "frictionReport": false } }' > "$WORK/.myspec.json"
run --session=s2-repeated-block
expect_exit 0 "config opt-out: exit 0"
expect_empty "config opt-out: silent"
echo '{ "aiDir": ".ai" }' > "$WORK/.myspec.json"
OUTPUT=$(cd "$WORK" && MYSPEC_DISABLE_FRICTION_REPORT=1 node "$SCRIPT" --projects-dir="$PROJECTS" --session=s2-repeated-block 2>&1); STATUS=$?
expect_exit 0 "env opt-out: exit 0"
expect_empty "env opt-out: silent"
OUTPUT=$(cd "$WORK" && MYSPEC_DISABLE_FRICTION_REPORT=1 node "$SCRIPT" --projects-dir="$PROJECTS" --session=s2-repeated-block --json 2>&1)
if jq -e '.disabled == true and (.findings | length == 0)' >/dev/null <<<"$OUTPUT"; then ok; else fail "opt-out in JSON mode prints parseable JSON"; fi
# The opt-out is read from the checkout root, not the working directory.
git -C "$WORK" init -q
mkdir -p "$WORK/sub"
echo '{ "aiDir": ".ai", "feedback": { "frictionReport": false } }' > "$WORK/.myspec.json"
OUTPUT=$(cd "$WORK/sub" && node "$SCRIPT" --projects-dir="$PROJECTS" --session=s2-repeated-block 2>&1)
expect_empty "config opt-out applies from a subdirectory"
rm -rf "$WORK/.git" "$WORK/sub"
echo '{ "aiDir": ".ai" }' > "$WORK/.myspec.json"

# ── 9. lookup and failure modes ──
run --transcript="$(session s2-repeated-block)"
expect_line 'isolation-undecided' "--transcript path works"
run --session=does-not-exist
expect_exit 2 "missing transcript: exit 2"
echo '{"type":"summary","summary":"x"}' > "$(session s9-unknown)"
run --session=s9-unknown
expect_exit 3 "unrecognized format: exit 3"
run
expect_exit 1 "no arguments: usage error"

# ── 10. the signature table matches the hook sources ──
OUTPUT=$(node --input-type=module -e "
  import { HOOK_SIGNATURES, MYSPEC_HOOKS } from '$SCRIPT'
  import { readFileSync, existsSync } from 'node:fs'
  const retired = ['guard-git-branch.sh']
  for (const s of HOOK_SIGNATURES) {
    const src = '$HOOKS_DIR/' + s.hook
    if (!existsSync(src)) { console.log('missing hook ' + s.hook); continue }
    if (!readFileSync(src, 'utf8').includes(s.match)) { console.log('stale signature ' + s.id) }
  }
  for (const h of MYSPEC_HOOKS) {
    if (!retired.includes(h) && !existsSync('$HOOKS_DIR/' + h)) { console.log('unknown hook ' + h) }
  }
" 2>&1)
expect_empty "every signature is a literal substring of its hook"
OUTPUT=$(cd "$HOOKS_DIR" && for h in *.sh; do grep -q "'$h'" "$SCRIPT" || echo "not in MYSPEC_HOOKS: $h"; done)
expect_empty "every shipped hook is in MYSPEC_HOOKS"

printf 'friction-scan: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
