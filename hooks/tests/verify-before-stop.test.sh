#!/usr/bin/env bash
# Regression fixture for the linked node_modules gate in verify-before-stop.sh
# (issue #94).
#
# worktree-provision.sh links node_modules only when the branch leaves the
# lockfile alone, so a link it made must pass the Stop hook with default
# config. A link whose lockfiles differ from the checkout it points into, or a
# link with no lockfile to compare, must still block unless
# isolation.allowLinkedModules is set.
#
# Usage: verify-before-stop.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${1:-$HERE/../verify-before-stop.sh}"
PROVISION="$HERE/../../lib/worktree-provision.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
SID="vbs-$$"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# arm <sid> <cwd>: a code write in the cwd's checkout, recorded the way
# mark-code-changed.sh records it (lib/session-event.sh).
SESSION_EVENT="$(cd "$(dirname "$HOOK")" && pwd)/../lib/session-event.sh"
arm() {
  local top
  top=$(git -C "$2" rev-parse --show-toplevel)
  bash "$SESSION_EVENT" --root "$top" append "$1" "$(jq -nc --arg r "$top" '{t: "write", root: $r, rel: "src/edited.ts", kind: "code"}')"
}

# new_repo <name> <with-lockfile:0|1> -> prints main checkout path
new_repo() {
  local main="$ROOT/$1"
  mkdir -p "$main/.claude" "$main/node_modules/dep"
  git init -q -b main "$main"
  git -C "$main" config user.email t@t
  git -C "$main" config user.name t
  printf '{"checks":[{"name":"ok","command":"true","required":true}]}\n' > "$main/.claude/verification.json"
  printf 'node_modules\n' > "$main/.gitignore"
  [ "$2" = 1 ] && printf '{"lockfileVersion":3}\n' > "$main/package-lock.json"
  git -C "$main" add -A
  git -C "$main" commit -q -m init
  printf '%s\n' "$main"
}

# stop <sid-suffix> <cwd> -> prints the decision
stop() {
  arm "$SID-$1" "$2"
  printf '{"session_id":"%s-%s","cwd":%s}' "$SID" "$1" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$HOOK" 2>/dev/null | jq -r '.decision'
}

expect() {  # expect <want> <got> <desc>
  if [ "$1" = "$2" ]; then ok; else fail "$3 (want $1, got $2)"; fi
}

# --- provisioned link, lockfile unchanged: accepted ------------------------
MAIN=$(new_repo a 1)
WT="$ROOT/a-wt"
git -C "$MAIN" worktree add -q -b feat "$WT" main
bash "$PROVISION" "$WT" --base main >/dev/null
[ -L "$WT/node_modules" ] && ok || fail "provision links node_modules when the lockfile is unchanged"
expect approve "$(stop 1 "$WT")" "linked node_modules with identical lockfile is accepted"

# --- uncommitted lockfile edit under the link: blocked ---------------------
printf '{"lockfileVersion":3,"x":1}\n' > "$WT/package-lock.json"
expect block "$(stop 2 "$WT")" "uncommitted lockfile change under a link blocks"
bash "$SESSION_EVENT" --root "$WT" events "$SID-2" | jq -e 'select(.t == "verified")' >/dev/null \
  && fail "a block records no verified event, so the checkout stays armed" || ok

# --- committed lockfile change, stale link: blocked -------------------------
git -C "$WT" commit -q -am "bump lock"
expect block "$(stop 3 "$WT")" "committed lockfile change under a link blocks"

# --- provision declines to link a changed-lockfile branch -------------------
WT2="$ROOT/a-wt2"
git -C "$MAIN" worktree add -q -b feat2 "$WT2" feat
bash "$PROVISION" "$WT2" --base main >/dev/null
[ ! -e "$WT2/node_modules" ] && ok || fail "provision skips the link when the lockfile changed"

# --- allowLinkedModules still overrides a mismatch --------------------------
printf '{"isolation":{"allowLinkedModules":true}}\n' > "$WT/.myspec.json"
expect approve "$(stop 4 "$WT")" "allowLinkedModules accepts a mismatched link"
rm -f "$WT/.myspec.json"

