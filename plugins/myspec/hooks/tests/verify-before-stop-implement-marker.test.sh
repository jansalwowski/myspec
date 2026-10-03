#!/usr/bin/env bash
# Regression fixture for the feature-implement orchestration state in
# verify-before-stop.sh (issue #95, R6).
#
# A failing required check must block the stop when the session has no
# implement run, must only warn (no block decision, a systemMessage instead)
# while its last `implement` event in the session-state file is a start under
# 8h old, and must block again when that start is stale, unreadable,
# future-dated or followed by a stop, so a crashed run cannot disable the gate
# for good.
#
# The state is the session's own: a failing check in a linked task worktree
# the session's subagents edited (armed through the shared session id) warns
# like one in the cwd's checkout, and another session's run does not
# downgrade this one. The start is recorded by mark-code-changed.sh when a
# Bash command runs `session-event.sh implement start`, with the payload's
# session id: the model never sees it.
#
# Usage: verify-before-stop-implement-marker.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../verify-before-stop.sh}"
MARK="$(cd "$(dirname "$HOOK")" && pwd)/mark-code-changed.sh"
SESSION_EVENT="$(cd "$(dirname "$HOOK")" && pwd)/../lib/session-event.sh"

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
printf '{"checks":[{"name":"always-red","command":"echo boom; exit 1","required":true}]}\n' > "$REPO/.claude/verification.json"
SID="vbs-$$"
STATE="$REPO/.claude/state/sessions"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

wrote() {  # wrote <sid> <root>: a code write in <root>, as mark-code-changed.sh records it
  bash "$SESSION_EVENT" --root "$2" append "$1" "$(jq -nc --arg r "$2" '{t: "write", root: $r, rel: "src/a.ts", kind: "code", agent: "agent-1"}')"
}

run_hook() {  # run_hook [sid] -> hook stdout, after a code write in the cwd's checkout
  wrote "${1:-$SID}" "$REPO"
  printf '{"session_id":"%s","cwd":"%s"}' "${1:-$SID}" "$REPO" | bash "$HOOK"
}

implement() {  # implement <state> <at> [sid]: an implement event dated <at>
  mkdir -p "$STATE"
  printf '{"t":"implement","state":"%s","at":%s}\n' "$1" "$2" >> "$STATE/${3:-$SID}.jsonl"
}

expect_block() {  # expect_block <output> <desc>
  if [ "$(printf '%s' "$1" | jq -r '.decision')" = "block" ]; then ok; else fail "$2 (expected block, got: $1)"; fi
}

expect_warn() {
  if [ "$(printf '%s' "$1" | jq -r '.decision')" != "block" ] \
    && printf '%s' "$1" | jq -e '.systemMessage | test("always-red")' >/dev/null; then
    ok
  else
    fail "$2 (expected non-blocking warning, got: $1)"
  fi
}

NOW=$(date +%s)
OUT=$(run_hook)
expect_block "$OUT" "no implement run blocks"

implement start "$NOW"
OUT=$(run_hook)
expect_warn "$OUT" "a fresh start downgrades to warning"

implement stop "$NOW"
OUT=$(run_hook)
expect_block "$OUT" "a stop ends the downgrade"

implement start "$(( NOW - 28801 ))"
OUT=$(run_hook)
expect_block "$OUT" "a stale start blocks"

implement start '"garbage"'
OUT=$(run_hook)
expect_block "$OUT" "an unreadable start blocks"

implement start "$(( NOW + 3600 ))"
OUT=$(run_hook)
expect_block "$OUT" "a future-dated start blocks"

# The real path: the skill's command, seen by mark-code-changed.sh.
jq -n --arg s "$SID" --arg d "$REPO" \
  '{session_id: $s, tool_name: "Bash", cwd: $d, tool_input: {command: "\"$(git rev-parse --show-toplevel)\"/.claude/lib/session-event.sh implement start"}}' \
  | bash "$MARK" >/dev/null 2>&1
OUT=$(run_hook)
expect_warn "$OUT" "a start recorded by mark-code-changed.sh from the skill's command downgrades"

# --- the state covers the task worktrees the session armed -------------------
rm -rf "$STATE"
printf '.claude/state/\n.claude/worktrees/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m checks
TASK="$REPO/.claude/worktrees/t1"
git -C "$REPO" worktree add -q -b main--t1 "$TASK"
run_task() {  # run_task: a subagent's code write in the task worktree
  wrote "$SID" "$TASK"
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | bash "$HOOK"
}

OUT=$(run_task)
expect_block "$OUT" "no implement run: a failure in an armed task worktree blocks"

implement start "$(date +%s)"
OUT=$(run_task)
expect_warn "$OUT" "the session's start downgrades a failure in an armed task worktree"

implement stop "$(date +%s)"
implement start "$(date +%s)" other-session
OUT=$(run_task)
expect_block "$OUT" "another session's run does not downgrade this session"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
