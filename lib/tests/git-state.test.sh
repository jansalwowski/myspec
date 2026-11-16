#!/usr/bin/env bash
# Tests for git-state.sh: the git signals of skills/_shared/git-helpers.md in
# one call (#488).
#
# The properties under test: the default branch follows the cascade
# (origin/HEAD, main, master, else unknown); head names the current branch;
# a clean tree prints `tree: clean` and a dirty one lists its porcelain lines;
# with a feature name, the feat-<name> worktree and the feat/<name> branch are
# found, and a name that only shares a prefix is not; outside git, exit 1.
#
# Usage: git-state.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../git-state.sh}"
[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: [$3]"$'\n'"actual:   [$2]"; fi; }
gitq() { git -c user.email=t@t -c user.name=t "$@"; }

REPO="$ROOT/repo"
mkdir -p "$REPO"
gitq -C "$REPO" init -q -b main
gitq -C "$REPO" commit -q --allow-empty -m init
REPO=$(cd "$REPO" && pwd -P)

echo "# a clean checkout on main, no remote"
expect_eq "default, head and a clean tree" "$(cd "$REPO" && "$SCRIPT")" "default: main
head: main
tree: clean"

echo "# a dirty tree lists its files"
printf 'x\n' > "$REPO/new.md"
expect_eq "dirty, with the porcelain line" "$(cd "$REPO" && "$SCRIPT" | sed -n '3,$p')" "tree: dirty
  ?? new.md"
rm "$REPO/new.md"

echo "# the feature's worktree and branch"
expect_eq "none yet" "$(cd "$REPO" && "$SCRIPT" invoices | sed -n '4,$p')" "worktree: none
branch: absent"
gitq -C "$REPO" worktree add -q "$ROOT/feat-invoices" -b feat/invoices
gitq -C "$REPO" worktree add -q "$ROOT/feat-invoices-v2" -b feat/invoices-v2
WT=$(cd "$ROOT/feat-invoices" && pwd -P)
expect_eq "found, from the main checkout" "$(cd "$REPO" && "$SCRIPT" invoices | sed -n '4,$p')" "worktree: $WT
branch: exists"
expect_eq "head inside the worktree" "$(cd "$WT" && "$SCRIPT" | sed -n 2p)" "head: feat/invoices"
expect_eq "a prefix-sharing name is not matched" "$(cd "$REPO" && "$SCRIPT" invoice | sed -n '4,$p')" "worktree: none
branch: absent"

echo "# the default-branch cascade"
M="$ROOT/master"
mkdir -p "$M" && gitq -C "$M" init -q -b master && gitq -C "$M" commit -q --allow-empty -m init
expect_eq "master when there is no main" "$(cd "$M" && "$SCRIPT" | sed -n 1p)" "default: master"
gitq -C "$M" checkout -q -b trunk && gitq -C "$M" branch -q -D master
expect_eq "unknown when nothing resolves" "$(cd "$M" && "$SCRIPT" | sed -n 1p)" "default: unknown"
gitq clone -q "$REPO" "$ROOT/clone" 2>/dev/null
gitq -C "$ROOT/clone" checkout -q -b develop
gitq -C "$ROOT/clone" branch -q -D main
expect_eq "origin/HEAD wins" "$(cd "$ROOT/clone" && "$SCRIPT" | sed -n 1p)" "default: main"

echo "# an unborn branch and a detached HEAD"
U="$ROOT/unborn"
mkdir -p "$U" && gitq -C "$U" init -q -b main
expect_eq "unborn: the branch name, one line" "$(cd "$U" && "$SCRIPT")" "default: unknown
head: main
tree: clean"
gitq -C "$REPO" checkout -q --detach
expect_eq "detached: HEAD" "$(cd "$REPO" && "$SCRIPT" | sed -n 2p)" "head: HEAD"
gitq -C "$REPO" checkout -q main

echo "# bad input"
mkdir -p "$ROOT/nogit"
if (cd "$ROOT/nogit" && "$SCRIPT" >/dev/null 2>&1); then nok "outside git: exit 1"; else ok "outside git: exit 1"; fi
if (cd "$REPO" && "$SCRIPT" ../x >/dev/null 2>&1); then nok "rejects a name with a slash"; else ok "rejects a name with a slash"; fi
if (cd "$REPO" && "$SCRIPT" a b >/dev/null 2>&1); then nok "rejects two names"; else ok "rejects two names"; fi

echo "git-state: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