# --- no lockfile anywhere: no evidence, blocked -----------------------------
MAIN_B=$(new_repo b 0)
WT_B="$ROOT/b-wt"
git -C "$MAIN_B" worktree add -q -b feat "$WT_B" main
bash "$PROVISION" "$WT_B" --base main >/dev/null
expect block "$(stop 5 "$WT_B")" "link with no lockfile to compare blocks"

# --- a real install is untouched by the gate --------------------------------
rm "$WT_B/node_modules"
mkdir "$WT_B/node_modules"
expect approve "$(stop 6 "$WT_B")" "a real node_modules directory is accepted"

# --- other ecosystems: the guard follows each configured entry ---------------
# new_dep_repo <name> <dir> <lockfile> <myspec-json> -> prints main checkout path
new_dep_repo() {
  local main="$ROOT/$1"
  mkdir -p "$main/.claude" "$main/$2/dep"
  git init -q -b main "$main"
  git -C "$main" config user.email t@t
  git -C "$main" config user.name t
  printf '{"checks":[{"name":"ok","command":"true","required":true}]}\n' > "$main/.claude/verification.json"
  printf '%s\n' "$2" > "$main/.gitignore"
  printf 'v1\n' > "$main/$3"
  [ -n "$4" ] && printf '%s\n' "$4" > "$main/.myspec.json"
  git -C "$main" add -A
  git -C "$main" commit -q -m init
  printf '%s\n' "$main"
}

# dep_case <name> <dir> <lockfile> <myspec-json> <sid-base>
dep_case() {
  local main wt wt2
  main=$(new_dep_repo "$1" "$2" "$3" "$4")
  wt="$ROOT/$1-wt"
  git -C "$main" worktree add -q -b feat "$wt" main
  bash "$PROVISION" "$wt" --base main >/dev/null
  [ -L "$wt/$2" ] && ok || fail "$1: provision links $2 when $3 is unchanged"
  expect approve "$(stop "$5-1" "$wt")" "$1: linked $2 with identical $3 is accepted"
  printf 'v2\n' > "$wt/$3"
  expect block "$(stop "$5-2" "$wt")" "$1: uncommitted $3 change under a linked $2 blocks"
  git -C "$wt" commit -q -am "bump lock"
  expect block "$(stop "$5-3" "$wt")" "$1: committed $3 change under a linked $2 blocks"
  wt2="$ROOT/$1-wt2"
  git -C "$main" worktree add -q -b feat2 "$wt2" feat
  local out
  out=$(bash "$PROVISION" "$wt2" --base main)
  [ ! -e "$wt2/$2" ] && ok || fail "$1: provision skips $2 when $3 changed"
  printf '%s' "$out" | grep -qF "not linking $2" && ok || fail "$1: provision says why it skipped $2"
}

dep_case php vendor composer.lock '{"isolation":{"provision":{"symlink":["vendor"]}}}' 10
dep_case py .venv poetry.lock '{"isolation":{"provision":{"symlink":[".venv"]}}}' 20
dep_case pyreq .venv requirements-dev.txt '{"isolation":{"provision":{"symlink":[".venv"]}}}' 30
dep_case custom deps deps.lock '{"isolation":{"provision":{"symlink":[{"path":"deps","lockfiles":["deps.lock"]}]}}}' 40

# --- a hand-made vendor link is caught with no config at all ----------------
MAIN_H=$(new_dep_repo hand vendor composer.lock '')
WT_H="$ROOT/hand-wt"
git -C "$MAIN_H" worktree add -q -b feat "$WT_H" main
ln -s "$MAIN_H/vendor" "$WT_H/vendor"
expect approve "$(stop 50 "$WT_H")" "hand-made vendor link with identical composer.lock is accepted"
printf 'v2\n' > "$WT_H/composer.lock"
expect block "$(stop 51 "$WT_H")" "hand-made vendor link with a changed composer.lock blocks"
expect approve "$(MYSPEC_ALLOW_LINKED_MODULES=1 stop 52 "$WT_H")" "MYSPEC_ALLOW_LINKED_MODULES=1 accepts a mismatched vendor link"

