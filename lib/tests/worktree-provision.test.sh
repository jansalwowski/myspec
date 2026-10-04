#!/usr/bin/env bash
# Regression fixture for the per-entry lockfile guard in worktree-provision.sh.
#
# Each isolation.provision.symlink entry is skipped when the branch changes a
# lockfile that pins it, for any ecosystem: a vendor/ link survived a
# composer.lock change before, because the guard only knew node_modules. The
# entry-to-lockfile map is lib/dependency-map.sh, which
# hooks/verify-before-stop.sh sources too; this fails if either script grows
# a copy of its own again.
#
# Usage: worktree-provision.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../worktree-provision.sh}"
HOOK="$HERE/../../hooks/verify-before-stop.sh"
MAP="$(dirname "$SCRIPT")/dependency-map.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# The dependency-directory map lives in lib/dependency-map.sh, which both
# scripts source; neither keeps a copy of its own.
for f in "$SCRIPT" "$HOOK"; do
  grep -qE '^(dep_lockfiles|infer_entry|symlink_entries|tree_loads_checkout)\(\)' "$f" && fail "$(basename "$f") keeps its own dependency map" || ok
  grep -qF 'dependency-map.sh' "$f" && ok || fail "$(basename "$f") sources lib/dependency-map.sh"
done

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
# tree_loads_checkout is called directly, from lib/dependency-map.sh, on a tree
# inside a checkout. Each link below leaves the tree for the checkout, but
# its text matches no ../-prefixed pattern, or it sits in pnpm's hidden
# hoist four levels down.
REAL_FIND=$(command -v find)
# tlc <tree> <checkout> [PATH prefix] -> tree_loads_checkout's exit status
tlc() {
  # shellcheck source=lib/dependency-map.sh
  ( PATH="${3:+$3:}$PATH"; . "$MAP"; tree_loads_checkout "$1" "$2" ) >/dev/null 2>&1
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
# An unreadable directory makes find exit non-zero after it listed every link
# it could read: the tree is judged on that list, not counted as loading.
if [ "$(id -u)" -ne 0 ]; then
  C="$ROOT/lc-unreadable"
  mkdir -p "$C/packages/ui" "$C/node_modules/pkg" "$C/node_modules/.cache/locked"
  chmod 000 "$C/node_modules/.cache"
  tlc "$C/node_modules" "$C" && fail "links: an unreadable directory alone does not count as loading" || ok
  ln -s ../packages/ui "$C/node_modules/ui"
  tlc "$C/node_modules" "$C" && ok || fail "links: a workspace link beside an unreadable directory is still caught"
  chmod 755 "$C/node_modules/.cache"
  # The tree root itself unlistable (0311: enterable, not readable): the scan
  # sees nothing, so the tree counts as loading (#251 review). Same for an
  # unlistable NESTED_LINK_DIRS entry.
  C="$ROOT/lc-unlistable"
  mkdir -p "$C/node_modules/pkg"
  ln -s /etc "$C/node_modules/etc"
  chmod 0311 "$C/node_modules"
  tlc "$C/node_modules" "$C" && ok || fail "links: an unlistable tree root counts as loading"
  chmod 755 "$C/node_modules"
  C="$ROOT/lc-unlistable-nest"
  mkdir -p "$C/node_modules/.pnpm/node_modules/@acme" "$C/packages/ui"
  ln -s ../../../../packages/ui "$C/node_modules/.pnpm/node_modules/@acme/ui"
  chmod 0311 "$C/node_modules/.pnpm/node_modules"
  tlc "$C/node_modules" "$C" && ok || fail "links: an unlistable nested link directory counts as loading"
  chmod 755 "$C/node_modules/.pnpm/node_modules"
  # End to end: provision refuses the unlistable tree and says why.
  M=$(new_main unlistable '{"isolation":{"provision":{"symlink":["node_modules"]}}}')
  mkdir -p "$M/node_modules/dep"; commit_all "$M" init
  git -C "$M" worktree add -q -b unlistable-wt "$ROOT/unlistable-wt" main
  chmod 0311 "$M/node_modules"
  out=$(bash "$SCRIPT" "$ROOT/unlistable-wt" --base main 2>&1)
  chmod 755 "$M/node_modules"
  [ ! -e "$ROOT/unlistable-wt/node_modules" ] && printf '%s' "$out" | grep -qF "cannot list node_modules" && ok \
    || fail "unlistable: provision does not link a tree it cannot list, and says so (got: $out)"
fi

# --- install, copy, clean (#230, #222, #193) ---------------------------------
# Install steps are fake commands that leave marker files, so no network is
# needed. Each fixture commits its .myspec.json, so the worktree carries it.

# wt_for <main> <name> -> a fresh worktree of main
wt_for() {
  git -C "$1" worktree add -q -b "$2" "$ROOT/$2" main
  printf '%s\n' "$ROOT/$2"
}

# A single command runs in the root with both variables exported.
# shellcheck disable=SC2016 # expanded by the shell that runs it, not here
M=$(new_main inst1 '{"isolation":{"provision":{"symlink":[],"install":"printf \"%s\\n%s\\n\" \"$MYSPEC_WORKTREE\" \"$MYSPEC_MAIN_CHECKOUT\" > env.marker; pwd -P > cwd.marker"}}}')
commit_all "$M" init
W=$(wt_for "$M" inst1-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1); st=$?
[ "$st" -eq 0 ] && ok || fail "install: a passing command exits 0 (got $st: $out)"
[ "$(sed -n 1p "$W/env.marker" 2>/dev/null)" = "$W" ] && ok || fail "install: MYSPEC_WORKTREE is the worktree"
[ "$(sed -n 2p "$W/env.marker" 2>/dev/null)" = "$M" ] && ok || fail "install: MYSPEC_MAIN_CHECKOUT is the main checkout"
[ "$(cat "$W/cwd.marker" 2>/dev/null)" = "$W" ] && ok || fail "install: the default cwd is the worktree root"
printf '%s' "$out" | grep -qF "1 installed" && ok || fail "install: the summary counts the step"

# Steps with cwd and when, in a polyglot layout; a step whose when is missing is skipped.
M=$(new_main inst2 '{"isolation":{"provision":{"symlink":[],"install":[
  {"run":"pwd -P > api.marker","cwd":"api","when":["api/composer.lock"]},
  {"run":"touch web.marker","when":["pnpm-lock.yaml"]},
  {"run":"touch go.marker","cwd":"worker","when":"worker/go.sum"}]}}}')
