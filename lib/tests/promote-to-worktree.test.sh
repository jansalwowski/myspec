#!/usr/bin/env bash
# Regression fixture for promote-to-worktree.sh and worktree-provision.sh.
#
# A promoted worktree has to be verifiable the moment it exists, because the
# Stop hook runs lint and tests in whatever tree the session sits in: a bare
# worktree has no node_modules and no lint cache, so verification fails on a
# branch that is otherwise clean (issue #11). The safety property beside it:
# provisioning happens AFTER the commit, so nothing it links or copies can
# reach the branch, and a branch that changes a lockfile gets no node_modules
# link at all — a linked tree would then describe the wrong dependencies.
#
# Builds a synthetic repo with a local bare origin; no network, no gh (--no-pr).
# Usage: promote-to-worktree.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../promote-to-worktree.sh}"

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

printf '.eslintcache\nnode_modules\n.claude/state/\n' > .gitignore
printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > .myspec.json
echo "original" > tracked.js
echo '{"lockfileVersion": 1}' > package-lock.json
git add -A
git commit -qm init

git clone -q --bare . "$ROOT/origin.git"
git remote add origin "$ROOT/origin.git"
git push -q -u origin main >/dev/null 2>&1

# Stand in for a main checkout that has been installed and linted at least once.
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

# --- promotion 1: a tracked edit plus an untracked file -----------------------

echo "changed" > tracked.js
echo "new" > added.js

OUT=$("$SCRIPT" --branch fix/provisioning --title "fix(x): y" \
        --only tracked.js --only added.js --no-pr \
        --trailer "Co-Authored-By: Test Agent <t@t>" 2>&1)
RC=$?

ok "script exits 0 (output: ${OUT})" "$RC"

WT="$REPO/.claude/worktrees/provisioning"
[ -d "$WT" ]; ok "worktree was created under the default worktree root" $?

# --- what verification needs --------------------------------------------------
[ -L "$WT/node_modules" ]; ok "node_modules is symlinked" $?
[ -f "$WT/.eslintcache" ] && [ ! -L "$WT/.eslintcache" ]; ok "lint cache is copied, not linked" $?
EXCLUDE=$(git -C "$WT" rev-parse --git-path info/exclude)
grep -qxF node_modules "$EXCLUDE" 2>/dev/null; ok "node_modules listed in the worktree's info/exclude" $?
grep -qxF .eslintcache "$EXCLUDE" 2>/dev/null; ok ".eslintcache listed in the worktree's info/exclude" $?

# --- nothing provisioned reaches the branch -----------------------------------
git -C "$WT" ls-files --error-unmatch .eslintcache >/dev/null 2>&1
[ $? -ne 0 ]; ok "lint cache is not committed" $?
git -C "$WT" ls-files --error-unmatch added.js >/dev/null 2>&1
ok "the promoted untracked file IS committed" $?
[ "$(git -C "$WT" show HEAD:tracked.js)" = "changed" ]; ok "the tracked edit is on the branch" $?

# --- commit message and remote --------------------------------------------------
git -C "$WT" log -1 --format=%B | grep -qF "Co-Authored-By: Test Agent <t@t>"; ok "trailer reaches the commit message" $?
[ "$(git -C "$WT" log -1 --format=%s)" = "fix(x): y" ]; ok "title is the commit subject" $?
git -C "$ROOT/origin.git" show-ref --verify --quiet refs/heads/fix/provisioning; ok "branch was pushed to origin" $?

# --- the main checkout is restored, still on main -------------------------------
[ "$(git -C "$REPO" branch --show-current)" = "main" ]; ok "main checkout never changed branch" $?
[ "$(cat "$REPO/tracked.js")" = "original" ]; ok "tracked edit restored in the main checkout" $?
[ ! -e "$REPO/added.js" ]; ok "promoted untracked file removed from the main checkout" $?
printf '%s' "$OUT" | grep -qF "base main"; ok "output names the detected base branch" $?

# --- promotion 2: a lockfile change gets no node_modules link -------------------

echo '{"lockfileVersion": 2}' > package-lock.json
OUT2=$("$SCRIPT" --branch chore/lockfile --title "chore(deps): bump" \
        --only package-lock.json --no-pr 2>&1)
ok "lockfile promotion exits 0 (output: ${OUT2})" $?

WT2="$REPO/.claude/worktrees/lockfile"
[ -d "$WT2" ]; ok "second worktree was created" $?
[ ! -e "$WT2/node_modules" ]; ok "node_modules is NOT linked when the branch changes a lockfile" $?
printf '%s' "$OUT2" | grep -qF "not linking node_modules"; ok "provisioning says why it skipped the link" $?
[ -f "$WT2/.eslintcache" ]; ok "the lint cache is still copied" $?

# --- refusals -----------------------------------------------------------------
"$SCRIPT" --branch fix/provisioning --title "dup" --only tracked.js --no-pr >/dev/null 2>&1
[ $? -ne 0 ]; ok "an existing branch is refused" $?
"$SCRIPT" --branch "Bad Name" --title "x" --no-pr >/dev/null 2>&1
[ $? -ne 0 ]; ok "a malformed branch name is refused" $?
"$SCRIPT" --branch fix/empty --title "x" --only tracked.js --no-pr >/dev/null 2>&1
[ $? -ne 0 ]; ok "nothing to promote is refused" $?

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