# --- lockfiles: [] opts an entry out; an unknown entry is not guarded --------
MAIN_O=$(new_dep_repo optout vendor composer.lock '{"isolation":{"provision":{"symlink":[{"path":"vendor","lockfiles":[]},".env"]}}}')
printf 'X=1\n' > "$MAIN_O/.env"
WT_O="$ROOT/optout-wt"
git -C "$MAIN_O" worktree add -q -b feat "$WT_O" main
printf 'v2\n' > "$WT_O/composer.lock"
git -C "$WT_O" commit -q -am "bump lock"
bash "$PROVISION" "$WT_O" --base main >/dev/null
[ -L "$WT_O/vendor" ] && ok || fail "lockfiles: [] links vendor despite a changed composer.lock"
[ -L "$WT_O/.env" ] && ok || fail "an unknown entry is linked"
expect approve "$(stop 60 "$WT_O")" "lockfiles: [] and an unknown .env link do not block"

# --- nested entry: pinned by the lockfile beside it --------------------------
MAIN_N=$(new_dep_repo nested apps/web/node_modules apps/web/package-lock.json '{"isolation":{"provision":{"symlink":["apps/web/node_modules"]}}}')
WT_N="$ROOT/nested-wt"
git -C "$MAIN_N" worktree add -q -b feat "$WT_N" main
bash "$PROVISION" "$WT_N" --base main >/dev/null
[ -L "$WT_N/apps/web/node_modules" ] && ok || fail "nested: provision links apps/web/node_modules"
expect approve "$(stop 70 "$WT_N")" "nested: identical apps/web/package-lock.json is accepted"
printf 'v2\n' > "$WT_N/apps/web/package-lock.json"
expect block "$(stop 71 "$WT_N")" "nested: a changed apps/web/package-lock.json blocks"

# --- a tree that loads the project's own source blocks despite equal lockfiles
MAIN_C=$(new_dep_repo composer vendor composer.lock '{"isolation":{"provision":{"symlink":["vendor"]}}}')
mkdir -p "$MAIN_C/vendor/composer"
printf "<?php\nreturn array('App\\\\\\\\' => array(\$baseDir . '/src'));\n" > "$MAIN_C/vendor/composer/autoload_psr4.php"
WT_C="$ROOT/composer-wt"
git -C "$MAIN_C" worktree add -q -b feat "$WT_C" main
ln -s "$MAIN_C/vendor" "$WT_C/vendor"
expect block "$(stop 80 "$WT_C")" "a vendor whose Composer autoload maps \$baseDir blocks"

MAIN_E=$(new_dep_repo editable .venv uv.lock '{"isolation":{"provision":{"symlink":[".venv"]}}}')
mkdir -p "$MAIN_E/.venv/lib/python3.12/site-packages/app-0.1.dist-info"
printf '{"url":"file://%s","dir_info":{"editable":true}}\n' "$MAIN_E" \
  > "$MAIN_E/.venv/lib/python3.12/site-packages/app-0.1.dist-info/direct_url.json"
WT_E="$ROOT/editable-wt"
git -C "$MAIN_E" worktree add -q -b feat "$WT_E" main
ln -s "$MAIN_E/.venv" "$WT_E/.venv"
expect block "$(stop 81 "$WT_E")" "a .venv with an editable install of the main checkout blocks"

# --- an unlisted .venv pointing outside this repo is not the gate's business --
MAIN_V=$(new_dep_repo central src/x poetry.lock '')
mkdir -p "$ROOT/store/proj"
ln -s "$ROOT/store/proj" "$MAIN_V/.venv"
expect approve "$(stop 82 "$MAIN_V")" "a .venv linked to a central store is accepted in the main checkout"