mkdir -p "$M/api" "$M/worker"; printf 'v1\n' > "$M/api/composer.lock"; printf 'v1\n' > "$M/worker/go.sum"
commit_all "$M" init
W=$(wt_for "$M" inst2-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1)
[ "$(cat "$W/api/api.marker" 2>/dev/null)" = "$W/api" ] && ok || fail "install: a step runs in its cwd"
[ -e "$W/worker/go.marker" ] && ok || fail "install: a string when is one path"
[ ! -e "$W/web.marker" ] && ok || fail "install: a step whose when path is missing does not run"
printf '%s' "$out" | grep -qF "pnpm-lock.yaml not found — skipped install step 2" && ok || fail "install: the skipped step is named (got: $out)"

# A failing step stops provisioning, reports, and runs nothing after it.
M=$(new_main inst3 '{"isolation":{"provision":{"symlink":[],"install":[{"run":"touch first.marker"},{"run":"exit 3"},{"run":"touch third.marker"}]}}}')
commit_all "$M" init
W=$(wt_for "$M" inst3-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1); st=$?
[ "$st" -ne 0 ] && ok || fail "install: a failing step exits non-zero"
[ -e "$W/first.marker" ] && [ ! -e "$W/third.marker" ] && ok || fail "install: steps after a failure do not run"
printf '%s' "$out" | grep -qF "install step 2 failed (exit 3)" && ok || fail "install: the failure names the step and exit (got: $out)"

