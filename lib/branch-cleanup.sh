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
# UNATTENDED VETOES (--unattended, for callers that remove without asking,
# such as housekeep.sh) — a worktree is also kept when:
#   - git recorded activity in it in the last 24h (HEAD or its reflog in
#     its admin dir: a commit or checkout in a subdirectory never touches
#     the top-level directory the 1h veto reads)
#   - a session event in the last 24h names it (lib/session-event.sh
#     session_claims: a write, a verify, or an isolation decision)
#   - a running process has its working directory inside it
#   - it holds ignored files (.env, local config): `git worktree remove`
#     deletes them, and they exist nowhere else
# Each such DETAIL starts with "may be in use" or "holds ignored files".
#
# Usage:
#   branch-cleanup.sh                              audit every candidate (default)
#   branch-cleanup.sh --apply --branch <name>...   remove the named ones
#   branch-cleanup.sh [--base <ref>] [--no-fetch] [--json] [--unattended]
#
# Deletion is never bulk: --apply requires each branch to be named, and every
# candidate is re-verified at apply time.

set -uo pipefail

BASE=""
APPLY=0
DO_FETCH=1
AS_JSON=0
UNATTENDED=0
NAMED_BRANCHES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)    APPLY=1; shift ;;
    --branch)   NAMED_BRANCHES+=("${2:-}"); shift 2 ;;
    --base)     BASE="${2:-}"; shift 2 ;;
    --no-fetch) DO_FETCH=0; shift ;;
    --json)     AS_JSON=1; shift ;;
    --unattended) UNATTENDED=1; shift ;;
    -h|--help)  sed -n '2,56p' "$0"; exit 0 ;;
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

# The session files the unattended vetoes read live with the main checkout,
# and only lib/session-event.sh reads them.
SESSION_HOME=""
if [ "$UNATTENDED" -eq 1 ]; then
  # shellcheck source=lib/hook-core.sh
  . "$(dirname "${BASH_SOURCE[0]}")/hook-core.sh"
  # shellcheck source=lib/session-event.sh
  . "$(dirname "${BASH_SOURCE[0]}")/session-event.sh"
  SESSION_HOME=$(session_home "$REPO_ROOT") || SESSION_HOME="$REPO_ROOT"
fi

worktree_for_branch() {
  git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$1" '
    /^worktree /  { path = $2 }
    /^branch /    { if ($2 == want) { print path; exit } }
  '
}

# Echoes a file's mtime as a Unix timestamp, or 0.
#
# Chaining `stat -f %m || stat -c %Y` does not work: on GNU, -f is
# --file-system, so it SUCCEEDS on a directory and prints a non-numeric block.
# The || fallback therefore never fires, and the result reaches $(( )), where
# bash reads the word `File` as a variable name and `set -u` aborts the script
# mid-run. Try the GNU form first and validate that what came back is a number.
mtime_of() {
  local p="$1" t
  t=$(stat -c %Y "$p" 2>/dev/null) || t=""
  case "$t" in ''|*[!0-9]*) t=$(stat -f %m "$p" 2>/dev/null) || t="" ;; esac
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  printf '%s' "$t"
}