# --- ./vendor is the same entry as vendor -------------------------------------
MAIN_D=$(new_dep_repo dotslash vendor composer.lock '{"isolation":{"provision":{"symlink":["./vendor"]}}}')
WT_D="$ROOT/dotslash-wt"
git -C "$MAIN_D" worktree add -q -b feat "$WT_D" main
ln -s "$MAIN_D/vendor" "$WT_D/vendor"
expect approve "$(stop 83 "$WT_D")" "./vendor with identical composer.lock is accepted"

# --- an empty lockfile name does not abort the hook --------------------------
MAIN_Z=$(new_dep_repo emptylock deps deps.lock '{"isolation":{"provision":{"symlink":[{"path":"deps","lockfiles":[""]}]}}}')
WT_Z="$ROOT/emptylock-wt"
git -C "$MAIN_Z" worktree add -q -b feat "$WT_Z" main
ln -s "$MAIN_Z/deps" "$WT_Z/deps"
expect approve "$(stop 84 "$WT_Z")" "lockfiles: [\"\"] is unguarded and does not abort"

# --- a string lockfiles still guards; vendor/bundle is guarded by Gemfile.lock -
MAIN_S=$(new_dep_repo strlock vendor composer.lock '{"isolation":{"provision":{"symlink":["node_modules",{"path":"vendor","lockfiles":"composer.lock"}]}}}')
WT_S="$ROOT/strlock-wt"
git -C "$MAIN_S" worktree add -q -b feat "$WT_S" main
ln -s "$MAIN_S/vendor" "$WT_S/vendor"
printf 'v2\n' > "$WT_S/composer.lock"
expect block "$(stop 85 "$WT_S")" "\"lockfiles\": \"composer.lock\" still guards vendor"

MAIN_R=$(new_dep_repo bundle vendor/bundle Gemfile.lock '{"isolation":{"provision":{"symlink":["vendor/bundle"]}}}')
WT_R="$ROOT/bundle-wt"
git -C "$MAIN_R" worktree add -q -b feat "$WT_R" main
mkdir -p "$WT_R/vendor"
ln -s "$MAIN_R/vendor/bundle" "$WT_R/vendor/bundle"
expect approve "$(stop 86 "$WT_R")" "vendor/bundle with identical Gemfile.lock is accepted"
printf 'v2\n' > "$WT_R/Gemfile.lock"
expect block "$(stop 87 "$WT_R")" "vendor/bundle with a changed Gemfile.lock blocks"

# --- a workspace link out of a linked tree blocks despite equal lockfiles (#229)
# The triage repro: apps/web/node_modules linked into main, its workspace link
# ../../../../packages/ui then resolves to main's packages/ui.
MAIN_W=$(new_dep_repo workspace apps/web/node_modules lock.yaml '{"isolation":{"provision":{"symlink":[{"path":"apps/web/node_modules","lockfiles":["lock.yaml"]}]}}}')
mkdir -p "$MAIN_W/packages/ui" "$MAIN_W/apps/web/node_modules/@acme"
ln -s ../../../../packages/ui "$MAIN_W/apps/web/node_modules/@acme/ui"
WT_W="$ROOT/workspace-wt"
git -C "$MAIN_W" worktree add -q -b feat "$WT_W" main
mkdir -p "$WT_W/apps/web"
ln -s "$MAIN_W/apps/web/node_modules" "$WT_W/apps/web/node_modules"
expect block "$(stop 100 "$WT_W")" "a linked tree whose workspace link resolves into main blocks"
rm "$MAIN_W/apps/web/node_modules/@acme/ui"
ln -s ../.store/ui "$MAIN_W/apps/web/node_modules/@acme/ui"
expect approve "$(stop 101 "$WT_W")" "a linked tree whose links stay inside it is accepted"
# The same tree with its root unlistable (0311: enterable, not readable): the
# scan sees no link, so it counts as loading and blocks (#251 review).
if [ "$(id -u)" -ne 0 ]; then
  chmod 0311 "$MAIN_W/apps/web/node_modules"
  d=$(stop 104 "$WT_W")
  chmod 755 "$MAIN_W/apps/web/node_modules"
  expect block "$d" "a linked tree whose root cannot be listed blocks"
