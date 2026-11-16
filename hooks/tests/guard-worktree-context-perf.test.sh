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
# lacks: bash gets it as a POSIX class.
printf '{"aiDir":".ai","frameworkVersion":"3.0.0","isolation":{"blockInMain":["^make\\\\s+deploy$"]}}\n' > "$REPO/.myspec.json"
printf '{"t":"isolation","mode":"worktree","path":"","note":"","at":%d}\n' \
  "$(date +%s)" > "$REPO/.claude/state/sessions/wt.jsonl"

# The wall-clock bounds hold on macOS, where a fork is dear; on Linux the old
# cost may fit under them. So a grep first on PATH counts its calls: the
# count does not depend on the runner.
SHIM="$ROOT/bin"
mkdir -p "$SHIM"
REAL_GREP=$(command -v grep)
printf '#!/bin/sh\necho >> "%s/greps"\nexec "%s" "$@"\n' "$ROOT" "$REAL_GREP" > "$SHIM/grep"
chmod +x "$SHIM/grep"

# timed <session-id> <command> -> runs the hook once from the main checkout;
# ELAPSED is the whole seconds it took, GOT is allow or block, GREPS the
# hook's grep calls.
timed() {
  local start=$SECONDS out
  : > "$ROOT/greps"
  out=$(jq -nc --arg s "$1" --arg c "$REPO" --arg cmd "$2" \
    '{hook_event_name: "PreToolUse", session_id: $s, tool_name: "Bash", cwd: $c, tool_input: {command: $cmd}}' \
    | PATH="$SHIM:$PATH" bash "$HOOK" 2>/dev/null)
  ELAPSED=$((SECONDS - start))
  GREPS=$(wc -l < "$ROOT/greps" | tr -d ' ')
  case "$out" in
    '') GOT=allow ;;
    *'"deny"'*) GOT=block ;;
    *) GOT=noisy ;;
  esac
}

check() {  # check <bound seconds> <most greps> <want> <desc>
  if [ "$ELAPSED" -le "$1" ]; then ok; else fail "$4: ${ELAPSED}s, bound ${1}s"; fi
  if [ "$GREPS" -le "$2" ]; then ok; else fail "$4: $GREPS grep calls, at most $2"; fi
  if [ "$GOT" = "$3" ]; then ok; else fail "$4: want $3, got $GOT"; fi
}

# 120 statements, none of them git: 60 lines of `echo; grep || true`.
CMD=""
for i in $(seq 1 60); do CMD="${CMD}echo step $i; grep -c foo file$i.txt || true"$'\n'; done

# No grep while nothing is decided; a block costs two, in the deny path.
timed none 'ls'
check 2 0 allow "ls, no decision"
timed wt 'ls -la lib | head -5'
check 2 0 allow "a pipeline, worktree mode"

timed none "$CMD"
check 4 0 allow "120 statements, no decision"
timed wt "$CMD"
check 4 0 allow "120 statements, worktree mode"

# The same statements with a blocked one last: every statement is still read.
timed none "${CMD}git checkout develop"
check 4 2 block "120 statements then a branch switch, no decision"
timed wt "${CMD}npm install"
check 4 2 block "120 statements then an install, worktree mode"
timed wt "${CMD}make  deploy"
check 4 2 block "120 statements then a project entry with a GNU escape, worktree mode"

# Five entries only grep runs (\b): one grep per statement for all five, not
# one each, plus one per entry to check it once. 16 statements: 16 + 5 + 2
# calls, where one grep per entry would make 82.
jq '.isolation.blockInMain += ["^helm\\b.*\\bupgrade\\b", "^terraform\\b.*\\bapply\\b", "^kubectl\\b.*\\bapply\\b", "^pulumi\\b.*\\bup\\b", "^cdk\\b.*\\bdeploy\\b"]' \
  "$REPO/.myspec.json" > "$ROOT/myspec.json" && mv "$ROOT/myspec.json" "$REPO/.myspec.json"
SHORT=""
for i in 1 2 3 4 5; do SHORT="${SHORT}echo step $i; grep -c foo file$i.txt || true"$'\n'; done
timed wt "${SHORT}pulumi --yes up"
check 4 23 block "15 statements then a grep-only project entry, worktree mode"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
