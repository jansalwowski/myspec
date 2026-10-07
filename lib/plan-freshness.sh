#!/usr/bin/env bash
# plan-freshness.sh
# Git logic behind feature-plan's base sync and feature-implement's plan
# freshness check (#154). Each step here regressed at least once while it
# lived in skill prose (a6cb428, e5b17e0, 04f90a3).
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/lib/plan-freshness.sh base <integration-branch>
#   "${CLAUDE_PLUGIN_ROOT}"/lib/plan-freshness.sh check <planned_against> <integration-branch> [<path>...]
#
# base   Prints the ref that stands for the integration branch's tip:
#        `origin/<branch>` after `git fetch origin <branch>`, or `<branch>`
#        when the repository has no `origin` remote. A local branch is never
#        the ref when a remote exists: the fetch moves only origin/<branch>,
#        so the local one can lag and diff empty.
#        Exit 0 ref printed. Exit 2 the fetch failed or the ref does not
#        resolve; nothing on stdout.
#
# check  Lists the given paths that changed on the integration branch since
#        <planned_against>: `git diff --name-only <sha>...<ref>`, three dots,
#        so the diff runs from the merge base. feature-plan records HEAD after
#        merging the integration branch in, and a two-dot diff would list
#        every file the feature branch itself changed.
#        First stdout line is the verdict:
#          fresh                 exit 0 — no listed path changed
#          stale                 exit 1 — the changed paths follow, one a line
#          unknown: <reason>     exit 2 — the fetch failed, or the sha is not
#                                a commit (rebased or squashed away). Never
#                                read as fresh: `git diff` on a missing sha
#                                exits 128 with empty output.
#        With no paths, every changed file counts.
#
# Exit 64 usage.

set -uo pipefail

usage() {
  echo "usage: plan-freshness.sh base <integration-branch>" >&2
  echo "       plan-freshness.sh check <planned_against> <integration-branch> [<path>...]" >&2
  exit 64
}

# Sets REF to the integration ref, or REASON and returns 2.
REF=""
REASON=""
integration_ref() {
  local branch="$1"
  if git remote get-url origin >/dev/null 2>&1; then
    if ! git fetch -q origin "$branch" >/dev/null 2>&1; then
      REASON="fetch of $branch from origin failed"
      return 2
    fi
    REF="origin/$branch"
  else
    REF="$branch"
  fi
  if ! git rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1; then
    REASON="$REF does not resolve to a commit"
    return 2
  fi
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

case "$CMD" in
  base)
    [ $# -eq 1 ] && [ -n "$1" ] || usage
    if ! integration_ref "$1"; then
      echo "plan-freshness: $REASON" >&2
      exit 2
    fi
    printf '%s\n' "$REF"
    ;;
  check)
    [ $# -ge 2 ] && [ -n "$1" ] && [ -n "$2" ] || usage
    SHA="$1"; BRANCH="$2"; shift 2
    if ! integration_ref "$BRANCH"; then
      echo "unknown: $REASON"
      exit 2
    fi
    if ! git rev-parse --verify --quiet "$SHA^{commit}" >/dev/null 2>&1; then
      echo "unknown: planned_against $SHA not found (rebased or squashed away?)"
      exit 2
    fi
    if ! CHANGED=$(git diff --name-only "$SHA...$REF" -- "$@" 2>/dev/null); then
      echo "unknown: git diff $SHA...$REF failed"
      exit 2
    fi
    if [ -z "$CHANGED" ]; then
      echo "fresh"
      exit 0
    fi
    echo "stale"
    printf '%s\n' "$CHANGED"
    exit 1
    ;;
  *) usage ;;
esac