fi

# --- vendor-bin/*/vendor is guarded with no config (#222) --------------------
MAIN_B2=$(new_dep_repo binplugin vendor-bin/tool/vendor vendor-bin/tool/composer.lock '')
WT_B2="$ROOT/binplugin-wt"
git -C "$MAIN_B2" worktree add -q -b feat "$WT_B2" main
ln -s "$MAIN_B2/vendor-bin/tool/vendor" "$WT_B2/vendor-bin/tool/vendor"
expect approve "$(stop 102 "$WT_B2")" "vendor-bin/tool/vendor link with identical composer.lock is accepted"
printf 'v2\n' > "$WT_B2/vendor-bin/tool/composer.lock"
expect block "$(stop 103 "$WT_B2")" "vendor-bin/tool/vendor link with a changed composer.lock blocks"

# --- a container exec without runIn is unverifiable in a linked worktree (#220)
# A fake docker on PATH: a check that runs reports what it ran and passes.
BIN="$ROOT/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/docker"
cp "$BIN/docker" "$BIN/docker-compose"
chmod +x "$BIN/docker" "$BIN/docker-compose"
MAIN_X=$(new_dep_repo compose src/app app.lock '')
WT_X="$ROOT/compose-wt"
git -C "$MAIN_X" worktree add -q -b feat "$WT_X" main
# compose_stop <sid> <cwd> <command> -> "decision<TAB>reason"
compose_stop() {
  local cfg
  cfg=$(jq -n --arg c "$3" '{checks:[{name:"Lint",command:$c,required:true}]}')
  printf '%s\n' "$cfg" > "$2/.claude/verification.json"
  arm "$SID-$1" "$2"
  printf '{"session_id":"%s-%s","cwd":%s}' "$SID" "$1" "$(printf '%s' "$2" | jq -Rs .)" \
    | PATH="$BIN:$PATH" bash "$HOOK" 2>/dev/null | jq -r '[.decision, (.reason // "")] | @tsv'
}
r=$(compose_stop 110 "$WT_X" "docker compose exec svc make lint")
expect block "${r%%$'\t'*}" "worktree: docker compose exec without runIn blocks"
case "$r" in *unverifiable*) ok ;; *) fail "worktree: the reason says the check is unverifiable" ;; esac
case "$r" in *runIn*) ok ;; *) fail "worktree: the reason names runIn" ;; esac
r=$(compose_stop 112 "$WT_X" "true && docker compose exec -T svc make lint")
expect block "${r%%$'\t'*}" "worktree: an exec in a later simple command blocks"
r=$(compose_stop 115 "$WT_X" "docker compose run --rm svc make lint")
expect approve "${r%%$'\t'*}" "worktree: docker compose run is not refused"
r=$(compose_stop 116 "$MAIN_X" "docker compose exec svc make lint")
expect approve "${r%%$'\t'*}" "main checkout: docker compose exec without runIn runs as before"

# A -w is not read any more: only runIn says where the work runs (R8a).
r=$(compose_stop 113 "$WT_X" "docker compose exec -w /srv/wt svc make lint")
expect block "${r%%$'\t'*}" "worktree: docker compose exec -w without runIn blocks"
r=$(compose_stop 114 "$WT_X" "docker exec --workdir=/srv/wt app make lint")
expect block "${r%%$'\t'*}" "worktree: docker exec --workdir= without runIn blocks"

