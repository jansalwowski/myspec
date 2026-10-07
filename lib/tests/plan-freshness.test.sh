#!/usr/bin/env bash
# Regression tests for plan-freshness.sh (#154). Each case reproduces a fix
# that once lived only in feature-plan / feature-implement prose:
#   a6cb428  planned_against is HEAD after the sync, so the diff is three-dot
#   e5b17e0  the ref is origin/<branch> after a fetch, never a lagging local
#   04f90a3  a missing sha or failed fetch is "unknown", never "fresh"
#
# Usage: plan-freshness.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../plan-freshness.sh}"
[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
commit() { mkdir -p "$(dirname "$1")"; echo "$2" > "$1"; git add -A; git commit -qm "$3"; }

# origin (bare) <- upstream clone pushes integration-branch work;
# repo is the feature checkout.
git init -q --bare -b main "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/upstream" 2>/dev/null
cd "$ROOT/upstream" || exit 1
git checkout -q -b main 2>/dev/null || true
commit src/app.txt v1 "init"
commit src/lib.txt v1 "lib"
git push -q origin main
git clone -q "$ROOT/origin.git" "$ROOT/repo"
cd "$ROOT/repo" || exit 1
git checkout -q -b feat/x

# The feature branch's own commit, then the sync point feature-plan records.
commit src/feature.txt f1 "feature work before planning"
PLANNED=$(git rev-parse HEAD)
commit src/app.txt feature-edit "feature edits app after planning"

# 1. Nothing changed on the integration branch: fresh, although the feature
#    branch itself changed src/feature.txt before planning and src/app.txt
#    after (a two-dot diff lists src/feature.txt).
out=$("$SCRIPT" check "$PLANNED" main src/feature.txt src/app.txt src/lib.txt); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "fresh" ] && ok "feature-branch edits are not drift" || fail "feature-branch edits are not drift (rc=$rc out=$out)"

# 2. The integration branch moves on origin only; local main lags. The
#    check must fetch and see it (a local-ref diff exits 0, empty).
cd "$ROOT/upstream" || exit 1
commit src/lib.txt v2 "upstream changes lib"
commit src/other.txt o "upstream changes an unlisted file"
git push -q origin main
cd "$ROOT/repo" || exit 1
out=$("$SCRIPT" check "$PLANNED" main src/feature.txt src/app.txt src/lib.txt); rc=$?
[ "$rc" -eq 1 ] && ok "stale exits 1" || fail "stale exits 1 (got $rc)"
[ "$(printf '%s\n' "$out" | head -1)" = "stale" ] && ok "stale verdict line" || fail "stale verdict line ($out)"
printf '%s\n' "$out" | grep -qx 'src/lib.txt' && ok "changed path listed" || fail "changed path listed"
! printf '%s\n' "$out" | grep -q 'src/other.txt' && ok "unlisted path filtered out" || fail "unlisted path filtered out"
! printf '%s\n' "$out" | grep -qE 'src/(app|feature).txt' && ok "feature-branch paths not listed" || fail "feature-branch paths not listed"
git rev-parse -q --verify main >/dev/null && [ "$(git rev-parse main)" != "$(git rev-parse origin/main)" ] \
  && ok "local main still lags (precondition)" || fail "local main still lags (precondition)"

# 3. Paths absent: every integration-branch change counts.
out=$("$SCRIPT" check "$PLANNED" main); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qx 'src/other.txt' && ok "no paths: all changes listed" || fail "no paths: all changes listed"

# 4. A planned_against sha that a rebase or squash removed is unknown.
out=$("$SCRIPT" check deadbeefdeadbeefdeadbeefdeadbeefdeadbeef main src/lib.txt); rc=$?
[ "$rc" -eq 2 ] && ok "missing sha exits 2" || fail "missing sha exits 2 (got $rc)"
case "$out" in "unknown: planned_against"*) ok "missing sha verdict is unknown" ;; *) fail "missing sha verdict is unknown ($out)" ;; esac

# 5. A failed fetch is unknown, never fresh.
git remote set-url origin "$ROOT/no-such-remote.git"
out=$("$SCRIPT" check "$PLANNED" main src/lib.txt); rc=$?
[ "$rc" -eq 2 ] && ok "failed fetch exits 2" || fail "failed fetch exits 2 (got $rc)"
case "$out" in "unknown: fetch"*) ok "failed fetch verdict is unknown" ;; *) fail "failed fetch verdict is unknown ($out)" ;; esac
out=$("$SCRIPT" base main 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] && ok "base: failed fetch exits 2, no ref" || fail "base: failed fetch exits 2, no ref (rc=$rc out=$out)"
git remote set-url origin "$ROOT/origin.git"

# 6. base prints the remote-tracking ref.
out=$("$SCRIPT" base main); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "origin/main" ] && ok "base prints origin/<branch>" || fail "base prints origin/<branch> (rc=$rc out=$out)"

# 7. No remote: the local branch is the ref.
git remote remove origin
git branch -q -f main "$PLANNED"
out=$("$SCRIPT" base main); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "main" ] && ok "no remote: base is the local branch" || fail "no remote: base is the local branch (rc=$rc out=$out)"
out=$("$SCRIPT" check "$PLANNED" main src/lib.txt); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "fresh" ] && ok "no remote: check runs on the local branch" || fail "no remote: check runs on the local branch (rc=$rc out=$out)"
out=$("$SCRIPT" check "$PLANNED" nosuchbranch src/lib.txt); rc=$?
[ "$rc" -eq 2 ] && ok "unknown integration branch exits 2" || fail "unknown integration branch exits 2 (got $rc)"

# 8. Usage.
"$SCRIPT" check onlysha 2>/dev/null; rc=$?
[ "$rc" -eq 64 ] && ok "usage exits 64" || fail "usage exits 64 (got $rc)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
