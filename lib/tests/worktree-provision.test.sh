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

# new_main <name> <myspec-json> -> an empty main checkout with that config
new_main() {
  local main="$ROOT/$1"
  mkdir -p "$main"
  git init -q -b main "$main"
  git -C "$main" config user.email t@t
  git -C "$main" config user.name t
  printf 'vendor\nnode_modules\n.venv\n' > "$main/.gitignore"
  printf '%s\n' "$2" > "$main/.myspec.json"
  printf '%s\n' "$main"
}
commit_all() { git -C "$1" add -A; git -C "$1" commit -q -m "$2"; }

# --- one malformed entry does not drop the others ----------------------------
M=$(new_main malformed '{"isolation":{"provision":{"symlink":["node_modules",{"path":"vendor","lockfiles":"composer.lock"},42]}}}')
mkdir -p "$M/node_modules/pkg" "$M/vendor/pkg"; printf 'v1\n' > "$M/composer.lock"; commit_all "$M" init
git -C "$M" worktree add -q -b bump "$ROOT/malformed-wt" main
printf 'v2\n' > "$ROOT/malformed-wt/composer.lock"; git -C "$ROOT/malformed-wt" commit -q -am bump
bash "$SCRIPT" "$ROOT/malformed-wt" --base main >/dev/null
[ -L "$ROOT/malformed-wt/node_modules" ] && ok || fail "malformed: node_modules is still linked"
[ ! -e "$ROOT/malformed-wt/vendor" ] && ok || fail "malformed: a string lockfiles still guards vendor"

# --- a * in a lockfile stays in one directory, as in the Stop hook -----------
M=$(new_main globdir '{"isolation":{"provision":{"symlink":[".venv"]}}}')
mkdir -p "$M/.venv/lib" "$M/requirements"; printf 'v1\n' > "$M/requirements/dev.txt"
printf 'v1\n' > "$M/poetry.lock"; commit_all "$M" init
git -C "$M" worktree add -q -b bump "$ROOT/globdir-wt" main
printf 'v2\n' > "$ROOT/globdir-wt/requirements/dev.txt"; git -C "$ROOT/globdir-wt" commit -q -am bump
bash "$SCRIPT" "$ROOT/globdir-wt" --base main >/dev/null
[ -L "$ROOT/globdir-wt/.venv" ] && ok || fail "globdir: requirements*.txt does not match requirements/dev.txt"

# --- vendor/bundle is pinned by Gemfile.lock ---------------------------------
M=$(new_main bundle '{"isolation":{"provision":{"symlink":["vendor/bundle"]}}}')
mkdir -p "$M/vendor/bundle/gem"; printf 'v1\n' > "$M/Gemfile.lock"; commit_all "$M" init
git -C "$M" worktree add -q -b bump "$ROOT/bundle-wt" main
printf 'v2\n' > "$ROOT/bundle-wt/Gemfile.lock"; git -C "$ROOT/bundle-wt" commit -q -am bump
bash "$SCRIPT" "$ROOT/bundle-wt" --base main >/dev/null
[ ! -e "$ROOT/bundle-wt/vendor/bundle" ] && ok || fail "bundle: vendor/bundle is not linked when Gemfile.lock changed"

# --- a tree that loads the main checkout's own source is never linked --------
M=$(new_main selfsrc '{"isolation":{"provision":{"symlink":["vendor",".venv"]}}}')
mkdir -p "$M/vendor/composer" "$M/.venv/lib/python3.12/site-packages/app-0.1.dist-info"
printf "<?php\nreturn array('App\\\\\\\\' => array(\$baseDir . '/src'));\n" > "$M/vendor/composer/autoload_psr4.php"
printf '{"url":"file://%s","dir_info":{"editable":true}}\n' "$M" \
  > "$M/.venv/lib/python3.12/site-packages/app-0.1.dist-info/direct_url.json"
printf 'v1\n' > "$M/composer.lock"; printf 'v1\n' > "$M/uv.lock"; commit_all "$M" init
git -C "$M" worktree add -q -b same "$ROOT/selfsrc-wt" main
out=$(bash "$SCRIPT" "$ROOT/selfsrc-wt" --base main)
[ ! -e "$ROOT/selfsrc-wt/vendor" ] && ok || fail "selfsrc: a Composer vendor with \$baseDir rules is not linked"
[ ! -e "$ROOT/selfsrc-wt/.venv" ] && ok || fail "selfsrc: a .venv with an editable install of main is not linked"
printf '%s' "$out" | grep -qF "own source — not linking vendor" && ok || fail "selfsrc: output says why vendor was skipped"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
