#!/usr/bin/env bash
# Function tests for lib/stop-gate/arm.sh and lib/stop-gate/provision.sh, the
# stop gate's arming decision and its provision-record comparison
# (docs/stop-gate.md, R1 to R3a, R5, R6, R8). The modules are sourced and
# their functions called on small fixtures; the end-to-end paths stay in
# hooks/tests/verify-before-stop*.test.sh.
#
# Usage: stop-gate-arm.test.sh [path-to-lib]

set -uo pipefail

LIB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/session-event.sh
. "$LIB/session-event.sh"
# shellcheck source=lib/stop-gate/arm.sh
. "$LIB/stop-gate/arm.sh"
# shellcheck source=lib/stop-gate/provision.sh
. "$LIB/stop-gate/provision.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) fail "$3 (no '$2' in: $1)" ;; esac; }

git_() { git -c user.email=t@t -c user.name=t -c protocol.file.allow=always "$@"; }
REPO="$ROOT/repo"
mkdir -p "$REPO/.claude" "$REPO/src"
git_ init -q -b main "$REPO"
printf '.claude/state/\n.claude/worktrees/\n' > "$REPO/.gitignore"
printf 'a\n' > "$REPO/src/a.ts"
printf 'b\n' > "$REPO/src/b.ts"
printf '{"checks":[]}\n' > "$REPO/.claude/verification.json"
git_ -C "$REPO" add -A
git_ -C "$REPO" commit -q -m init
WT="$REPO/.claude/worktrees/w"
git_ -C "$REPO" worktree add -q -b feat "$WT" main

N=0
# write <root> <kind> <rel> -> a write event in a fresh session (SESSION_ID).
new_session() { N=$((N + 1)); SESSION_ID="arm-$N"; }
write() {
  session_append "$REPO" "$SESSION_ID" "$(jq -nc --arg r "$1" --arg k "$2" --arg p "$3" '{t: "write", root: $r, rel: $p, kind: $k}')"
}
roots() { arm_init "$REPO"; armed_roots; printf '%s\n' ${VERIFY_ROOTS[@]+"${VERIFY_ROOTS[@]}"}; }

# --- armed_roots (R1, R2, R3a) -----------------------------------------------------
new_session
eq "$(roots)" "" "no write arms nothing"
write "$REPO" file docs/notes.md
eq "$(roots)" "" "R1: a non-code write arms nothing"
write "$ROOT/elsewhere" code x.ts
eq "$(roots)" "" "R2: a code write in another repository arms nothing here"
write "$REPO" code src/a.ts
eq "$(roots)" "$REPO" "R1: a code write arms its checkout"
new_session
write "$WT" code src/a.ts
eq "$(roots)" "$WT" "R3a: a worktree edited from the main checkout's cwd is the one armed"
write "$REPO" code src/b.ts
eq "$(roots)" "$(printf '%s\n%s' "$WT" "$REPO")" "R3a: both checkouts, in first-written order"
arm_init "$REPO"; armed_roots
finish_run
eq "$(roots)" "" "finish_run records verified for each root, which disarms it"
write "$WT" code src/b.ts
eq "$(roots)" "$WT" "a later code write re-arms only its checkout"
SESSION_ID=""
eq "$(roots)" "" "without a session id nothing is armed"

# A submodule's root is verified through the superproject and recorded too.
MOD="$ROOT/modsrc"
git_ init -q -b main "$MOD"
printf 'm\n' > "$MOD/m.ts"
git_ -C "$MOD" add -A && git_ -C "$MOD" commit -q -m init
git_ -C "$REPO" submodule add -q "$MOD" mod >/dev/null 2>&1
git_ -C "$REPO" commit -q -m sub
new_session
write "$REPO/mod" code m.ts
arm_init "$REPO"; armed_roots
eq "${VERIFY_ROOTS[*]}" "$REPO" "a submodule write verifies the superproject"
eq "${NESTED_ROOTS[*]:-}" "$REPO/mod" "the submodule root is kept for its verified event"
ROOT_KEY="$REPO"
eq "$(session_files)" "mod/m.ts" "session_files: a submodule write counts under the superproject"
finish_run
eq "$(session_events "$REPO" "$SESSION_ID" | jq -r 'select(.t == "verified") | .root' | sort | paste -sd' ' -)" "$REPO $REPO/mod" "finish_run marks the nested root verified too"

# --- changed_files ------------------------------------------------------------------
REPO_ROOT="$WT"
git_ -C "$WT" mv src/a.ts src/renamed.ts
printf 'new\n' > "$WT/src/new.ts"
eq "$(changed_files | sort | paste -sd' ' -)" "src/a.ts src/new.ts src/renamed.ts" "changed_files: both sides of a rename and an untracked file"
git_ -C "$WT" reset -q --hard
rm -f "$WT/src/new.ts"

