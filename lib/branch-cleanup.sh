#!/usr/bin/env bash
# branch-cleanup.sh
# Audits, and on request removes, agent worktrees and the branches behind them.
#
# WHY THIS EXISTS AS A SCRIPT
# `git branch -d` refuses to delete anything it considers unmerged, and a
# squash merge — this project's merge strategy — never makes a branch an
# ancestor of the base. So every merged agent branch looks unmerged, `-d`
# refuses, and cleanup either stalls or reaches for `-D`, which throws away
# git's safety net entirely. This script earns the right to use `-D` by
# proving containment itself, and refuses when it cannot.
#
# It also keeps that capability off the copyable-bypass path: the git calls
# happen in this child process, which guard-worktree-context.sh never inspects.
# The audited flow holds the capability, not a string any agent can repeat.
#
# TWO PROOFS OF CONTAINMENT — either one is sufficient
#   A (local, no network): every path the branch touched is byte-identical in
#     the base. Survives squash merges, needs no remote.
#   B (remote): a MERGED PR exists for the branch AND the local tip equals that
#     PR's headRefOid. The tip check is load-bearing: without it, a branch that
#     was merged and then had new commits pushed reads as "merged" and its
#     unmerged work is destroyed.
#   C (local): every commit has a patch-equivalent upstream (`git cherry`).
#     Covers commits cherry-picked into the base, which A and B both miss.
# A alone is incomplete: once later PRs touch the same files, the base moves on
# and content equivalence stops holding for a branch that really did merge.
# B alone is unsafe. C does not survive a squash merge (patch-ids change), so it
# supplements rather than replaces. Together they classify correctly and fail
# toward KEEP.
#
# HARD VETOES — any one keeps the branch, before proofs are considered
#   - it is the current branch, or the base branch
#   - its worktree has uncommitted or untracked files
#   - its worktree was touched in the last hour (possibly a live session)
#   - it was never pushed and has no merged PR
#   - it has commits ahead of its remote-tracking ref
#
# Usage:
#   branch-cleanup.sh                              audit every candidate (default)
#   branch-cleanup.sh --apply --branch <name>...   remove the named ones
#   branch-cleanup.sh [--base <ref>] [--no-fetch] [--json]
#
# Deletion is never bulk: --apply requires each branch to be named, and every
# candidate is re-verified at apply time.

set -uo pipefail

BASE=""
APPLY=0
DO_FETCH=1
AS_JSON=0
NAMED_BRANCHES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)    APPLY=1; shift ;;
    --branch)   NAMED_BRANCHES+=("${2:-}"); shift 2 ;;
    --base)     BASE="${2:-}"; shift 2 ;;
    --no-fetch) DO_FETCH=0; shift ;;
    --json)     AS_JSON=1; shift ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *)          echo "branch-cleanup: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "branch-cleanup: not inside a git repository" >&2
  exit 2
}

# Worktrees are what this script removes; running from inside one would delete
# the ground it stands on.
if [ -f "$REPO_ROOT/.git" ]; then
  echo "branch-cleanup: run this from the main checkout, not a worktree" >&2
  exit 2
fi

if [ -z "$BASE" ]; then
  BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  [ -n "$BASE" ] || BASE=develop
fi

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "branch-cleanup: base ref '$BASE' does not exist" >&2
  exit 2
fi

# Remote branches are deleted on merge here, leaving stale remote-tracking refs
# that would make an "ahead of origin" test compare against a ghost.
if [ "$DO_FETCH" -eq 1 ]; then
  git fetch --quiet --prune origin 2>/dev/null || true
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

worktree_for_branch() {
  git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$1" '
    /^worktree /  { path = $2 }
    /^branch /    { if ($2 == want) { print path; exit } }
  '
}

# Echoes the merged PR head SHA, or nothing.
merged_pr_head() {
  command -v gh >/dev/null 2>&1 || return 0
  gh pr list --head "$1" --state merged --json headRefOid --limit 1 2>/dev/null \
    | jq -r '.[0].headRefOid // empty' 2>/dev/null
}

