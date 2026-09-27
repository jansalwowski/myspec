#!/usr/bin/env bash
# Regression fixture for task-worktree.sh (and worktree-provision.sh's
# --no-symlink flag).
#
# Issue #93: harness worktree isolation forks from the default branch, so a
# parallel task in any later phase could not see the feature commits it built
# on. The properties under test: a task worktree starts at the CONTROLLER's
# HEAD, is provisioned from the controller's checkout, merges back onto the
# feature branch, and leaves no worktree or branch behind; every symlink entry
# can be refused for tasks that would write through a linked directory.
#
# Builds a synthetic repo; no network.
# Usage: task-worktree.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../task-worktree.sh}"

if [ ! -x "$SCRIPT" ]; then
  echo "FATAL: script not executable: $SCRIPT" >&2
  exit 1
fi

# `pwd -P` matters: macOS mktemp hands back /var/..., git reports /private/var/...
ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
mkdir -p "$REPO"
trap 'rm -rf "$ROOT"' EXIT

cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t
printf '.eslintcache\nnode_modules\n.claude/worktrees/\n' > .gitignore
echo '{"lockfileVersion": 1}' > package-lock.json
echo '{"name": "x"}' > package.json
echo "base" > shared.js
git add -A
git commit -qm init
mkdir -p node_modules
echo "cache" > .eslintcache

PASS=0
FAIL=0

ok() {  # ok <condition-desc> <0|1>
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$1" >&2
  fi
}

# The controller works in its own feature worktree, one commit ahead of main.
CTRL="$REPO/.claude/worktrees/feat-x"
git worktree add -q -b feat/x "$CTRL" main
"$(dirname "$SCRIPT")/worktree-provision.sh" "$CTRL" --base main >/dev/null
cd "$CTRL" || exit 1
echo "feature" > feature.js
git add feature.js
git commit -qm "feat: phase 1"
FEAT_HEAD=$(git rev-parse HEAD)

# --- create: from the controller's HEAD, provisioned ---------------------------
OUT=$("$SCRIPT" create t2 2>&1); ok "create t2 exits 0 (output: $OUT)" $?
T2="$REPO/.claude/worktrees/t2"
[ "$(printf '%s\n' "$OUT" | tail -1)" = "$T2" ]; ok "create prints the worktree path last" $?
[ "$(git -C "$T2" rev-parse HEAD)" = "$FEAT_HEAD" ]; ok "task worktree starts at the controller's HEAD, not main" $?
[ -f "$T2/feature.js" ]; ok "task worktree sees the feature commit" $?
[ "$(git -C "$T2" branch --show-current)" = "feat/x--t2" ]; ok "task branch is named <feature-branch>--<slug>" $?
[ -L "$T2/node_modules" ]; ok "node_modules is linked" $?
[ "$(cd "$T2/node_modules" && pwd -P)" = "$REPO/node_modules" ]; ok "the link resolves to a real install" $?
[ -f "$T2/.eslintcache" ] && [ ! -L "$T2/.eslintcache" ]; ok "lint cache is copied" $?

"$SCRIPT" create t3 >/dev/null 2>&1; ok "create t3 exits 0" $?
T3="$REPO/.claude/worktrees/t3"

"$SCRIPT" create t2 >/dev/null 2>&1
[ $? -ne 0 ]; ok "an existing slug is refused" $?
"$SCRIPT" create "bad/slug" >/dev/null 2>&1
[ $? -ne 0 ]; ok "a slug with a slash is refused" $?

# --- merge: each task commits, controller merges one at a time ---------------
echo "a" > "$T2/a.js"; git -C "$T2" add a.js; git -C "$T2" commit -qm "feat: task 2"
echo "b" > "$T3/b.js"; git -C "$T3" add b.js; git -C "$T3" commit -qm "feat: task 3"

echo "dirty" > "$T3/untracked.js"
"$SCRIPT" merge t3 >/dev/null 2>&1
[ $? -ne 0 ]; ok "merge refuses a task worktree with uncommitted changes" $?
rm "$T3/untracked.js"

"$SCRIPT" merge t2 >/dev/null 2>&1; ok "merge t2 exits 0" $?
"$SCRIPT" merge t3 >/dev/null 2>&1; ok "merge t3 exits 0" $?
[ -f "$CTRL/a.js" ] && [ -f "$CTRL/b.js" ]; ok "both tasks landed on the feature branch" $?
[ "$(git -C "$CTRL" branch --show-current)" = "feat/x" ]; ok "controller stays on the feature branch" $?
[ ! -e "$T2" ] && [ ! -e "$T3" ]; ok "merged worktrees are removed" $?
! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/x--t2; ok "merged task branch is deleted" $?
[ -z "$(git -C "$REPO" branch --show-current | grep -v '^main$')" ]; ok "main checkout never changed branch" $?

