#!/usr/bin/env bash
# Regression fixture for verify-before-stop.sh: linked dependency directories
# (R8, issues #94, #229, #239), container execs in a linked worktree (R8a) and
# the memory gate.
#
# worktree-provision.sh records each link it makes, with the hash of every
# lockfile that pinned it, in .claude/state/provision.json. A link it made
# must pass with default config; a recorded lockfile that changed since, on
# either side, or a recorded link that moved, must block until provision runs
# again. A worktree without a record, and a main checkout, are not compared.
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
expect approve "$(stop 3 "$WT")" "the restored lockfile matches the record again"
printf '{"lockfileVersion":3,"y":1}\n' > "$MAIN/package-lock.json"
expect block "$(stop 4 "$WT")" "a lockfile changed in the main checkout blocks"

# --- re-running provision clears the block --------------------------------------
# The worktree's lockfile now differs from the main checkout's, so provision
# drops the link (and says to install); nothing on record is stale.
bash "$PROVISION" "$WT" --base main >/dev/null
[ ! -e "$WT/node_modules" ] && ok || fail "provision rerun drops a link whose lockfile now differs"
expect approve "$(stop 5 "$WT")" "after provision reruns, the record matches and the checks run"
git -C "$MAIN" checkout -q -- package-lock.json

# --- a recorded link that moved blocks ------------------------------------------
bash "$PROVISION" "$WT" --base main >/dev/null
[ -L "$WT/node_modules" ] && ok || fail "provision links node_modules again once the lockfiles match"
mkdir -p "$ROOT/elsewhere/node_modules"
rm "$WT/node_modules"
ln -s "$ROOT/elsewhere/node_modules" "$WT/node_modules"
r=$(stop_reason 6 "$WT")
expect_in "node_modules (the link no longer points into $MAIN)" "$r" "a recorded link that points elsewhere blocks"
rm "$WT/node_modules"
ln -s "$ROOT/gone/node_modules" "$WT/node_modules"
expect block "$(stop 7 "$WT")" "a recorded link that dangles blocks"

# --- a real install where the link was is not compared ---------------------------
rm "$WT/node_modules"
mkdir "$WT/node_modules"
printf '{"lockfileVersion":3,"z":1}\n' > "$WT/package-lock.json"
expect approve "$(stop 8 "$WT")" "a real directory at a recorded path is not compared"

# --- no record: the checks run without the comparison -----------------------------
# A hand-made link is doctor's finding (link-unrecorded), not the gate's.
MAIN_H=$(new_repo hand 1)
WT_H="$ROOT/hand-wt"
git -C "$MAIN_H" worktree add -q -b feat "$WT_H" main
ln -s "$MAIN_H/node_modules" "$WT_H/node_modules"
printf '{"lockfileVersion":3,"x":1}\n' > "$WT_H/package-lock.json"
expect approve "$(stop 9 "$WT_H")" "a worktree without a provision record is not compared"

# --- the main checkout never compares ---------------------------------------------
# Its node_modules links into a worktree whose lockfile differs (which the
# old scan blocked on), and it holds a record whose every entry is stale.
WT_H2="$ROOT/hand-wt2"
git -C "$MAIN_H" worktree add -q -b feat2 "$WT_H2" main
mkdir -p "$WT_H2/node_modules/dep"
printf '{"lockfileVersion":3,"w":1}\n' > "$WT_H2/package-lock.json"
rm -rf "$MAIN_H/node_modules"
ln -s "$WT_H2/node_modules" "$MAIN_H/node_modules"
mkdir -p "$MAIN_H/.claude/state"
jq -n --arg s "$WT_H2" '{source: $s, links: [{path: "node_modules", target: "/nowhere", lockfiles: {"package-lock.json": "0"}}]}' \
  > "$MAIN_H/.claude/state/provision.json"
expect approve "$(stop 10 "$MAIN_H")" "the main checkout is never compared, record or not"