# Every exec form in CONTAINER_EXEC_FORMS, not only compose (#220 review),
# whatever the spacing or the path the program is called by.
printf '#!/bin/sh\nexit 0\n' > "$BIN/podman"
cp "$BIN/podman" "$BIN/podman-compose"
chmod +x "$BIN/podman" "$BIN/podman-compose"
sid=120
for c in "docker exec app make lint" \
         "docker container exec app make lint" \
         "docker-compose -f compose.yaml exec svc make lint" \
         "podman exec app make lint" \
         "podman container exec app make lint" \
         "podman compose exec svc make lint" \
         "podman-compose exec svc make lint" \
         "docker  compose   exec svc make lint" \
         "docker --context ci compose -p app exec svc make lint" \
         "sh -c 'docker exec app make lint'" \
         "env $BIN/docker exec app make lint"; do
  r=$(compose_stop "$sid" "$WT_X" "$c")
  expect block "${r%%$'\t'*}" "worktree: '$c' without runIn blocks"
  case "$r" in *unverifiable*) ok ;; *) fail "worktree: '$c' is refused as unverifiable" ;; esac
  sid=$((sid + 1))
done
for c in "docker run --rm -v .:/srv img make lint" \
         "docker container ls" \
         "docker compose ps" \
         "docker compose run svc sh -c exec" \
         "echo mydocker exec"; do
  r=$(compose_stop "$sid" "$WT_X" "$c")
  expect approve "${r%%$'\t'*}" "worktree: '$c' runs"
  sid=$((sid + 1))
done
r=$(compose_stop 141 "$MAIN_X" "docker exec app make lint")
expect approve "${r%%$'\t'*}" "main checkout: docker exec without runIn runs as before"

# A submodule inside a linked worktree is in that worktree: its git dir is
# its own common dir, so the superproject decides (#220 review).
SUBSRC="$ROOT/subsrc"
mkdir -p "$SUBSRC/.claude"
git init -q -b main "$SUBSRC"
printf '{}\n' > "$SUBSRC/.claude/verification.json"
git -C "$SUBSRC" add -A
git -C "$SUBSRC" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$MAIN_X" -c protocol.file.allow=always submodule add -q "$SUBSRC" sub >/dev/null 2>&1
git -C "$MAIN_X" commit -q -m "add sub"
WT_XS="$ROOT/compose-sub-wt"
git -C "$MAIN_X" worktree add -q -b feat-sub "$WT_XS" main
git -C "$WT_XS" -c protocol.file.allow=always submodule update -q --init >/dev/null 2>&1
[ -f "$WT_XS/sub/.claude/verification.json" ] && ok || fail "fixture: the linked worktree has its submodule checked out"
r=$(compose_stop 142 "$WT_XS/sub" "docker compose exec svc make lint")
expect block "${r%%$'\t'*}" "submodule of a linked worktree: docker compose exec without runIn blocks"
r=$(compose_stop 143 "$MAIN_X/sub" "docker compose exec svc make lint")
expect approve "${r%%$'\t'*}" "submodule of the main checkout: docker compose exec without runIn runs"

# A find without -lname (BusyBox) still blocks the #229 repro (#229 review).
REAL_FIND=$(command -v find)
SHIM="$ROOT/find-shim"
mkdir -p "$SHIM"
# shellcheck disable=SC2016 # the shim's own "$@", expanded when it runs
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -lname ] && { echo "find: unrecognized: -lname" >&2; exit 1; }; done\nexec %s "$@"\n' "$REAL_FIND" > "$SHIM/find"
chmod +x "$SHIM/find"
rm "$MAIN_W/apps/web/node_modules/@acme/ui"
ln -s ../../../../packages/ui "$MAIN_W/apps/web/node_modules/@acme/ui"
arm "$SID-144" "$WT_W"
d=$(printf '{"session_id":"%s-144","cwd":%s}' "$SID" "$(printf '%s' "$WT_W" | jq -Rs .)" \
  | PATH="$SHIM:$PATH" bash "$HOOK" 2>/dev/null | jq -r '.decision')
expect block "$d" "a find without -lname still blocks a workspace link into main"

