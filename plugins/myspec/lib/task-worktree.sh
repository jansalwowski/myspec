#!/usr/bin/env bash
# task-worktree.sh
# Creates a provisioned worktree for one parallel plan task from the
# CONTROLLER's HEAD, and merges it back at the barrier (issue #93). The
# harness `isolation: "worktree"` forks from the default branch, so a task in
# any phase after the first cannot see the feature commits it builds on.
#
# Usage (run from the controller's checkout, on the feature branch):
#   .claude/lib/task-worktree.sh create <slug> [--no-link-modules]
#   .claude/lib/task-worktree.sh merge  <slug> [--keep]
#
# create   adds <main-checkout>/.claude/worktrees/<slug> on a new branch
#          `<feature-branch>--<slug>` at the controller's HEAD, then runs
#          worktree-provision.sh with the controller's checkout as the link
#          source — its node_modules already matches the feature's lockfile.
#          --no-link-modules is passed through: use it when the task runs
#          codegen that writes into node_modules, then install for real.
#          Prints the worktree path as the last line.
# merge    merges the task branch into the controller's current branch. On a
#          conflict it stops with the merge in progress: resolve, commit, and
#          run merge again to clean up. Then removes the worktree and deletes
#          the branch, unless --keep.
#
# Commit the controller's work before `create`: uncommitted changes are not in
# the task worktree. Recipe: skills/_shared/worktree-provisioning.md

set -euo pipefail

usage() {
  echo "usage: task-worktree.sh create <slug> [--no-link-modules] | merge <slug> [--keep]" >&2
  exit 1
}

[ $# -ge 2 ] || usage
CMD="$1"
SLUG="$2"
shift 2

case "$SLUG" in
  ''|*[!A-Za-z0-9._-]*|-*) echo "task-worktree: slug must match [A-Za-z0-9._-]+ (got '$SLUG')" >&2; exit 1 ;;
esac

NO_LINK=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-link-modules) NO_LINK="--no-link-modules"; shift ;;
    --keep) KEEP=1; shift ;;
    *) usage ;;
  esac
done

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONTROLLER=$(git rev-parse --show-toplevel)
COMMON=$(git rev-parse --path-format=absolute --git-common-dir)
MAIN=$(dirname "$COMMON")
WT="$MAIN/.claude/worktrees/$SLUG"

case "$CMD" in
  create)
    CURRENT=$(git -C "$CONTROLLER" branch --show-current)
    [ -n "$CURRENT" ] || { echo "task-worktree: controller is on a detached HEAD — check out the feature branch" >&2; exit 1; }
    BRANCH="$CURRENT--$SLUG"
    [ ! -e "$WT" ] || { echo "task-worktree: $WT already exists" >&2; exit 1; }
    if git -C "$CONTROLLER" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      echo "task-worktree: branch $BRANCH already exists" >&2; exit 1
    fi
    if [ -n "$(git -C "$CONTROLLER" status --porcelain --untracked-files=no)" ]; then
      echo "task-worktree: warning — uncommitted changes in $CONTROLLER are not in the task worktree"
    fi
    HEAD_SHA=$(git -C "$CONTROLLER" rev-parse HEAD)
    mkdir -p "$(dirname "$WT")"
    git -C "$CONTROLLER" worktree add -q -b "$BRANCH" "$WT" "$HEAD_SHA"
    "$HERE/worktree-provision.sh" "$WT" --base "$HEAD_SHA" --main "$CONTROLLER" ${NO_LINK:+"$NO_LINK"}
    echo "$WT"
    ;;
  merge)
    [ -d "$WT" ] || { echo "task-worktree: no worktree at $WT" >&2; exit 1; }
    BRANCH=$(git -C "$WT" branch --show-current)
    [ -n "$BRANCH" ] || { echo "task-worktree: $WT is on a detached HEAD" >&2; exit 1; }
    if [ -n "$(git -C "$WT" status --porcelain)" ]; then
      echo "task-worktree: $WT has uncommitted changes — the task must commit before merge" >&2; exit 1
    fi
    if ! git -C "$CONTROLLER" merge --no-edit "$BRANCH"; then
      echo "task-worktree: merge of $BRANCH conflicted — resolve, commit, then rerun merge $SLUG" >&2
      exit 1
    fi
    if [ "$KEEP" -eq 0 ]; then
      git -C "$CONTROLLER" worktree remove "$WT"
      git -C "$CONTROLLER" branch -q -d "$BRANCH"
      echo "task-worktree: merged $BRANCH, removed $WT"
    else
      echo "task-worktree: merged $BRANCH, kept $WT"
    fi
    ;;
  *) usage ;;
esac