# Sets PR_HEAD and PR_NUM from the branch's merged PR, or empties them.
# One network call, made only when classify() needs it: the local proofs
# settle most branches, and a repo with hundreds of branches otherwise pays
# a gh round trip for each.
merged_pr() {
  local out
  PR_HEAD="" PR_NUM=""
  command -v gh >/dev/null 2>&1 || return 0
  out=$(gh pr list --head "$1" --state merged --json headRefOid,number --limit 1 2>/dev/null \
    | jq -r '.[0] // empty | "\(.headRefOid) \(.number)"' 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  PR_HEAD="${out%% *}" PR_NUM="${out#* }"
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

  ! grep -q '^+' <<< "$out"
}

# The working directory of every running process, one per line, read once.
# lsof where present (macOS, most Linux), else /proc. Neither: nothing, and
# the other unattended vetoes still hold.
PROCESS_CWDS=""
PROCESS_CWDS_READ=0
process_cwds() {
  local p
  if [ "$PROCESS_CWDS_READ" -eq 0 ]; then
    PROCESS_CWDS_READ=1
    if command -v lsof >/dev/null 2>&1; then
      PROCESS_CWDS=$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    elif [ -d /proc/self ]; then
      PROCESS_CWDS=$(for p in /proc/[0-9]*/cwd; do readlink "$p" 2>/dev/null; done)
    fi
  fi
  printf '%s\n' "$PROCESS_CWDS"
}

# unattended_veto <worktree> -> 0, with DETAIL set, when the worktree may be
# in use or holds files a removal would destroy.
unattended_veto() {
  local wt="$1" phys admin f since
  phys=$(cd "$wt" 2>/dev/null && pwd -P) || phys="$wt"
  since=$(( $(date +%s) - 86400 ))

  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || admin=""
  # Not index: the dirty-tree veto's `git status` may rewrite it, and a
  # staged change is already dirty.
  for f in "$admin/HEAD" "$admin/logs/HEAD"; do
    if [ -n "$admin" ] && [ -e "$f" ] && [ "$(mtime_of "$f")" -ge "$since" ]; then
      DETAIL="may be in use: git activity in the last 24h"
      return 0
    fi
  done

  if session_claims "$SESSION_HOME" "$since" "$wt" "$phys"; then
    DETAIL="may be in use: a session worked in it in the last 24h"
    return 0
  fi

  local cwds ignored
  cwds=$(process_cwds)
  if awk -v a="$wt" -v b="$phys" '
      $0 == a || $0 == b || index($0, a "/") == 1 || index($0, b "/") == 1 { found = 1; exit }
      END { exit !found }' <<< "$cwds"; then
    DETAIL="may be in use: a running process is inside it"
    return 0
  fi

  ignored=$(git -C "$wt" status --porcelain --ignored=matching 2>/dev/null)
  if grep -q '^!!' <<< "$ignored"; then
    DETAIL="holds ignored files that removal would delete"
    return 0
  fi
  return 1
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
    age=$(( $(date +%s) - $(mtime_of "$WT") ))
    if [ "$age" -lt 3600 ]; then
      DETAIL="worktree touched $(( age / 60 ))min ago — may be a live session"
      return
    fi

    if [ "$UNATTENDED" -eq 1 ] && unattended_veto "$WT"; then
      return
    fi
  fi

  local tip pr_looked=0
  tip=$(git rev-parse "$br")
  PR_HEAD="" PR_NUM=""

  # "Was this branch ever published?" Three independent signals, because each
  # one alone has a blind spot: `git push` without -u sets no upstream config;
  # a merged PR's remote branch is deleted, taking origin/<br> with it.
  local upstream_remote has_remote_ref=0
  upstream_remote=$(git config --get "branch.${br}.remote" 2>/dev/null)
  git rev-parse --verify --quiet "origin/$br" >/dev/null && has_remote_ref=1

  if [ -z "$upstream_remote" ] && [ "$has_remote_ref" -eq 0 ]; then
    merged_pr "$br"
    pr_looked=1
    if [ -z "$PR_HEAD" ]; then
      DETAIL="never pushed and no merged PR — local-only work"
      return
    fi
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

  [ "$pr_looked" -eq 1 ] || merged_pr "$br"
  if [ -n "$PR_HEAD" ]; then
    if [ "$PR_HEAD" = "$tip" ]; then
      VERDICT=DELETE
      PROOF="PR #${PR_NUM} merged, tip matches its head"
      return
    fi
    DETAIL="PR #${PR_NUM} merged but local tip ${tip:0:8} != PR head ${PR_HEAD:0:8} — work added after the merge"
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