# A malformed step stops provisioning before anything runs.
M=$(new_main inst4 '{"isolation":{"provision":{"symlink":[],"install":[{"run":"touch ok.marker"},{"cwd":"api"}]}}}')
commit_all "$M" init
W=$(wt_for "$M" inst4-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1); st=$?
[ "$st" -ne 0 ] && printf '%s' "$out" | grep -qF "install step 2 is malformed" && ok || fail "install: a malformed step stops provisioning (got $st: $out)"

# A step that reads stdin gets /dev/null, not the remaining step list (PR #242 review).
M=$(new_main inst-stdin '{"isolation":{"provision":{"symlink":[],"install":[{"run":"cat"},{"run":"touch second.marker"}]}}}')
commit_all "$M" init
W=$(wt_for "$M" inst-stdin-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1)
[ -e "$W/second.marker" ] && ok || fail "install: a step reading stdin does not swallow the next step (got: $out)"
printf '%s' "$out" | grep -qF "2 installed" && ok || fail "install: both steps are counted (got: $out)"

# install set: the dependency tree is not linked (install builds it); other links are.
M=$(new_main inst5 '{"isolation":{"provision":{"symlink":["node_modules",".env"],"install":"mkdir node_modules && touch node_modules/built.marker"}}}')
mkdir -p "$M/node_modules/pkg"; printf 'X=1\n' > "$M/.env"; printf '.env\n' >> "$M/.gitignore"; printf 'v1\n' > "$M/package-lock.json"
commit_all "$M" init
W=$(wt_for "$M" inst5-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1)
[ -d "$W/node_modules" ] && [ ! -L "$W/node_modules" ] && [ -e "$W/node_modules/built.marker" ] && ok \
  || fail "install: with install set, node_modules is built in the worktree, not linked"
[ ! -e "$M/node_modules/built.marker" ] && ok || fail "install: nothing is written into the main checkout"
[ -L "$W/.env" ] && ok || fail "install: a non-dependency entry is still linked"
printf '%s' "$out" | grep -qF "install is set — not linking node_modules" && ok || fail "install: the skipped link is named"

# --no-install prints each skipped step, runs none, and links as if install were unset.
W=$(wt_for "$M" inst5-noinst)
out=$(bash "$SCRIPT" "$W" --base main --no-install 2>&1)
[ ! -e "$W/node_modules/built.marker" ] && ok || fail "--no-install: no step runs"
printf '%s' "$out" | grep -qF -- "--no-install — skipped install step 1 in .: mkdir node_modules" && ok || fail "--no-install: the step is printed (got: $out)"
[ -L "$W/node_modules" ] && ok || fail "--no-install: node_modules is linked as before"

# A workspace config alone blocks no link (PR #242 review): a pnpm
# workspace's Composer vendor holds no workspace links, so it is linked like
# any other tree, as on main.
for marker in 'pnpm-workspace.yaml:packages: []' 'package.json:{"workspaces":["packages/*"]}' 'go.work:go 1.22'; do
  file="${marker%%:*}"
  M=$(new_main "ws-${file%%.*}" '{"isolation":{"provision":{"symlink":["node_modules","vendor"]}}}')
  mkdir -p "$M/node_modules/pkg" "$M/vendor/acme/lib"; printf '%s\n' "${marker#*:}" > "$M/$file"
  printf '<?php\n' > "$M/vendor/acme/lib/a.php"
  commit_all "$M" init
  W=$(wt_for "$M" "ws-${file%%.*}-wt")
  out=$(bash "$SCRIPT" "$W" --base main 2>&1)
  [ -L "$W/vendor" ] && ok || fail "workspace $file: a vendor without workspace links is linked (got: $out)"
  [ -L "$W/node_modules" ] && ok || fail "workspace $file: a node_modules without workspace links is linked (got: $out)"