# --- base_ref (R5) and arm_root ---------------------------------------------------------
REPO_ROOT="$WT"
base_ref
FORK=$(git -C "$WT" merge-base main HEAD)
eq "$MYSPEC_BASE_REF" "$FORK" "base_ref: the merge base with main"
printf 'x\n' > "$WT/src/c.ts"
git_ -C "$WT" add -A && git_ -C "$WT" commit -q -m c
base_ref
eq "$MYSPEC_BASE_REF" "$FORK" "base_ref: a commit on the branch does not move it"
NOBASE="$ROOT/nobase"
git_ init -q -b trunk "$NOBASE" && git_ -C "$NOBASE" commit -q --allow-empty -m init
REPO_ROOT="$NOBASE"
base_ref
eq "$MYSPEC_BASE_REF" "" "base_ref: empty without a default branch"

new_session
write "$WT" code src/a.ts
arm_init "$REPO"
arm_root "$WT"
eq "$ROOT_LABEL" " [in $WT]" "arm_root: a checkout other than the cwd's is named"
eq "$ROOT_IS_LINKED" 1 "arm_root: a linked worktree"
eq "$MYSPEC_SESSION_FILES" "src/a.ts" "arm_root: the session's files there"
arm_root "$REPO"
eq "$ROOT_LABEL" "" "arm_root: the cwd's checkout has no label"
eq "$ROOT_IS_LINKED" 0 "arm_root: the main checkout is not linked"

# --- is_linked_worktree (R8a) -----------------------------------------------------------
git_ -C "$WT" submodule update -q --init >/dev/null 2>&1
is_linked_worktree "$WT/mod" && ok || fail "a submodule checked out in a linked worktree counts as linked"
is_linked_worktree "$REPO/mod" && fail "a submodule of the main checkout is not linked" || ok

# --- implement_state (R6) ------------------------------------------------------------------
STATE_HOME="$REPO"
new_session
implement_state
eq "$IMPLEMENT_ACTIVE" 0 "no implement run"
session_append "$REPO" "$SESSION_ID" '{"t":"implement","state":"start"}'
implement_state
eq "$IMPLEMENT_ACTIVE" 1 "a fresh start is active"

# --- provision_stale and provision_check (R8) -------------------------------------------------
P="$ROOT/prov"
mkdir -p "$P/vendor/dep"
git_ init -q -b main "$P"
printf 'vendor\n.claude/state/\n' > "$P/.gitignore"
printf 'v1\n' > "$P/composer.lock"
git_ -C "$P" add -A && git_ -C "$P" commit -q -m init
PW="$ROOT/prov-wt"
git_ -C "$P" worktree add -q -b feat "$PW" main
ln -s "$P/vendor" "$PW/vendor"
mkdir -p "$PW/.claude/state"
record() {  # record <target> <lock hash>
  jq -n --arg s "$P" --arg t "$1" --arg h "$2" '{source: $s, links: [{path: "vendor", target: $t, lockfiles: {"composer.lock": $h}}]}' > "$PW/.claude/state/provision.json"
}
HASH=$(file_sha256 "$P/composer.lock")
record "$P/vendor" "$HASH"
eq "$(provision_stale "$PW")" "" "a record that matches is not stale"
printf 'v2\n' > "$PW/composer.lock"
eq "$(provision_stale "$PW")" "vendor (composer.lock changed)" "a lockfile changed in the worktree"
printf 'v1\n' > "$PW/composer.lock"
printf 'v2\n' > "$P/composer.lock"
eq "$(provision_stale "$PW")" "vendor (composer.lock changed)" "a lockfile changed in the source"
printf 'v1\n' > "$P/composer.lock"
mkdir -p "$ROOT/elsewhere-vendor"
rm "$PW/vendor" && ln -s "$ROOT/elsewhere-vendor" "$PW/vendor"
eq "$(provision_stale "$PW")" "vendor (the link no longer points into $P)" "a link that moved"
rm "$PW/vendor" && ln -s "$ROOT/gone" "$PW/vendor"
eq "$(provision_stale "$PW")" "vendor (the link no longer points into $P)" "a dangling link"
rm "$PW/vendor" && mkdir "$PW/vendor"
printf 'v3\n' > "$PW/composer.lock"
eq "$(provision_stale "$PW")" "" "a real directory at a recorded path is not compared"
printf 'v1\n' > "$PW/composer.lock"
rmdir "$PW/vendor" && ln -s "$P/vendor" "$PW/vendor"
printf '{"source":' > "$PW/.claude/state/provision.json"
out=$(provision_stale "$PW") && fail "an unparseable record fails" || ok
[ -n "$out" ] && ok || fail "an unparseable record gives a reason"
printf '{"links":[]}' > "$PW/.claude/state/provision.json"
eq "$(provision_stale "$PW")" "the record has no source" "a record without a source fails"

# provision_check exits through decision_block; run it in a subshell.
record "$P/vendor" "0"
out=$(provision_check "$PW")
has "$out" '"decision": "block"' "provision_check blocks a stale linked worktree"
has "$out" "worktree-provision.sh" "provision_check names the provision script"
mkdir -p "$P/.claude/state"
cp "$PW/.claude/state/provision.json" "$P/.claude/state/provision.json"
eq "$(provision_check "$P")" "" "the main checkout is never compared"
rm "$PW/.claude/state/provision.json"
eq "$(provision_check "$PW")" "" "a worktree without a record is not compared"

printf '\nstop-gate-arm: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