# --- conflict: stop with the merge in progress, rerun cleans up -----------------
"$SCRIPT" create t6 >/dev/null 2>&1
"$SCRIPT" create t7 >/dev/null 2>&1
T6="$REPO/.claude/worktrees/t6"
T7="$REPO/.claude/worktrees/t7"
echo "six" > "$T6/shared.js"; git -C "$T6" commit -qam "t6"
echo "seven" > "$T7/shared.js"; git -C "$T7" commit -qam "t7"
"$SCRIPT" merge t6 >/dev/null 2>&1; ok "first overlapping merge succeeds" $?
"$SCRIPT" merge t7 >/dev/null 2>&1
[ $? -ne 0 ]; ok "conflicting merge exits non-zero" $?
[ -d "$T7" ]; ok "conflicting task worktree is kept" $?
echo "resolved" > "$CTRL/shared.js"
git -C "$CTRL" add shared.js
git -C "$CTRL" commit -qm "merge t7" --no-edit
"$SCRIPT" merge t7 >/dev/null 2>&1; ok "rerun after resolution exits 0" $?
[ ! -e "$T7" ]; ok "rerun removes the resolved worktree" $?

# --- --no-symlink skips every symlink entry, not just node_modules --------------
if command -v jq >/dev/null 2>&1; then
  printf '{"isolation":{"provision":{"symlink":["node_modules","vendor"]}}}\n' > "$CTRL/.myspec.json"
  mkdir -p "$CTRL/vendor"
fi
OUT=$("$SCRIPT" create t4 --no-symlink 2>&1); ok "create --no-symlink exits 0" $?
[ ! -e "$REPO/.claude/worktrees/t4/node_modules" ]; ok "--no-symlink leaves node_modules absent" $?
printf '%s' "$OUT" | grep -qF "run a real install"; ok "--no-symlink says to install" $?
if command -v jq >/dev/null 2>&1; then
  [ ! -e "$REPO/.claude/worktrees/t4/vendor" ]; ok "--no-symlink leaves a non-node entry absent" $?
  "$SCRIPT" create t5 >/dev/null 2>&1; ok "create t5 exits 0" $?
  [ -L "$REPO/.claude/worktrees/t5/vendor" ]; ok "without the flag a non-node entry is linked" $?
fi

"$SCRIPT" merge t4 --keep >/dev/null 2>&1; ok "merge --keep of an empty task exits 0" $?
[ -d "$REPO/.claude/worktrees/t4" ]; ok "--keep leaves the worktree" $?

# --- discard: a stale worktree from an interrupted run is cleared for re-dispatch
"$SCRIPT" create t8 >/dev/null 2>&1
echo "partial" > "$REPO/.claude/worktrees/t8/partial.js"
"$SCRIPT" discard t8 >/dev/null 2>&1; ok "discard exits 0 on a dirty worktree" $?
[ ! -e "$REPO/.claude/worktrees/t8" ]; ok "discard removes the worktree" $?
! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/x--t8; ok "discard deletes the task branch" $?
"$SCRIPT" discard t8 >/dev/null 2>&1; ok "discard of nothing is a no-op" $?
"$SCRIPT" create t8 >/dev/null 2>&1; ok "create after discard succeeds" $?

# --- a failed provision leaves nothing behind ---------------------------------
STUB="$ROOT/stub"
mkdir -p "$STUB"
cp "$SCRIPT" "$STUB/task-worktree.sh"
printf '#!/bin/sh\nexit 1\n' > "$STUB/worktree-provision.sh"
chmod +x "$STUB"/*.sh
"$STUB/task-worktree.sh" create t9 >/dev/null 2>&1
[ $? -ne 0 ]; ok "create fails when provisioning fails" $?
[ ! -e "$REPO/.claude/worktrees/t9" ]; ok "failed create removes its worktree" $?
! git -C "$REPO" show-ref --verify --quiet refs/heads/feat/x--t9; ok "failed create deletes its branch" $?

# --- uncommitted controller changes are named -----------------------------------
echo "wip" >> "$CTRL/feature.js"
OUT=$("$SCRIPT" create t10 2>&1)
printf '%s' "$OUT" | grep -qF "feature.js"; ok "the dirty-tree warning lists the uncommitted file" $?
git -C "$CTRL" checkout -q -- feature.js

# --- isolation.worktreeRoot is honored ------------------------------------------
if command -v jq >/dev/null 2>&1; then
  printf '{"isolation":{"worktreeRoot":".wt/"}}\n' > "$REPO/.myspec.json"
  OUT=$("$SCRIPT" create t11 2>&1)
  [ "$(printf '%s\n' "$OUT" | tail -1)" = "$REPO/.wt/t11" ]; ok "create uses isolation.worktreeRoot (output: $OUT)" $?
  "$SCRIPT" discard t11 >/dev/null 2>&1
  [ ! -e "$REPO/.wt/t11" ]; ok "discard resolves the same root" $?
  rm -f "$REPO/.myspec.json"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
