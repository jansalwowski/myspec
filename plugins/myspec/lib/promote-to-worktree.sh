#!/usr/bin/env bash
# promote-to-worktree.sh
# Moves develop-mode work (an uncommitted diff in the main checkout) onto a
# branch in a fresh linked worktree, commits, pushes, and opens a PR — without
# disturbing the main checkout.
#
# The main checkout never changes branch. Since the promoted diff now lives on
# the branch, it is also restored here by default — leaving it behind meant
# every promotion armed a conflict that fired at the next `git pull`.
#
# Usage:
#   .claude/lib/promote-to-worktree.sh \
#     --branch fix/lang-switcher-visibility \
#     --title  "fix(i18n): hide the switcher for unpublished locales" \
#     [--base <branch>] [--only <path>]... \
#     [--body-file <path>] [--commit-body-file <path>] \
#     [--trailer "<Key: value>"]... [--session-url <url>] \
#     [--keep-tree] [--clear] [--no-pr]
#
# --base       the integration branch (default: origin/HEAD's branch, else main)
# --only       limit the promotion to these paths (repeatable). REQUIRED whenever
#              the checkout holds work that is not this session's — concurrent
#              agents and the user's own WIP share the main checkout, and an
#              unscoped promotion silently bundles all of it into one PR.
# --trailer    a commit trailer line (repeatable), e.g. Co-Authored-By
# --keep-tree  leave the promoted diff in the main checkout after pushing. Use
#              when you still need to run the change locally; you then own
#              clearing it (`git restore .`) before pulling once the PR merges.
# --clear      clear an UNSCOPED promotion too (see safety note)
# --no-pr      push the branch but skip `gh pr create`
#
# Safety: clearing an UNSCOPED promotion (no --only) would `git restore .`
# across the whole tree, taking concurrent agents' WIP with it. That case is
# never cleared automatically — pass --clear explicitly to accept the blast
# radius.
#
# Provisioning of the new worktree (node_modules link, lint cache) is delegated
# to worktree-provision.sh beside this script; see that file for the rules.

set -euo pipefail

BRANCH=""
BASE=""
TITLE=""
BODY_FILE=""
COMMIT_BODY_FILE=""
SESSION_URL=""
KEEP_TREE=0
FORCE_CLEAR=0
CREATE_PR=1
ONLY_PATHS=()
TRAILERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --branch)           BRANCH="${2:-}"; shift 2 ;;
    --base)             BASE="${2:-}"; shift 2 ;;
    --title)            TITLE="${2:-}"; shift 2 ;;
    --only)             ONLY_PATHS+=("${2:-}"); shift 2 ;;
    --body-file)        BODY_FILE="${2:-}"; shift 2 ;;
    --commit-body-file) COMMIT_BODY_FILE="${2:-}"; shift 2 ;;
    --trailer)          TRAILERS+=("${2:-}"); shift 2 ;;
    --session-url)      SESSION_URL="${2:-}"; shift 2 ;;
    --keep-tree)        KEEP_TREE=1; shift ;;
    --clear)            FORCE_CLEAR=1; shift ;;
    --no-pr)            CREATE_PR=0; shift ;;
    *) echo "promote: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ "$KEEP_TREE" -eq 1 ] && [ "$FORCE_CLEAR" -eq 1 ]; then
  echo "promote: --keep-tree and --clear are mutually exclusive" >&2
  exit 1
fi

if [ "$KEEP_TREE" -eq 1 ]; then
  CLEAR_AFTER=0
elif [ "${#ONLY_PATHS[@]}" -gt 0 ] || [ "$FORCE_CLEAR" -eq 1 ]; then
  CLEAR_AFTER=1
else
  CLEAR_AFTER=0
fi

if [ -z "$BRANCH" ] || [ -z "$TITLE" ]; then
  echo "promote: --branch and --title are required" >&2
  exit 1
fi

if ! printf '%s' "$BRANCH" | grep -qE '^[a-z][a-z0-9]*(/[a-z0-9][a-z0-9._-]*)+$'; then
  echo "promote: --branch must look like 'fix/some-slug' (got '$BRANCH')" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)

if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "promote: must run from the MAIN checkout, not a worktree" >&2
  exit 1
fi

if [ -z "$BASE" ]; then
  BASE=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
  BASE="${BASE#origin/}"
  BASE="${BASE:-main}"
