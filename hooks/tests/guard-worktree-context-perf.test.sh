#!/usr/bin/env bash
# Timing regression for guard-worktree-context.sh (#524). The hook runs at
# PreToolUse of every Bash call, and started one grep per pattern per
# statement: 1,083 for a 120-statement command with no decision, 3,783 in
# worktree mode, where the blockInMain list is matched too. That took 10 to
# 30 s on macOS. The patterns are now matched by bash itself and a call costs
# about a second; the bounds below leave a slow CI runner room, while the old
# cost overshoots them. Each case also checks the decision, so a fast hook
# that lets everything through cannot pass.
#
# Usage: guard-worktree-context-perf.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../guard-worktree-context.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# A main checkout; session "wt" has chosen worktree isolation, "none" nothing.
REPO="$ROOT/checkout"
mkdir -p "$REPO/.claude/state/sessions"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
# A project entry with a GNU escape (\s), which the macOS regex library
# lacks: the hook still hands it to grep.
printf '{"aiDir":".ai","frameworkVersion":"3.0.0","isolation":{"blockInMain":["^make\\\\s+deploy$"]}}\n' > "$REPO/.myspec.json"
printf '{"t":"isolation","mode":"worktree","path":"","note":"","at":%d}\n' \
  "$(date +%s)" > "$REPO/.claude/state/sessions/wt.jsonl"

# timed <session-id> <command> -> runs the hook once from the main checkout;
# ELAPSED is the whole seconds it took, GOT is allow or block.
timed() {
  local start=$SECONDS out
  out=$(jq -nc --arg s "$1" --arg c "$REPO" --arg cmd "$2" \
    '{hook_event_name: "PreToolUse", session_id: $s, tool_name: "Bash", cwd: $c, tool_input: {command: $cmd}}' \
    | bash "$HOOK" 2>/dev/null)
  ELAPSED=$((SECONDS - start))
  case "$out" in
    '') GOT=allow ;;
    *'"deny"'*) GOT=block ;;
    *) GOT=noisy ;;
  esac
}

check() {  # check <bound seconds> <want> <desc>
  if [ "$ELAPSED" -le "$1" ]; then ok; else fail "$3: ${ELAPSED}s, bound ${1}s"; fi
  if [ "$GOT" = "$2" ]; then ok; else fail "$3: want $2, got $GOT"; fi
}

# 120 statements, none of them git: 60 lines of `echo; grep || true`.
CMD=""
for i in $(seq 1 60); do CMD="${CMD}echo step $i; grep -c foo file$i.txt || true"$'\n'; done

timed none 'ls'
check 2 allow "ls, no decision"
timed wt 'ls -la lib | head -5'
check 2 allow "a pipeline, worktree mode"

timed none "$CMD"
check 4 allow "120 statements, no decision"
timed wt "$CMD"
check 4 allow "120 statements, worktree mode"

# The same statements with a blocked one last: every statement is still read.
timed none "${CMD}git checkout develop"
check 4 block "120 statements then a branch switch, no decision"
timed wt "${CMD}npm install"
check 4 block "120 statements then an install, worktree mode"
timed wt "${CMD}make  deploy"
check 4 block "120 statements then a project entry with a GNU escape, worktree mode"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
