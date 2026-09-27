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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