fi

WORKTREE_ROOT=".claude/worktrees"
if [ -f "$REPO_ROOT/.myspec.json" ] && command -v jq >/dev/null 2>&1; then
  WORKTREE_ROOT=$(jq -r '.isolation.worktreeRoot // ".claude/worktrees"' "$REPO_ROOT/.myspec.json" 2>/dev/null)
  WORKTREE_ROOT="${WORKTREE_ROOT%/}"
fi

if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "promote: branch '$BRANCH' already exists" >&2
  exit 1
fi

SLUG="${BRANCH##*/}"
WORKTREE="$REPO_ROOT/$WORKTREE_ROOT/$SLUG"

if [ -e "$WORKTREE" ]; then
  echo "promote: '$WORKTREE' already exists — pick another slug or clean it up" >&2
  exit 1
fi

# Refuse when the agent committed on the base branch: those commits are not in
# the working-tree diff, so the PR would silently miss them. Moving them means
# resetting the local branch, which rewrites the user's history — needs a human.
git -C "$REPO_ROOT" fetch --quiet origin "$BASE" 2>/dev/null || true

if git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
  AHEAD=$(git -C "$REPO_ROOT" rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)

  if [ "$AHEAD" -gt 0 ]; then
    echo "promote: local $BASE is $AHEAD commit(s) ahead of origin/$BASE." >&2
    echo "" >&2
    echo "Those commits are not part of the working-tree diff. Moving them requires" >&2
    echo "cherry-picking into the branch and resetting local $BASE back to" >&2
    echo "origin/$BASE, which rewrites your local branch. Do that deliberately:" >&2
    echo "" >&2
    echo "  git log --oneline origin/$BASE..HEAD    # confirm what would move" >&2
    echo "" >&2
    echo "then ask the user before resetting." >&2
    exit 1
  fi
fi

PATCH=$(mktemp -t promote-patch)
UNTRACKED_LIST=$(mktemp -t promote-untracked)
cleanup() { rm -f "$PATCH" "$UNTRACKED_LIST"; }
trap cleanup EXIT

# Tracked changes, binary-safe. Never touches the working tree. Scoped to
# --only paths when given, so a shared checkout does not leak other agents' or
# the user's unrelated WIP into the PR.
if [ "${#ONLY_PATHS[@]}" -gt 0 ]; then
  git -C "$REPO_ROOT" diff HEAD --binary -- "${ONLY_PATHS[@]}" > "$PATCH"
  git -C "$REPO_ROOT" ls-files --others --exclude-standard -z -- "${ONLY_PATHS[@]}" > "$UNTRACKED_LIST"
else
  git -C "$REPO_ROOT" diff HEAD --binary > "$PATCH"
  git -C "$REPO_ROOT" ls-files --others --exclude-standard -z > "$UNTRACKED_LIST"

  OTHER=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all | wc -l | tr -d ' ')
  echo "promote: no --only given — promoting all $OTHER working-tree entries." >&2
  echo "         If any of them belong to another agent or to unrelated WIP, abort now." >&2
fi

if [ ! -s "$PATCH" ] && [ ! -s "$UNTRACKED_LIST" ]; then
  echo "promote: nothing to promote — no tracked changes and no untracked files" >&2
  exit 1
fi

# Base the branch on the main checkout's HEAD, not origin/<base>, so the patch
# always applies cleanly even when the local base is stale.
git -C "$REPO_ROOT" worktree add --quiet -b "$BRANCH" "$WORKTREE" HEAD

if [ -s "$PATCH" ]; then
  if ! git -C "$WORKTREE" apply --binary "$PATCH"; then
    echo "promote: patch failed to apply — rolling back the worktree" >&2
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE"
    git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
    exit 1
  fi
fi

UNTRACKED_COUNT=0
while IFS= read -r -d '' REL; do
  mkdir -p "$WORKTREE/$(dirname "$REL")"
  # /bin/cp, not cp — `cp` is shadowed by a shell alias in some environments.
  /bin/cp -p "$REPO_ROOT/$REL" "$WORKTREE/$REL"
  UNTRACKED_COUNT=$(( UNTRACKED_COUNT + 1 ))
done < "$UNTRACKED_LIST"

git -C "$WORKTREE" add -A

