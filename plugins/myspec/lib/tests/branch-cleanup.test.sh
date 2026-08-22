#!/usr/bin/env bash
# Regression fixture for branch-cleanup.sh.
#
# The script is allowed to use `git branch -D`, which discards git's own
# unmerged-branch protection. Everything that keeps that safe lives in
# classify(), so classify() needs a fixture that models the ways a branch can
# look merged without being merged.
#
# Builds a synthetic repo with a squash-merge history; no network, no gh, so
# Proof B (merged PR + tip match) is not exercised here — that path is checked
# against real PRs. Proof A and every veto are exercised.
#
# Usage: branch-cleanup.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../branch-cleanup.sh}"

if [ ! -x "$SCRIPT" ]; then
  echo "FATAL: script not executable: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/repo"
mkdir -p "$REPO"
trap 'rm -rf "$ROOT"' EXIT

cd "$REPO" || exit 1
git init -q -b develop .
git config user.email t@t
git config user.name t

seed() { echo "$2" > "$1"; git add -A; git commit -qm "$3"; }
seed base.txt base init

git clone -q --bare . "$ROOT/origin.git"
git remote add origin "$ROOT/origin.git"
git push -q -u origin develop

mkbranch() { git checkout -q -b "$1" develop; }
squash_merge() {
  git checkout -q develop
  git merge -q --squash "$1" >/dev/null 2>&1 || true
  git commit -qm "squash: $1 (#999)"
}

# 1. plain ancestor merge
mkbranch ff-merged;               seed a.txt A "add a"
git checkout -q develop; git merge -q --ff-only ff-merged

# 2. squash-merged, nothing after it
mkbranch squash-clean;            seed b.txt B1 b1; seed b2.txt B2 b2
squash_merge squash-clean

# 3. squash-merged, then more work pushed
mkbranch squash-then-more;        seed c.txt C1 c1
squash_merge squash-then-more
git checkout -q squash-then-more; seed c.txt C2-UNMERGED c2

# 4. never merged at all
mkbranch never-merged;            seed d.txt D d

# 5. squash-merged, then the base moved on over the same file
mkbranch base-moved;              seed e.txt E1 e1
squash_merge base-moved
git checkout -q develop;          seed e.txt E1-later "later edit"

# 6. content merged but the branch was never pushed
mkbranch unpushed;                seed f.txt F f
squash_merge unpushed

# 7 + 8. merged branches that own a worktree
mkbranch wt-clean;                seed g.txt G g
squash_merge wt-clean
mkbranch wt-dirty;                seed h.txt H h
squash_merge wt-dirty

git checkout -q develop
for b in ff-merged squash-clean squash-then-more never-merged base-moved wt-clean wt-dirty; do
  git push -q origin "$b" 2>/dev/null || true
done

git worktree add -q "$ROOT/wt-clean" wt-clean
git worktree add -q "$ROOT/wt-dirty" wt-dirty
echo "scratch notes" > "$ROOT/wt-dirty/NOTES.txt"

# A worktree touched in the last hour is held as a possibly-live session, which
# would mask the checks below; backdate both so the other rules are what decide.
touch -t 202001010000 "$ROOT/wt-clean" "$ROOT/wt-dirty"

# 9. merged branch whose worktree is clean but freshly touched
mkbranch wt-live;                 seed i.txt I i
squash_merge wt-live
git checkout -q develop
git push -q origin wt-live 2>/dev/null || true
git worktree add -q "$ROOT/wt-live" wt-live

# 10. merged branch whose worktree is clean but locked. classify() has no lock
#     veto, so the audit says DELETE — the refusal comes from git at apply
#     time, and the script must surface it rather than escalate to --force.
mkbranch wt-locked;               seed j.txt J j
squash_merge wt-locked
git checkout -q develop
git push -q origin wt-locked 2>/dev/null || true
git worktree add -q "$ROOT/wt-locked" wt-locked
git worktree lock "$ROOT/wt-locked"
touch -t 202001010000 "$ROOT/wt-locked"

RESULT=$("$SCRIPT" --base develop --no-fetch --no-fetch --json 2>/dev/null)

PASS=0
FAIL=0

expect() {  # expect <branch> <verdict> <description>
  local br="$1" want="$2" desc="$3" got
  got=$(printf '%s' "$RESULT" | jq -r --arg b "$br" '.[] | select(.branch==$b) | .verdict')

  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-24s want=%-6s got=%-6s  %s\n' "$br" "$want" "${got:-<none>}" "$desc" >&2
    printf '%s' "$RESULT" | jq -r --arg b "$br" '.[] | select(.branch==$b) | "      detail: \(.detail)"' >&2
  fi
}

expect ff-merged        DELETE "ancestor of base"
expect squash-clean     DELETE "squash-merged, content still equivalent"
expect squash-then-more KEEP   "work added after the squash merge"
expect never-merged     KEEP   "never merged"
expect base-moved       KEEP   "no proof once the base moved on"
expect unpushed         KEEP   "never pushed, no PR"
expect wt-clean         DELETE "merged, worktree clean and idle"
expect wt-dirty         KEEP   "worktree holds an untracked file"
expect wt-live          KEEP   "worktree touched within the hour"
expect wt-locked        DELETE "merged, clean and idle — the lock is enforced at apply time"
expect develop          KEEP   "base and current branch"

# --apply must refuse to act without an explicit branch list.
if "$SCRIPT" --base develop --no-fetch --apply >/dev/null 2>&1; then
  FAIL=$((FAIL + 1))
  echo "FAIL  --apply without --branch should refuse" >&2
else
  PASS=$((PASS + 1))
fi

# --apply on a vetoed branch must skip it and leave it in place.
"$SCRIPT" --base develop --no-fetch --apply --branch squash-then-more >/dev/null 2>&1
if git rev-parse --verify --quiet squash-then-more >/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL  --apply deleted a branch that had work after the merge" >&2
fi

# --apply on a proven branch removes branch and worktree together.
"$SCRIPT" --base develop --no-fetch --apply --branch wt-clean >/dev/null 2>&1
if git rev-parse --verify --quiet wt-clean >/dev/null || [ -d "$ROOT/wt-clean" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL  --apply left a provably-contained branch or its worktree behind" >&2
else
  PASS=$((PASS + 1))
fi

# A refused worktree removal must SKIP — surfaced, never forced. Branch and
# worktree both survive, and the refusal appears in the output.
LOCK_OUT=$("$SCRIPT" --base develop --no-fetch --apply --branch wt-locked 2>&1)
if [ -d "$ROOT/wt-locked" ] && git rev-parse --verify --quiet wt-locked >/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL  --apply destroyed a locked worktree or its branch instead of refusing" >&2
fi
case "$LOCK_OUT" in
  *"worktree removal refused"*) PASS=$((PASS + 1)) ;;
  *)
    FAIL=$((FAIL + 1))
    echo "FAIL  refused removal was not surfaced in --apply output" >&2
    ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