done
# A tree that does hold workspace links is still skipped, with the install advice.
M=$(new_main ws-links '{"isolation":{"provision":{"symlink":["node_modules","vendor"]}}}')
mkdir -p "$M/packages/ui" "$M/node_modules/@acme" "$M/vendor/acme/lib"
printf 'packages: [packages/*]\n' > "$M/pnpm-workspace.yaml"
ln -s ../../packages/ui "$M/node_modules/@acme/ui"
printf '<?php\n' > "$M/vendor/acme/lib/a.php"
commit_all "$M" init
W=$(wt_for "$M" ws-links-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1)
[ ! -e "$W/node_modules" ] && ok || fail "workspace: a node_modules with a workspace link into main is not linked"
printf '%s' "$out" | grep -qF "node_modules loads the main checkout's own source — not linking node_modules; set isolation.provision.install or run a real install" && ok \
  || fail "workspace: the skipped tree gets the install advice (got: $out)"
[ -L "$W/vendor" ] && ok || fail "workspace: the vendor beside it is still linked"

# The worktree's own .myspec.json wins over the main checkout's uncommitted one.
M=$(new_main ownsettings '{"isolation":{"provision":{"symlink":[]}}}')
commit_all "$M" init
printf '{"isolation":{"provision":{"symlink":[],"install":"touch main-setting.marker"}}}\n' > "$M/.myspec.json"
W=$(wt_for "$M" ownsettings-wt)
bash "$SCRIPT" "$W" --base main >/dev/null 2>&1
[ ! -e "$W/main-setting.marker" ] && ok || fail "settings: the worktree's own .myspec.json is read"

# A directory copies; clone mode clones or copies, never links.
M=$(new_main copydir '{"isolation":{"provision":{"symlink":[],"copy":[".cache-dir",{"path":"vendor","mode":"clone"},{"path":"deps","mode":"bogus"}]}}}')
mkdir -p "$M/.cache-dir/sub" "$M/vendor/acme/lib" "$M/deps"
printf 'c\n' > "$M/.cache-dir/sub/f"; printf '<?php\n' > "$M/vendor/acme/lib/a.php"; printf 'd\n' > "$M/deps/x"
printf '.cache-dir\ndeps\n' >> "$M/.gitignore"; commit_all "$M" init
W=$(wt_for "$M" copydir-wt)
out=$(bash "$SCRIPT" "$W" --base main 2>&1)
[ -f "$W/.cache-dir/sub/f" ] && [ ! -L "$W/.cache-dir" ] && ok || fail "copy: a directory entry is copied"
[ -f "$W/vendor/acme/lib/a.php" ] && [ ! -L "$W/vendor" ] && ok || fail "copy: a clone-mode tree is a real directory"
printf '%s' "$out" | grep -qE "(cloned vendor|no copy-on-write clone on this filesystem — copied vendor)" && ok || fail "copy: clone mode says what it did (got: $out)"
[ -f "$W/deps/x" ] && printf '%s' "$out" | grep -qF "unknown copy mode 'bogus' for deps — copying it" && ok || fail "copy: an unknown mode copies and says so"
grep -qxF vendor "$(git -C "$W" rev-parse --git-path info/exclude)" && ok || fail "copy: a copied tree is listed in info/exclude"
printf '<?php // edited\n' > "$W/vendor/acme/lib/a.php"
[ "$(cat "$M/vendor/acme/lib/a.php")" = "<?php" ] && ok || fail "copy: editing the clone leaves the main checkout alone"

# Clone fallback: where neither --reflink=auto nor -c works, a plain copy.
SHIMDIR="$ROOT/cp-shim"
mkdir -p "$SHIMDIR/lib"
# shellcheck disable=SC2016 # expanded by the shell that runs it, not here
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in -c|--reflink*) echo "cp: illegal option" >&2; exit 64 ;; esac; done\nexec /bin/cp "$@"\n' > "$SHIMDIR/cp"
chmod +x "$SHIMDIR/cp"
sed "s#/bin/cp #$SHIMDIR/cp #g" "$SCRIPT" > "$SHIMDIR/lib/worktree-provision.sh"
cp "$(dirname "$SCRIPT")/myspec-config.sh" "$(dirname "$SCRIPT")/myspec-config.schema.json" "$(dirname "$SCRIPT")/glob-regex.sh" \
  "$(dirname "$SCRIPT")/hook-core.sh" "$(dirname "$SCRIPT")/dependency-map.sh" "$SHIMDIR/lib/"
