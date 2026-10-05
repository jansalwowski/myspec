#!/usr/bin/env bash
# End-to-end fixture for verify-before-stop.sh: linked dependency directories
# (R8, issues #94, #229, #239), container execs in a linked worktree (R8a) and
# the memory gate (#124).
#
# worktree-provision.sh records each link it makes, with the hash of every
# lockfile that pinned it, in .claude/state/provision.json. A link it made
# must pass with default config; a recorded lockfile that changed since must
# block until provision runs again. The other record cases (a moved or
# dangling link, a real install, no record, the main checkout, an unreadable
# record, any stack's lockfile) are function tests of provision_stale and
# provision_check in lib/tests/stop-gate-arm.test.sh; each exec form is one in
# lib/tests/stop-gate-run.test.sh.
#
# Usage: verify-before-stop.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${1:-$HERE/../verify-before-stop.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"
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

# stop_reason <sid-suffix> <cwd> -> prints the block reason (empty on approve)
stop_reason() {
  arm "$SID-$1" "$2"
  printf '{"session_id":"%s-%s","cwd":%s}' "$SID" "$1" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$HOOK" 2>/dev/null | jq -r '.reason // empty'
}

expect_in() {  # expect_in <needle> <haystack> <desc>
  case "$2" in *"$1"*) ok ;; *) fail "$3 (no '$1' in: $2)" ;; esac
}

# --- R8: a provisioned link whose record still matches is accepted ------------
MAIN=$(new_repo a 1)
WT="$ROOT/a-wt"
git -C "$MAIN" worktree add -q -b feat "$WT" main
bash "$PROVISION" "$WT" --base main >/dev/null
[ -L "$WT/node_modules" ] && [ -f "$WT/.claude/state/provision.json" ] && ok || fail "provision links node_modules and records it"
expect approve "$(stop 1 "$WT")" "a provisioned link whose lockfile is unchanged is accepted"

# --- a lockfile changed in the worktree since provisioning blocks ---------------
printf '{"lockfileVersion":3,"x":1}\n' > "$WT/package-lock.json"
r=$(stop_reason 2 "$WT")
expect_in "dependencies in node_modules were provisioned from lockfiles that changed" "$r" "a worktree lockfile change blocks with the provision message"
expect_in "node_modules (package-lock.json changed)" "$r" "the block names the link and the lockfile"
expect_in "worktree-provision.sh \"$WT\"" "$r" "the block names the provision script and the worktree"
bash "$SESSION_EVENT" --root "$WT" events "$SID-2" | jq -e 'select(.t == "verified")' >/dev/null \
  && fail "a block records no verified event, so the checkout stays armed" || ok

# --- a lockfile changed in the main checkout since provisioning blocks ----------
git -C "$WT" checkout -q -- package-lock.json
printf '{"lockfileVersion":3,"y":1}\n' > "$MAIN/package-lock.json"
expect block "$(stop 4 "$WT")" "a lockfile changed in the main checkout blocks"

# --- re-running provision clears the block --------------------------------------
# The worktree's lockfile now differs from the main checkout's, so provision
# drops the link (and says to install); nothing on record is stale.
bash "$PROVISION" "$WT" --base main >/dev/null
[ ! -e "$WT/node_modules" ] && ok || fail "provision rerun drops a link whose lockfile now differs"
expect approve "$(stop 5 "$WT")" "after provision reruns, the record matches and the checks run"
git -C "$MAIN" checkout -q -- package-lock.json

# --- a nested lockfile the branch adds after provisioning blocks (#256 review) ---
# apps/web/node_modules is pinned by apps/web/package-lock.json or the root
# one; only the root one exists when provision links it.
MAIN=$(new_repo nested 1)
mkdir -p "$MAIN/apps/web/node_modules/dep"
printf '{"isolation":{"provision":{"symlink":["apps/web/node_modules"]}}}\n' > "$MAIN/.myspec.json"
printf 'apps/web/node_modules\n' >> "$MAIN/.gitignore"
git -C "$MAIN" add -A && git -C "$MAIN" commit -q -m nested
WT="$ROOT/nested-wt"
git -C "$MAIN" worktree add -q -b feat-nested "$WT" main
bash "$PROVISION" "$WT" --base main >/dev/null
[ -L "$WT/apps/web/node_modules" ] && ok || fail "nested: provision links apps/web/node_modules"
expect approve "$(stop 6 "$WT")" "nested: the record matches"
printf '{"lockfileVersion":3}\n' > "$WT/apps/web/package-lock.json"
r=$(stop_reason 7 "$WT")
expect_in "apps/web/node_modules (apps/web/package-lock.json appeared)" "$r" "nested: a lockfile added in the worktree after provisioning blocks"

# new_dep_repo <name> <dir> <lockfile> -> prints main checkout path
new_dep_repo() {
  local main="$ROOT/$1"
  mkdir -p "$main/.claude" "$main/$2/dep"
  git init -q -b main "$main"
  git -C "$main" config user.email t@t
  git -C "$main" config user.name t
  printf '{"checks":[{"name":"ok","command":"true","required":true}]}\n' > "$main/.claude/verification.json"
  printf '%s\n' "$2" > "$main/.gitignore"
  printf 'v1\n' > "$main/$3"
  git -C "$main" add -A
  git -C "$main" commit -q -m init
  printf '%s\n' "$main"
}

# --- a container exec without runIn is unverifiable in a linked worktree (#220)
# A fake docker on PATH: a check that runs reports what it ran and passes.
BIN="$ROOT/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/docker"
cp "$BIN/docker" "$BIN/docker-compose"
chmod +x "$BIN/docker" "$BIN/docker-compose"
MAIN_X=$(new_dep_repo compose src/app app.lock)
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
r=$(compose_stop 116 "$MAIN_X" "docker compose exec svc make lint")
expect approve "${r%%$'\t'*}" "main checkout: docker compose exec without runIn runs as before"

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

# --- memory gate: stale-ref ID collisions warn, they do not block (#124) -----
# S001 is added on feat/a, merged, reverted on main and reused there; feat/c
# and feat/d both take P001 and never merge. Touching the memory tree must not
# block the stop on either; an error the session made still does.
MAIN_M=$(new_repo memory 0)
mkdir -p "$MAIN_M/.ai/memory/semantic"
printf '{"aiDir":".ai/"}\n' > "$MAIN_M/.myspec.json"
printf 'node_modules\n.claude/state/\n' > "$MAIN_M/.gitignore"
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
