#!/usr/bin/env bash
# Regression fixture for the feature-implement orchestration marker in
# verify-before-stop.sh (issue #95).
#
# A failing required check must block the stop when no marker exists, must
# only warn (no block decision, a systemMessage instead) while a fresh
# .claude/state/implement-in-progress.json exists, and must block again when
# the marker is stale or unreadable, deleting it so a crashed run cannot
# disable the gate for good.
#
# The marker is the session's, read in the cwd's checkout: a failing check in
# a linked task worktree the session's subagents edited (armed through the
# shared session id) warns like one in the cwd's checkout, and a marker in
# that worktree alone does not downgrade a session whose cwd has none.
#
# Usage: verify-before-stop.test.sh [path-to-hook]

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
printf '{"checks":[{"name":"always-red","command":"echo boom; exit 1","required":true}]}\n' > "$REPO/.claude/verification.json"
MARKER="$REPO/.claude/state/implement-in-progress.json"
SID="vbs-$$"
CHANGED="/tmp/.myspec-code-changed-$SID"
LEDGER="/tmp/.myspec-session-writes-$SID"
trap 'rm -rf "$ROOT"; rm -f "$CHANGED" "$LEDGER"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

run_hook() {
  touch "$CHANGED"
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | bash "$HOOK"
}

write_marker() {  # write_marker <started_at>
  mkdir -p "$(dirname "$MARKER")"
  printf '{"started_at":%s,"feature":"demo"}\n' "$1" > "$MARKER"
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

OUT=$(run_hook)
expect_block "$OUT" "no marker blocks"

write_marker "$(date +%s)"
OUT=$(run_hook)
expect_warn "$OUT" "fresh marker downgrades to warning"
if [ -f "$MARKER" ]; then ok; else fail "fresh marker kept"; fi

write_marker "$(( $(date +%s) - 28801 ))"
OUT=$(run_hook)
expect_block "$OUT" "stale marker blocks"
if [ -f "$MARKER" ]; then fail "stale marker deleted"; else ok; fi

write_marker '"garbage"'
OUT=$(run_hook)
expect_block "$OUT" "unreadable marker blocks"
if [ -f "$MARKER" ]; then fail "unreadable marker deleted"; else ok; fi

write_marker "$(( $(date +%s) + 3600 ))"
OUT=$(run_hook)
expect_block "$OUT" "future-dated marker blocks"

# --- the marker covers the task worktrees the session armed -----------------
rm -f "$MARKER" "$CHANGED"
printf '.claude/state/\n.claude/worktrees/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m checks
TASK="$REPO/.claude/worktrees/t1"
git -C "$REPO" worktree add -q -b main--t1 "$TASK"
run_ledger() {  # run_ledger: a subagent's code write in the task worktree
  printf 'code\t%s\tsrc/a.ts\tagent-1\n' "$TASK" > "$LEDGER"
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$REPO" | bash "$HOOK"
}

OUT=$(run_ledger)
expect_block "$OUT" "no marker: a failure in an armed task worktree blocks"

write_marker "$(date +%s)"
OUT=$(run_ledger)
expect_warn "$OUT" "the cwd's fresh marker downgrades a failure in an armed task worktree"

rm -f "$MARKER"
mkdir -p "$TASK/.claude/state"
printf '{"started_at":%s,"feature":"other"}\n' "$(date +%s)" > "$TASK/.claude/state/implement-in-progress.json"
OUT=$(run_ledger)
expect_block "$OUT" "a marker in the task worktree alone does not downgrade this session"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