# A find that cannot run the scan at all (no -mindepth) still blocks: an
# unscanned tree is never accepted.
# shellcheck disable=SC2016 # the shim's own "$@", expanded when it runs
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -mindepth ] && { echo "find: unrecognized: -mindepth" >&2; exit 1; }; done\nexec %s "$@"\n' "$REAL_FIND" > "$SHIM/find"
arm "$SID-145" "$WT_W"
d=$(printf '{"session_id":"%s-145","cwd":%s}' "$SID" "$(printf '%s' "$WT_W" | jq -Rs .)" \
  | PATH="$SHIM:$PATH" bash "$HOOK" 2>/dev/null | jq -r '.decision')
expect block "$d" "a find without -mindepth leaves the tree unscanned, which blocks"

# An unreadable directory inside a linked tree makes find exit non-zero after
# it listed everything it could read. That is not evidence the tree loads the
# main checkout's source: a provisioned link with matching lockfiles passes.
if [ "$(id -u)" -ne 0 ]; then
  MAIN_U=$(new_repo unreadable 1)
  WT_U="$ROOT/unreadable-wt"
  git -C "$MAIN_U" worktree add -q -b feat "$WT_U" main
  bash "$PROVISION" "$WT_U" --base main >/dev/null
  mkdir -p "$MAIN_U/node_modules/.cache/locked"
  chmod 000 "$MAIN_U/node_modules/.cache"
  expect approve "$(stop 146 "$WT_U")" "an unreadable directory in a linked tree with matching lockfiles passes"
  chmod 755 "$MAIN_U/node_modules/.cache"
fi

# --- memory gate: stale-ref ID collisions warn, they do not block (#124) -----
# S001 is added on feat/a, merged, reverted on main and reused there; feat/c
# and feat/d both take P001 and never merge. Touching the memory tree must not
# block the stop on either; an error the session made still does.
MAIN_M=$(new_repo memory 0)
LIB="$HERE/../../lib"
mkdir -p "$MAIN_M/.claude/lib" "$MAIN_M/.ai/memory/semantic"
cp "$LIB/memory-doctor.mjs" "$LIB/memory-files.mjs" "$LIB/memory-index.mjs" "$LIB/memory-claim-id.sh" "$MAIN_M/.claude/lib/"
printf '{"aiDir":".ai/"}\n' > "$MAIN_M/.myspec.json"
printf 'node_modules\n.claude/state/\n.claude/lib/\n' > "$MAIN_M/.gitignore"
mem() {  # mem <file> <id> <hook>
  printf -- '---\nid: %s\nhook: "%s"\n---\n\n# %s\n' "$2" "$3" "$2" > "$MAIN_M/.ai/memory/$1"
}
sem_index() {  # sem_index [row]
  printf '# Index\n\n| ID | Hook | Anchor |\n|---|---|---|\n%s' "${1:+$1
}" > "$MAIN_M/.ai/memory/semantic/index.md"
}
commit_m() { git -C "$MAIN_M" add -A && git -C "$MAIN_M" commit -q -m "$1"; }
sem_index
commit_m "memory tree"
git -C "$MAIN_M" checkout -q -b feat/a
mem semantic/S001-x.md S001 x
sem_index '| [S001](S001-x.md) | x | |'
commit_m S001-x
git -C "$MAIN_M" checkout -q main
git -C "$MAIN_M" merge -q --no-ff -m "merge a" feat/a
git -C "$MAIN_M" revert --no-edit -m 1 HEAD >/dev/null
mem semantic/S001-y.md S001 y
sem_index '| [S001](S001-y.md) | y | |'
commit_m S001-y
for b in c d; do
  git -C "$MAIN_M" checkout -q -b "feat/$b" main
  mkdir -p "$MAIN_M/.ai/memory/procedural"
  mem "procedural/P001-$b.md" P001 "$b"
  commit_m "P001-$b"
done
git -C "$MAIN_M" checkout -q main
printf 'edited\n' >> "$MAIN_M/.ai/memory/semantic/S001-y.md"
expect approve "$(stop 90 "$MAIN_M")" "stale-ref duplicate IDs do not block a stop that touched memory"
mem semantic/S002-z.md S002 ""
expect block "$(stop 91 "$MAIN_M")" "a memory error the session made still blocks"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
