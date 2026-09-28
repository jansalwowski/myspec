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
trap 'rm -rf "$ROOT"; rm -f /tmp/.myspec-code-changed-'"$SID"'-*' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

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
  touch "/tmp/.myspec-code-changed-$SID-$1"
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
[ -f "/tmp/.myspec-code-changed-$SID-2" ] && ok || fail "block leaves the marker in place"

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