W=$(wt_for "$M" copydir-fallback)
out=$(bash "$SHIMDIR/lib/worktree-provision.sh" "$W" --base main 2>&1)
[ -f "$W/vendor/acme/lib/a.php" ] && printf '%s' "$out" | grep -qF "no copy-on-write clone on this filesystem — copied vendor" && ok \
  || fail "copy: clone mode falls back to a plain copy (got: $out)"

# clean deletes untracked matches, keeps tracked ones, and never touches a link.
M=$(new_main clean '{"isolation":{"provision":{"symlink":["node_modules"],"copy":["build"],"clean":["**/*.tsbuildinfo",".mypy_cache/**","./tmp-cache"]}}}')
mkdir -p "$M/build/app" "$M/node_modules/pkg" "$M/packages/ui"
printf 'x\n' > "$M/build/app/tsconfig.tsbuildinfo"; printf 'x\n' > "$M/build/keep.txt"
printf 'x\n' > "$M/node_modules/pkg/linked.tsbuildinfo"
printf 'x\n' > "$M/packages/ui/tracked.tsbuildinfo"
printf 'build\n' >> "$M/.gitignore"; commit_all "$M" init
W=$(wt_for "$M" clean-wt)
mkdir -p "$W/.mypy_cache/3.12" "$W/tmp-cache"; printf 'x\n' > "$W/.mypy_cache/3.12/m.json"; printf 'x\n' > "$W/root.tsbuildinfo"
out=$(bash "$SCRIPT" "$W" --base main 2>&1)
[ ! -e "$W/build/app/tsconfig.tsbuildinfo" ] && [ -e "$W/build/keep.txt" ] && ok || fail "clean: a copied match is deleted, the rest kept"
[ ! -e "$W/root.tsbuildinfo" ] && ok || fail "clean: ** matches at the root"
[ ! -e "$W/.mypy_cache/3.12/m.json" ] && ok || fail "clean: dir/** deletes what is under it"
[ ! -e "$W/tmp-cache" ] && ok || fail "clean: a directory glob deletes the directory"
[ -e "$W/packages/ui/tracked.tsbuildinfo" ] && printf '%s' "$out" | grep -qF "not cleaning packages/ui/tracked.tsbuildinfo — it is tracked" && ok \
  || fail "clean: a tracked match is kept and named (got: $out)"
[ -L "$W/node_modules" ] && [ -e "$M/node_modules/pkg/linked.tsbuildinfo" ] && ok || fail "clean: never deletes through a link"
[ -z "$(git -C "$W" status --porcelain)" ] && ok || fail "clean: the worktree stays clean"

# Without lib/glob-regex.sh the script refuses to start, before any link,
# rather than die at the first `clean` glob with the worktree half provisioned.
NOGLOB="$ROOT/noglob-lib"
mkdir -p "$NOGLOB"
cp "$SCRIPT" "$(dirname "$SCRIPT")/myspec-config.sh" "$(dirname "$SCRIPT")/myspec-config.schema.json" \
  "$(dirname "$SCRIPT")/hook-core.sh" "$(dirname "$SCRIPT")/dependency-map.sh" "$NOGLOB/"
W=$(wt_for "$M" noglob-wt)
rc=0
out=$(bash "$NOGLOB/worktree-provision.sh" "$W" --base main 2>&1) || rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -qF "glob-regex.sh missing" && [ ! -e "$W/node_modules" ] && ok \
  || fail "a missing glob-regex.sh stops provisioning before any link (rc=$rc, got: $out)"

# Globs compile through lib/glob-regex.sh (its own fixture covers the rules).
# The scripts that read a glob setting source it and keep no copy, so one
# glob means one thing in clean, ignorePaths and checks[].paths.
for f in "$SCRIPT" "$HERE/../../hooks/mark-code-changed.sh" "$HERE/../../hooks/verify-before-stop.sh"; do
  grep -qE '^(glob_regex|glob_ere)\(\)' "$f" && fail "$(basename "$f") keeps its own glob compiler" || ok
  grep -qF 'glob-regex.sh' "$f" && ok || fail "$(basename "$f") uses lib/glob-regex.sh"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