# --- an unreadable record blocks ------------------------------------------------
printf '{"source":' > "$WT/.claude/state/provision.json"
r=$(stop_reason 11 "$WT")
expect_in "cannot be read" "$r" "a provision record that is not JSON blocks and says so"

# --- a nested lockfile the branch adds after provisioning blocks (#256 review) ---
# apps/web/node_modules is pinned by apps/web/package-lock.json or the root
# one; only the root one exists when provision links it.
MAIN_N=$(new_repo nested 1)
mkdir -p "$MAIN_N/apps/web/node_modules/dep"
printf '{"isolation":{"provision":{"symlink":["apps/web/node_modules"]}}}\n' > "$MAIN_N/.myspec.json"
printf 'apps/web/node_modules\n' >> "$MAIN_N/.gitignore"
git -C "$MAIN_N" add -A && git -C "$MAIN_N" commit -q -m nested
WT_N="$ROOT/nested-wt"
git -C "$MAIN_N" worktree add -q -b feat-nested "$WT_N" main
bash "$PROVISION" "$WT_N" --base main >/dev/null
[ -L "$WT_N/apps/web/node_modules" ] && ok || fail "nested: provision links apps/web/node_modules"
expect approve "$(stop 14 "$WT_N")" "nested: the record matches"
printf '{"lockfileVersion":3}\n' > "$WT_N/apps/web/package-lock.json"
r=$(stop_reason 15 "$WT_N")
expect_in "apps/web/node_modules (apps/web/package-lock.json appeared)" "$r" "nested: a lockfile added in the worktree after provisioning blocks"
rm "$WT_N/apps/web/package-lock.json"
printf '{"lockfileVersion":3}\n' > "$MAIN_N/apps/web/package-lock.json"
r=$(stop_reason 16 "$WT_N")
expect_in "apps/web/node_modules (apps/web/package-lock.json appeared)" "$r" "nested: a lockfile added in the main checkout after provisioning blocks"
rm "$MAIN_N/apps/web/package-lock.json"
expect approve "$(stop 17 "$WT_N")" "nested: the record matches again once the lockfile is gone on both sides"
# A recorded glob pattern: a new match blocks, a match the record hashes does not.
jq '.links[0].lockfiles += {"req*.txt": null, "pack*.json": null}' "$WT_N/.claude/state/provision.json" > "$ROOT/prov.json" \
  && mv "$ROOT/prov.json" "$WT_N/.claude/state/provision.json"
expect approve "$(stop 18 "$WT_N")" "nested: a glob whose only match the record hashes is not new"
printf 'x\n' > "$WT_N/req-dev.txt"
r=$(stop_reason 19 "$WT_N")
expect_in "apps/web/node_modules (req-dev.txt appeared)" "$r" "nested: a new match of a recorded glob pattern blocks"
rm "$WT_N/req-dev.txt"
# A recorded lockfile that is gone on either side blocks as removed.
mv "$WT_N/package-lock.json" "$ROOT/pl.bak"
r=$(stop_reason 20 "$WT_N")
expect_in "apps/web/node_modules (package-lock.json removed)" "$r" "nested: a recorded lockfile that disappears blocks"
mv "$ROOT/pl.bak" "$WT_N/package-lock.json"

# --- the comparison is the same for any stack: a vendor pinned by composer.lock ----
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

MAIN_P=$(new_dep_repo php vendor composer.lock '{"isolation":{"provision":{"symlink":["vendor"]}}}')
WT_P="$ROOT/php-wt"
git -C "$MAIN_P" worktree add -q -b feat "$WT_P" main
bash "$PROVISION" "$WT_P" --base main >/dev/null
expect approve "$(stop 12 "$WT_P")" "php: a provisioned vendor with an unchanged composer.lock is accepted"
printf 'v2\n' > "$WT_P/composer.lock"
git -C "$WT_P" commit -q -am "bump lock"
expect block "$(stop 13 "$WT_P")" "php: a committed composer.lock change under a recorded vendor link blocks"

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