merged_pr_number() {
  command -v gh >/dev/null 2>&1 || return 0
  gh pr list --head "$1" --state merged --json number --limit 1 2>/dev/null \
    | jq -r '.[0].number // empty' 2>/dev/null
}

# Proof A: every path the branch introduced is byte-identical in the base.
content_equivalent() {
  local br="$1" mb
  local -a paths=()

  mb=$(git merge-base "$BASE" "$br" 2>/dev/null) || return 1

  while IFS= read -r p; do
    [ -n "$p" ] && paths+=("$p")
  done < <(git diff --name-only "$mb" "$br" 2>/dev/null)

  # A branch that introduces nothing is not proof of anything.
  [ "${#paths[@]}" -gt 0 ] || return 1

  git diff --quiet "$br" "$BASE" -- "${paths[@]}" 2>/dev/null
}

# Proof C: every commit on the branch already has a patch-equivalent upstream.
# Covers the case A and B both miss — commits cherry-picked into the base. A
# compares file content, which stops matching as soon as the base moves on; B
# compares the tip against the merged PR head, which differs the moment a
# commit is picked elsewhere. Neither can tell "behind" from "unmerged", and
# both fail toward KEEP, so such a branch is held forever.
#
# Not a replacement for A or B: a squash merge rewrites patch-ids, so
# `git cherry` reports `+` for every commit of a squash-merged branch.
#
# Patch-ids cover the diff and its file paths, so a `-` means this same change
# to this same file is already upstream — contained in substance even if it
# arrived by another route.
patches_upstream() {
  local br="$1" out

  out=$(git cherry "$BASE" "$br" 2>/dev/null) || return 1

  # No commits relative to the base proves nothing.
  [ -n "$out" ] || return 1

  ! printf '%s\n' "$out" | grep -q '^+'
}

