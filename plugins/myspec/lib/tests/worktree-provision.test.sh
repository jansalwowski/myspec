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

# --- a tree whose workspace links leave it is never linked (#229) -------------
# A workspace package manager links each workspace package relatively
# (apps/web/node_modules/@acme/ui -> ../../../../packages/ui), so through a
# link the worktree would load the main checkout's packages. Links that stay
# inside the tree (a content store, a bin dir) are not workspace links.
M=$(new_main workspace '{"isolation":{"provision":{"symlink":["apps/web/node_modules","node_modules"]}}}')
mkdir -p "$M/packages/ui" "$M/apps/web/node_modules/@acme" "$M/node_modules/.store/dep/bin" "$M/node_modules/.bin"
ln -s ../../../../packages/ui "$M/apps/web/node_modules/@acme/ui"
ln -s .store/dep "$M/node_modules/dep"
ln -s ../.store/dep/bin "$M/node_modules/.bin/dep"
printf 'apps/web/node_modules\n' >> "$M/.gitignore"
printf 'v1\n' > "$M/lock.yaml"; commit_all "$M" init
git -C "$M" worktree add -q -b same "$ROOT/workspace-wt" main
out=$(bash "$SCRIPT" "$ROOT/workspace-wt" --base main)
[ ! -e "$ROOT/workspace-wt/apps/web/node_modules" ] && ok || fail "workspace: a tree with a workspace link into main is not linked"
printf '%s' "$out" | grep -qF "own source — not linking apps/web/node_modules" && ok || fail "workspace: output says why apps/web/node_modules was skipped"
[ -L "$ROOT/workspace-wt/node_modules" ] && ok || fail "workspace: a tree whose links stay inside it is still linked"

# The same for a Composer path repository (vendor/<vendor>/<name>).
M=$(new_main pathrepo '{"isolation":{"provision":{"symlink":["vendor"]}}}')
mkdir -p "$M/packages/lib" "$M/vendor/acme"
ln -s ../../packages/lib "$M/vendor/acme/lib"
printf 'v1\n' > "$M/composer.lock"; commit_all "$M" init
git -C "$M" worktree add -q -b same "$ROOT/pathrepo-wt" main
bash "$SCRIPT" "$ROOT/pathrepo-wt" --base main >/dev/null
[ ! -e "$ROOT/pathrepo-wt/vendor" ] && ok || fail "pathrepo: a vendor with a path-repository link into main is not linked"

# --- every link is resolved physically, whatever its text (PR #236 review) ---
# tree_loads_checkout is called directly, from the shared block, on a tree
# inside a checkout. Each link below leaves the tree for the checkout, but
# its text matches no ../-prefixed pattern, or it sits in pnpm's hidden
# hoist four levels down.
REAL_FIND=$(command -v find)
# tlc <tree> <checkout> [PATH prefix] -> tree_loads_checkout's exit status
tlc() {
  ( PATH="${3:+$3:}$PATH"; eval "$A"; tree_loads_checkout "$1" "$2" ) >/dev/null 2>&1
}
# link_case <desc> <link path, tree-relative> <link text>
link_case() {
  local c="$ROOT/lc-$((LC = ${LC:-0} + 1))"
  mkdir -p "$c/packages/ui" "$c/node_modules/@acme" "$c/node_modules/.store/x"
  mkdir -p "$(dirname "$c/node_modules/$2")"
  ln -s "$3" "$c/node_modules/$2"
  tlc "$c/node_modules" "$c" && ok || fail "links: $1 is caught"
}
link_case "depth 1 self -> .." self ..
link_case "depth 2 @acme/root -> ../.." @acme/root ../..
link_case "depth 1 ui -> ./../packages/ui" ui ./../packages/ui
link_case "depth 2 @acme/ui -> ../@acme/../../packages/ui" @acme/ui ../@acme/../../packages/ui
link_case "pnpm hidden hoist .pnpm/node_modules/@acme/ui" .pnpm/node_modules/@acme/ui ../../../../packages/ui
# An internal-looking hop that chains into a deeper link that escapes.
C="$ROOT/lc-chain"
mkdir -p "$C/packages/ui" "$C/node_modules/.store/x"
ln -s ../../../packages/ui "$C/node_modules/.store/x/ui"
ln -s .store/x/ui "$C/node_modules/ui"
tlc "$C/node_modules" "$C" && ok || fail "links: ui -> .store/x/ui chaining to ../../../packages/ui is caught"
# Links that stay inside the tree are still accepted.
C="$ROOT/lc-inside"
mkdir -p "$C/packages/ui" "$C/node_modules/.store/x/ui" "$C/node_modules/.pnpm/node_modules"
ln -s .store/x/ui "$C/node_modules/ui"
ln -s ../.store/x/ui "$C/node_modules/.pnpm/node_modules/ui"
ln -s ../.store/x/ui/bin.js "$C/node_modules/.store/bin"
tlc "$C/node_modules" "$C" && fail "links: a tree whose links stay inside it is accepted" || ok

# A find without -lname (BusyBox) still scans: the PR's own repro is caught.
SHIM="$ROOT/find-shim"
mkdir -p "$SHIM"
# shellcheck disable=SC2016 # the shim's own "$@", expanded when it runs
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -lname ] && { echo "find: unrecognized: -lname" >&2; exit 1; }; done\nexec %s "$@"\n' "$REAL_FIND" > "$SHIM/find"
chmod +x "$SHIM/find"
C="$ROOT/lc-busybox"
mkdir -p "$C/packages/ui" "$C/apps/web/node_modules/@acme"
ln -s ../../../../packages/ui "$C/apps/web/node_modules/@acme/ui"
tlc "$C/apps/web/node_modules" "$C" "$SHIM" && ok || fail "links: a find without -lname still catches @acme/ui -> ../../../../packages/ui"
# A find that fails outright fails closed: the unscanned tree counts as loading.
FAILSHIM="$ROOT/find-fail"
mkdir -p "$FAILSHIM"
printf '#!/bin/sh\necho "find: bad option" >&2\nexit 1\n' > "$FAILSHIM/find"
chmod +x "$FAILSHIM/find"
tlc "$ROOT/lc-inside/node_modules" "$ROOT/lc-inside" "$FAILSHIM" && ok || fail "links: a failing find makes the tree count as loading the checkout"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