if git -C "$WORKTREE" diff --cached --quiet; then
  echo "promote: nothing staged after transfer — rolling back" >&2
  git -C "$REPO_ROOT" worktree remove --force "$WORKTREE"
  git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
  exit 1
fi

COMMIT_MSG=$(mktemp -t promote-commit)
{
  printf '%s\n' "$TITLE"

  if [ -n "$COMMIT_BODY_FILE" ] && [ -f "$COMMIT_BODY_FILE" ]; then
    printf '\n'
    cat "$COMMIT_BODY_FILE"
  fi

  if [ "${#TRAILERS[@]}" -gt 0 ] || [ -n "$SESSION_URL" ]; then
    printf '\n'
  fi

  # ${arr[@]+"${arr[@]}"}: an empty array is "unbound" under set -u in bash < 4.4
  for trailer in ${TRAILERS[@]+"${TRAILERS[@]}"}; do
    printf '%s\n' "$trailer"
  done

  if [ -n "$SESSION_URL" ]; then
    printf 'Claude-Session: %s\n' "$SESSION_URL"
  fi
} > "$COMMIT_MSG"

git -C "$WORKTREE" commit --quiet --file "$COMMIT_MSG"
rm -f "$COMMIT_MSG"

# Provision AFTER the commit, so nothing it links or copies can reach the branch.
PROVISION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-provision.sh"
if [ -x "$PROVISION" ]; then
  "$PROVISION" "$WORKTREE" --base "origin/$BASE" --main "$REPO_ROOT" || true
fi

git -C "$WORKTREE" push --quiet -u origin "$BRANCH"

PR_URL=""
if [ "$CREATE_PR" -eq 1 ]; then
  PR_BODY=$(mktemp -t promote-pr-body)
  {
    if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
      cat "$BODY_FILE"
      printf '\n'
    fi

    if [ -n "$SESSION_URL" ]; then
      printf '\n%s\n' "$SESSION_URL"
    fi
  } > "$PR_BODY"

  PR_URL=$(cd "$WORKTREE" && gh pr create \
    --base "$BASE" --head "$BRANCH" \
    --title "$TITLE" --body-file "$PR_BODY")
  rm -f "$PR_BODY"
fi

if [ "$CLEAR_AFTER" -eq 1 ]; then
  # Restore only what was promoted — never the whole tree, which would wipe
  # concurrent work that was deliberately excluded by --only.
  #
  # `git restore` errors on a path it does not track, and a doc/memory
  # promotion is frequently ALL new files — so narrow to the tracked subset
  # first and skip the call entirely when there is none. Untracked files are
  # handled by the removal loop below, which must still run in that case.
  if [ "${#ONLY_PATHS[@]}" -gt 0 ]; then
    TRACKED_PATHS=()

    while IFS= read -r -d '' REL; do
      TRACKED_PATHS+=("$REL")
    done < <(git -C "$REPO_ROOT" ls-files -z -- "${ONLY_PATHS[@]}")

    if [ "${#TRACKED_PATHS[@]}" -gt 0 ]; then
      git -C "$REPO_ROOT" restore -- "${TRACKED_PATHS[@]}"
    fi
  else
    git -C "$REPO_ROOT" restore .
  fi

  while IFS= read -r -d '' REL; do
    rm -f "$REPO_ROOT/$REL"
  done < "$UNTRACKED_LIST"
fi

echo ""
echo "promoted to $BRANCH (base $BASE)"
echo "  worktree:  $WORKTREE_ROOT/$SLUG"
echo "  untracked: $UNTRACKED_COUNT file(s) copied"

if [ -n "$PR_URL" ]; then
  echo "  PR:        $PR_URL"
fi

echo ""
if [ "$CLEAR_AFTER" -eq 1 ]; then
  echo "Main checkout restored — the diff now lives only on the branch. Nothing to clear later."
elif [ "$KEEP_TREE" -eq 1 ]; then
  echo "Main checkout still holds the changes (--keep-tree), still on $BASE."
  echo "Once the PR merges, run 'git restore .' before pulling $BASE or the pull will conflict."
else
  echo "Main checkout still holds the changes — unscoped promotion, so it was not cleared."
  echo "Re-run with --only <path> to get automatic clearing, or clear by hand once the PR merges."
fi
