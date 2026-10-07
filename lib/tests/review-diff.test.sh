#!/usr/bin/env bash
# Regression tests for review-diff.sh (#154): the review package a
# feature-implement reviewer reads.
#
# Usage: review-diff.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../review-diff.sh}"
[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"; mkdir -p "$REPO"; cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t; git config user.name t
commit() { echo "$2" > "$1"; git add -A; git commit -qm "$3"; }
commit base.txt base "init"
PHASE_BASE=$(git rev-parse HEAD)
commit a.txt alpha "task 1"
commit b.txt bravo "task 2"
PKG="$ROOT/state/phase-1-review.diff"

# 1. Every commit since the base is in the package, not only the last (the
#    HEAD~1 regression).
"$SCRIPT" "$PHASE_BASE" "$PKG"; rc=$?
[ "$rc" -eq 0 ] && ok "valid range exits 0" || fail "valid range exits 0 (got $rc)"
grep -q "task 1" "$PKG" && grep -q "task 2" "$PKG" && ok "both commits listed" || fail "both commits listed"
grep -q '^+alpha' "$PKG" && grep -q '^+bravo' "$PKG" && ok "both commits' changes in the diff" || fail "both commits' changes in the diff"
grep -q '2 files changed' "$PKG" && ok "stat summary present" || fail "stat summary present"

# 2. An unknown base fails loudly and leaves no package — never an empty diff
#    that reads as "nothing changed".
"$SCRIPT" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$PKG" 2>"$ROOT/err"; rc=$?
[ "$rc" -eq 2 ] && ok "unknown base exits 2" || fail "unknown base exits 2 (got $rc)"
[ ! -e "$PKG" ] && ok "unknown base removes the earlier package" || fail "unknown base removes the earlier package"
grep -q "not a commit" "$ROOT/err" && ok "unknown base names the cause" || fail "unknown base names the cause"
"$SCRIPT" "" "$PKG" 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "empty base exits 2" || fail "empty base exits 2 (got $rc)"

# 3. A sha a rebase removed: reachable before, gone after gc.
git checkout -q -b doomed
commit d.txt delta "doomed"
GONE=$(git rev-parse HEAD)
git checkout -q main; git branch -q -D doomed
git reflog expire --expire=now --all; git gc -q --prune=now
"$SCRIPT" "$GONE" "$PKG" 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] && ok "rebased-away base exits 2" || fail "rebased-away base exits 2 (got $rc)"

# 4. Uncommitted work is listed, and the index is not touched (no git add -N).
echo new > forgot.txt
echo changed >> a.txt
"$SCRIPT" "$PHASE_BASE" "$PKG"
grep -q '^# Uncommitted' "$PKG" && ok "uncommitted section present" || fail "uncommitted section present"
grep -q '?? forgot.txt' "$PKG" && ok "untracked file listed" || fail "untracked file listed"
grep -q ' M a.txt' "$PKG" && ok "modified file listed" || fail "modified file listed"
[ -z "$(git diff --cached --name-only)" ] && ! git ls-files --error-unmatch forgot.txt >/dev/null 2>&1 \
  && ok "index untouched" || fail "index untouched"
rm forgot.txt; git checkout -q -- a.txt

# 5. A clean tree gets no uncommitted section; an empty range says so.
"$SCRIPT" "$PHASE_BASE" "$PKG"
! grep -q '^# Uncommitted' "$PKG" && ok "clean tree: no uncommitted section" || fail "clean tree: no uncommitted section"
"$SCRIPT" HEAD "$PKG"
grep -q 'no commits in range' "$PKG" && ok "empty range is stated" || fail "empty range is stated"

# 6. Explicit head.
"$SCRIPT" "$PHASE_BASE" "$PKG" HEAD~1
grep -q "task 1" "$PKG" && ! grep -q "task 2" "$PKG" && ok "explicit head bounds the range" || fail "explicit head bounds the range"

# 7. Usage.
"$SCRIPT" only-one 2>/dev/null; rc=$?
[ "$rc" -eq 64 ] && ok "usage exits 64" || fail "usage exits 64 (got $rc)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
