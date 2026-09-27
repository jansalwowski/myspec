#!/usr/bin/env bash
# Regression fixture for the per-entry lockfile guard in worktree-provision.sh.
#
# Each isolation.provision.symlink entry is skipped when the branch changes a
# lockfile that pins it, for any ecosystem: a vendor/ link survived a
# composer.lock change before, because the guard only knew node_modules. The
# entry-to-lockfile map is duplicated in hooks/verify-before-stop.sh (the two
# ship separately), so this also fails when the two copies drift.
#
# Usage: worktree-provision.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../worktree-provision.sh}"
HOOK="$HERE/../../hooks/verify-before-stop.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# map_block <file> -> the shared dependency-lockfile map section
map_block() {
  sed -n '/^# BEGIN dependency-lockfile map$/,/^# END dependency-lockfile map$/p' "$1"
}
A=$(map_block "$SCRIPT")
B=$(map_block "$HOOK")
[ -n "$A" ] && [ "$A" = "$B" ] && ok || fail "dependency-lockfile map is identical in worktree-provision.sh and verify-before-stop.sh"

# run_case <name> <dir> <lockfile> <symlink-json> -> checks link, then skip
run_case() {
  local main="$ROOT/$1" out
  mkdir -p "$main/$2/pkg"
  git init -q -b main "$main"
  git -C "$main" config user.email t@t
  git -C "$main" config user.name t
  printf '%s\n' "$2" > "$main/.gitignore"
  printf 'v1\n' > "$main/$3"
  printf '{"isolation":{"provision":{"symlink":%s}}}\n' "$4" > "$main/.myspec.json"
  git -C "$main" add -A
  git -C "$main" commit -q -m init

  git -C "$main" worktree add -q -b same "$ROOT/$1-same" main
  bash "$SCRIPT" "$ROOT/$1-same" --base main >/dev/null
  [ -L "$ROOT/$1-same/$2" ] && ok || fail "$1: $2 is linked when $3 is unchanged"
  grep -qxF -- "$2" "$(git -C "$ROOT/$1-same" rev-parse --git-path info/exclude)" && ok \
    || fail "$1: linked $2 is listed in info/exclude"

  git -C "$main" worktree add -q -b bump "$ROOT/$1-bump" main
  printf 'v2\n' > "$ROOT/$1-bump/$3"
  git -C "$ROOT/$1-bump" commit -q -am bump
  out=$(bash "$SCRIPT" "$ROOT/$1-bump" --base main)
  [ ! -e "$ROOT/$1-bump/$2" ] && ok || fail "$1: $2 is not linked when $3 changed"
  printf '%s' "$out" | grep -qF "not linking $2" && ok || fail "$1: output names the skipped $2"

  # Without --base there is nothing to compare against: link as before.
  git -C "$main" worktree add -q -b nobase "$ROOT/$1-nobase" bump
  bash "$SCRIPT" "$ROOT/$1-nobase" >/dev/null
  [ -L "$ROOT/$1-nobase/$2" ] && ok || fail "$1: $2 is linked when no --base is given"
}

run_case php vendor composer.lock '["vendor"]'
run_case ruby vendor Gemfile.lock '["vendor/"]'
run_case py .venv uv.lock '[".venv"]'
run_case node node_modules pnpm-lock.yaml '["node_modules"]'
run_case obj deps deps.lock '[{"path":"deps","lockfiles":["deps.lock"]}]'
run_case objinfer vendor composer.lock '[{"path":"vendor"}]'

# --- a change to an unrelated lockfile does not skip the entry --------------
MAIN="$ROOT/mixed"
mkdir -p "$MAIN/vendor/pkg" "$MAIN/node_modules/pkg"
git init -q -b main "$MAIN"
git -C "$MAIN" config user.email t@t
git -C "$MAIN" config user.name t
printf 'vendor\nnode_modules\n' > "$MAIN/.gitignore"
printf 'v1\n' > "$MAIN/composer.lock"
printf 'v1\n' > "$MAIN/package-lock.json"
printf '{"isolation":{"provision":{"symlink":["vendor","node_modules"]}}}\n' > "$MAIN/.myspec.json"
git -C "$MAIN" add -A
git -C "$MAIN" commit -q -m init
git -C "$MAIN" worktree add -q -b bump "$ROOT/mixed-wt" main
printf 'v2\n' > "$ROOT/mixed-wt/package-lock.json"
git -C "$ROOT/mixed-wt" commit -q -am bump
bash "$SCRIPT" "$ROOT/mixed-wt" --base main >/dev/null
[ -L "$ROOT/mixed-wt/vendor" ] && ok || fail "mixed: vendor is linked when only package-lock.json changed"
[ ! -e "$ROOT/mixed-wt/node_modules" ] && ok || fail "mixed: node_modules is skipped when package-lock.json changed"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