# Sets VERDICT, PROOF, DETAIL for one branch.
classify() {
  local br="$1"
  VERDICT=KEEP
  PROOF=""
  DETAIL=""

  WT=$(worktree_for_branch "$br")

  if [ "$br" = "$CURRENT" ]; then
    DETAIL="current branch"
    return
  fi

  if [ "$br" = "$BASE" ]; then
    DETAIL="base branch"
    return
  fi

  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if [ -n "$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
      DETAIL="worktree has uncommitted or untracked files"
      return
    fi

    local age
    age=$(( $(date +%s) - $(stat -f %m "$WT" 2>/dev/null || stat -c %Y "$WT" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 3600 ]; then
      DETAIL="worktree touched $(( age / 60 ))min ago — may be a live session"
      return
    fi
  fi

  local pr_head pr_num tip
  tip=$(git rev-parse "$br")
  pr_head=$(merged_pr_head "$br")
  pr_num=$(merged_pr_number "$br")

  # "Was this branch ever published?" Three independent signals, because each
  # one alone has a blind spot: `git push` without -u sets no upstream config;
  # a merged PR's remote branch is deleted, taking origin/<br> with it.
  local upstream_remote has_remote_ref=0
  upstream_remote=$(git config --get "branch.${br}.remote" 2>/dev/null)
  git rev-parse --verify --quiet "origin/$br" >/dev/null && has_remote_ref=1

  if [ -z "$upstream_remote" ] && [ "$has_remote_ref" -eq 0 ] && [ -z "$pr_head" ]; then
    DETAIL="never pushed and no merged PR — local-only work"
    return
  fi

  # Commits sitting ahead of a remote-tracking ref that still exists.
  if git rev-parse --verify --quiet "origin/$br" >/dev/null; then
    if [ -n "$(git log --oneline "origin/$br..$br" 2>/dev/null)" ]; then
      DETAIL="commits ahead of origin/$br"
      return
    fi
  fi

  if git merge-base --is-ancestor "$br" "$BASE" 2>/dev/null; then
    VERDICT=DELETE
    PROOF="ancestor of $BASE"
    return
  fi

  if content_equivalent "$br"; then
    VERDICT=DELETE
    PROOF="content-equivalent to $BASE"
    return
  fi

  if patches_upstream "$br"; then
    VERDICT=DELETE
    PROOF="every commit patch-equivalent to $BASE"
    return
  fi

  if [ -n "$pr_head" ]; then
    if [ "$pr_head" = "$tip" ]; then
      VERDICT=DELETE
      PROOF="PR #${pr_num} merged, tip matches its head"
      return
    fi
    DETAIL="PR #${pr_num} merged but local tip ${tip:0:8} != PR head ${pr_head:0:8} — work added after the merge"
    return
  fi

  DETAIL="no containment proof (differs from $BASE, no merged PR)"
}

# --- collect candidates -----------------------------------------------------
CANDIDATES=()
if [ "${#NAMED_BRANCHES[@]}" -gt 0 ]; then
  CANDIDATES=("${NAMED_BRANCHES[@]}")
else
  while IFS= read -r b; do
    [ -n "$b" ] && CANDIDATES+=("$b")
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
fi

if [ "$APPLY" -eq 1 ] && [ "${#NAMED_BRANCHES[@]}" -eq 0 ]; then
  echo "branch-cleanup: --apply requires at least one --branch <name>." >&2
  echo "Run without --apply first, then name the branches to remove." >&2
  exit 2
fi

# --- report -----------------------------------------------------------------
DELETABLE=()
JSON_ROWS=()

for br in "${CANDIDATES[@]}"; do
  if ! git rev-parse --verify --quiet "$br" >/dev/null; then
    printf 'MISSING  %-50s (no such branch)\n' "$br" >&2
    continue
  fi

  classify "$br"

  if [ "$VERDICT" = "DELETE" ]; then
    DELETABLE+=("$br")
  fi

  if [ "$AS_JSON" -eq 1 ]; then
    JSON_ROWS+=("$(jq -n --arg b "$br" --arg v "$VERDICT" --arg p "$PROOF" \
      --arg d "$DETAIL" --arg w "$WT" \
      '{branch:$b, verdict:$v, proof:$p, detail:$d, worktree:$w}')")
  else
    if [ "$VERDICT" = "DELETE" ]; then
      printf 'DELETE   %-50s %s\n' "$br" "$PROOF"
    else
      printf 'KEEP     %-50s %s\n' "$br" "$DETAIL"
    fi
    [ -n "$WT" ] && printf '         %-50s worktree: %s\n' "" "$WT"
  fi
done

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "${JSON_ROWS[@]}" | jq -s .
fi

if [ "$APPLY" -eq 0 ]; then
  if [ "$AS_JSON" -eq 0 ]; then
    printf '\n%d of %d candidate(s) provably contained in %s.\n' \
      "${#DELETABLE[@]}" "${#CANDIDATES[@]}" "$BASE"
    printf 'Re-run with --apply and one --branch <name> per branch to remove them.\n'
  fi
  exit 0
fi

# --- apply ------------------------------------------------------------------
FAILED=0

for br in "${CANDIDATES[@]}"; do
  # Re-verify: the audit output the operator approved may be minutes old.
  classify "$br"

  if [ "$VERDICT" != "DELETE" ]; then
    printf 'SKIP     %-50s %s\n' "$br" "$DETAIL"
    FAILED=1
    continue
  fi

  if [ -n "$WT" ] && [ -d "$WT" ]; then
    # Never --force: git's own dirty-tree refusal is a backstop worth keeping.
    if git worktree remove "$WT" 2>/dev/null; then
      printf 'REMOVED  worktree %s\n' "$WT"
    else
      printf 'SKIP     %-50s worktree removal refused (%s)\n' "$br" "$WT"
      FAILED=1
      continue
    fi
  fi

  # -d first; -D only because a proof held, and only after -d refuses.
  if git branch -d "$br" 2>/dev/null; then
    printf 'DELETED  %-50s (%s)\n' "$br" "$PROOF"
  elif git branch -D "$br" 2>/dev/null; then
    printf 'DELETED  %-50s (%s, squash-merged)\n' "$br" "$PROOF"
  else
    printf 'FAILED   %-50s branch deletion refused\n' "$br"
    FAILED=1
  fi
done

git worktree prune

exit "$FAILED"
