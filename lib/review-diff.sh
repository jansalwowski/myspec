#!/usr/bin/env bash
# review-diff.sh
# Writes the review package a feature-implement reviewer reads: the commit
# list, a stat summary and the full diff over <base>..<head>, then any
# uncommitted changes the range cannot show (#154).
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/lib/review-diff.sh <base> <out-file> [<head>]
#
# <base>      PHASE_BASE, FIX_BASE or BASE_SHA, as recorded in the run.
# <out-file>  the package path ($STATE/phase-N-review.diff, ...).
# <head>      defaults to HEAD.
#
# The range is two-dot: the base is a commit this branch recorded, so every
# commit after it on this branch belongs to the review. Never `HEAD~1`, which
# drops all but the last commit of a multi-commit phase.
#
# A base that is not a commit (a typo, or a sha a rebase or squash removed)
# exits 2 with no package written. `git diff <gone-sha>..HEAD` exits 128 with
# empty stdout, and a caller that wrote that into the package would hand the
# reviewer an empty diff that reads as "nothing changed".
#
# Untracked and modified files are listed after the diff, never added to the
# index: a reviewer that sees only committed work misses a file an implementer
# created and forgot to commit, and `git add -N` would change the index the
# controller owns. The controller's own uncommitted plan edits show there too.
#
# Exit 0 package written (an empty range is still a package: it says so).
# Exit 2 base or head is not a commit; nothing written, and a package left
#        at <out-file> by an earlier run is removed.
# Exit 64 usage.

set -euo pipefail

usage() {
  echo "usage: review-diff.sh <base> <out-file> [<head>]" >&2
  exit 64
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage
BASE="$1"
OUT="$2"
HEAD_REF="${3:-HEAD}"
[ -n "$BASE" ] || { rm -f "$OUT"; echo "review-diff: empty base — record PHASE_BASE / FIX_BASE / BASE_SHA first" >&2; exit 2; }

resolve() {
  git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null || true
}

# A package left by an earlier run at this path must not outlive a failure.
rm -f "$OUT"
BASE_SHA=$(resolve "$BASE")
[ -n "$BASE_SHA" ] || { echo "review-diff: base $BASE is not a commit in this repository (rebased or squashed away?) — no package written" >&2; exit 2; }
HEAD_SHA=$(resolve "$HEAD_REF")
[ -n "$HEAD_SHA" ] || { echo "review-diff: head $HEAD_REF is not a commit — no package written" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")"
TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

{
  echo "# Review package: $BASE_SHA..$HEAD_SHA"
  echo
  if [ -z "$(git rev-list "$BASE_SHA..$HEAD_SHA")" ]; then
    echo "(no commits in range — HEAD has not moved past the base)"
  else
    git log --oneline "$BASE_SHA..$HEAD_SHA"
    echo
    git diff --stat "$BASE_SHA..$HEAD_SHA"
    echo
    git diff -U10 "$BASE_SHA..$HEAD_SHA"
  fi
  if [ "$HEAD_REF" = "HEAD" ]; then
    DIRTY=$(git status --porcelain --untracked-files=all)
    if [ -n "$DIRTY" ]; then
      echo
      echo "# Uncommitted — not in the diff above"
      echo
      echo "$DIRTY"
    fi
  fi
} > "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
