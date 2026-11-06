#!/usr/bin/env bash
# Fixture for lib/main-checkout.sh.
#
# Issue #392: session-complete archived a session under the cwd's checkout,
# so from a linked worktree the archive landed in the worktree and
# `git worktree remove` deleted it when the archive was ignored or
# uncommitted. The archive now goes under the main checkout this helper
# prints, from the main checkout, a linked worktree, a submodule and a
# --separate-git-dir checkout alike; a repository with no main checkout
# (a bare clone with worktrees) exits 3 and a directory outside git exits 1.
#
# Usage: main-checkout.test.sh [path-to-main-checkout.sh]

set -uo pipefail

LIB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../main-checkout.sh}"
if [ ! -x "$LIB" ]; then
  echo "FATAL: script not executable: $LIB" >&2
  exit 1
fi
# shellcheck source=lib/tests/old-bash.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/old-bash.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

git_() { git -c user.email=t@t -c user.name=t -c protocol.file.allow=always "$@"; }
new_repo() { git_ init -q -b main "$1" && git_ -C "$1" commit -q --allow-empty -m init; }

REPO="$ROOT/repo"
new_repo "$REPO"
mkdir -p "$REPO/sub/dir"
git_ -C "$REPO" worktree add -q -b wt "$ROOT/linked" >/dev/null 2>&1
mkdir -p "$ROOT/linked/deep"

new_repo "$ROOT/child-src"
git_ -C "$REPO" submodule add -q "$ROOT/child-src" child >/dev/null 2>&1
git_ -C "$REPO" commit -q -m sub

BARE="$ROOT/bare.git"
new_repo "$ROOT/bare-src"
git_ clone -q --bare "$ROOT/bare-src" "$BARE"
git_ -C "$BARE" worktree add -q -b ba "$ROOT/bare-a" >/dev/null 2>&1

git_ init -q -b main --separate-git-dir "$ROOT/sep.git" "$ROOT/sep"
git_ -C "$ROOT/sep" commit -q --allow-empty -m init
git_ -C "$ROOT/sep" worktree add -q -b sw "$ROOT/sep-linked" >/dev/null 2>&1

mkdir -p "$ROOT/nogit"

check() {  # check <bash dir> <want rc> <want stdout> <desc> <args...>
  local dir="$1" want_rc="$2" want_out="$3" desc="$4" out rc
  shift 4
  out=$(PATH="${dir:+$dir:}$PATH" "$LIB" "$@" 2>/dev/null)
  rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s%s: want rc=%s out=%s, got rc=%s out=%s\n' "$desc" "${dir:+ (old bash)}" \
      "$want_rc" "$want_out" "$rc" "$out" >&2
  fi
}

old_bash_dirs "$ROOT"
for d in "${TEST_BASH_DIRS[@]}"; do
  check "$d" 0 "$REPO" "main checkout prints itself" "$REPO"
  check "$d" 0 "$REPO" "a subdirectory of the main checkout" "$REPO/sub/dir"
  check "$d" 0 "$REPO" "a linked worktree prints the main checkout, not itself" "$ROOT/linked"
  check "$d" 0 "$REPO" "a subdirectory of a linked worktree" "$ROOT/linked/deep"
  check "$d" 0 "$REPO" "a submodule climbs to its superproject" "$REPO/child"
  check "$d" 0 "$ROOT/sep" "a --separate-git-dir checkout is its own main checkout" "$ROOT/sep"
  check "$d" 3 "" "a --separate-git-dir worktree names no main checkout" "$ROOT/sep-linked"
  check "$d" 3 "" "a bare clone's worktree has no main checkout" "$ROOT/bare-a"
  check "$d" 1 "" "outside git" "$ROOT/nogit"
  # No argument: the cwd.
  out=$(cd "$ROOT/linked/deep" && PATH="${d:+$d:}$PATH" "$LIB" 2>/dev/null)
  if [ "$out" = "$REPO" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); printf 'FAIL  no argument reads the cwd: got %s\n' "$out" >&2; fi
done

echo "main-checkout: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
