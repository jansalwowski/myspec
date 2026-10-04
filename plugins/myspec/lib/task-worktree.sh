#!/usr/bin/env bash
# task-worktree.sh
# Creates a provisioned worktree for one parallel plan task from the
# CONTROLLER's HEAD, and merges it back at the barrier (issue #93). The
# harness `isolation: "worktree"` forks from the default branch, so a task in
# any phase after the first cannot see the feature commits it builds on.
#
# Usage (run from the controller's checkout, on the feature branch):
#   .claude/lib/task-worktree.sh create <slug> [--no-symlink]
#   .claude/lib/task-worktree.sh merge  <slug> [--keep]
#   .claude/lib/task-worktree.sh discard <slug>
#
# create   adds <main-checkout>/<worktreeRoot>/<slug> (`isolation.worktreeRoot`
#          in .myspec.json, default .claude/worktrees) on a new branch
#          `<feature-branch>--<slug>` at the controller's HEAD, then runs
#          worktree-provision.sh with the controller's checkout as the link
#          source — its linked dependency directories already match the feature's
#          lockfiles.
#          Task worktrees run `isolation.provision.install` too, one after
#          another; a failing install step fails the create.
#          --no-symlink is passed through: use it when the task writes into
#          a linked directory (code generation into node_modules, vendor,
#          .venv, ...), then install for real.
#          Prints the worktree path as the last line. A failed create leaves
#          no worktree or branch behind.
# merge    merges the task branch into the controller's current branch. On a
#          conflict it stops with the merge in progress: resolve, commit, and
#          run merge again to clean up. Then removes the worktree and deletes
#          the branch, unless --keep.
# discard  force-removes the worktree and deletes its branch, discarding any
#          work in it — for a stale task worktree left by an interrupted run
#          before the task is re-dispatched. No-op when neither exists.
#
# Commit the controller's work before `create`: uncommitted changes are not in
# the task worktree. Recipe: skills/_shared/worktree-provisioning.md

set -euo pipefail

usage() {
  echo "usage: task-worktree.sh create <slug> [--no-symlink] | merge <slug> [--keep] | discard <slug>" >&2
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
    --no-symlink) NO_LINK="--no-symlink"; shift ;;
    --keep) KEEP=1; shift ;;
    *) usage ;;
  esac
done

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/hook-core.sh
. "$HERE/hook-core.sh"
checkout_facts "$PWD" || { echo "task-worktree: run it from the controller's checkout (not a git work tree: $PWD)" >&2; exit 1; }
CONTROLLER="$CF_ROOT"
# Task worktrees live under the main checkout (checkout_facts). A repository
# without one (a bare repository's worktree) keeps them under the controller.
MAIN="${CF_MAIN:-$CF_ROOT}"
WT_ROOT=".claude/worktrees"
if [ -f "$MAIN/.myspec.json" ] && command -v jq >/dev/null 2>&1; then
  WT_ROOT=$(jq -r '.isolation.worktreeRoot // ".claude/worktrees"' "$MAIN/.myspec.json" 2>/dev/null || echo ".claude/worktrees")
  WT_ROOT="${WT_ROOT%/}"
fi
case "$WT_ROOT" in
  /*) WT="$WT_ROOT/$SLUG" ;;
  *) WT="$MAIN/$WT_ROOT/$SLUG" ;;
esac

case "$CMD" in
  create)
    CURRENT=$(git -C "$CONTROLLER" branch --show-current)
    [ -n "$CURRENT" ] || { echo "task-worktree: controller is on a detached HEAD — check out the feature branch" >&2; exit 1; }
    BRANCH="$CURRENT--$SLUG"
    [ ! -e "$WT" ] || { echo "task-worktree: $WT already exists" >&2; exit 1; }
    if git -C "$CONTROLLER" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      echo "task-worktree: branch $BRANCH already exists" >&2; exit 1
    fi
    DIRTY=$(git -C "$CONTROLLER" status --porcelain --untracked-files=no)
    if [ -n "$DIRTY" ]; then
      echo "task-worktree: warning — uncommitted changes in $CONTROLLER are not in the task worktree:"
      printf '%s\n' "$DIRTY" | sed 's/^/  /'
    fi
    HEAD_SHA=$(git -C "$CONTROLLER" rev-parse HEAD)
    mkdir -p "$(dirname "$WT")"
    git -C "$CONTROLLER" worktree add -q -b "$BRANCH" "$WT" "$HEAD_SHA"
    # Undo a half-made worktree so a retry is not refused as "already exists".
    trap 'git -C "$CONTROLLER" worktree remove --force "$WT" 2>/dev/null; git -C "$CONTROLLER" branch -q -D "$BRANCH" 2>/dev/null' EXIT
    "$HERE/worktree-provision.sh" "$WT" --base "$HEAD_SHA" --main "$CONTROLLER" ${NO_LINK:+"$NO_LINK"}
    trap - EXIT
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
  discard)
    if [ -e "$WT" ]; then
      BRANCH=$(git -C "$WT" branch --show-current 2>/dev/null || true)
      git -C "$CONTROLLER" worktree remove --force "$WT"
    else
      CURRENT=$(git -C "$CONTROLLER" branch --show-current)
      BRANCH="${CURRENT:+$CURRENT--$SLUG}"
    fi
    if [ -n "$BRANCH" ] && git -C "$CONTROLLER" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git -C "$CONTROLLER" branch -q -D "$BRANCH"
    fi
    echo "task-worktree: discarded $SLUG"
    ;;
  *) usage ;;
esac
