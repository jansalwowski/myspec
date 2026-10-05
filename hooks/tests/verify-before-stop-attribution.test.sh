#!/usr/bin/env bash
# Fixture for the stop gate's session scope (docs/stop-gate.md, R1, R2, R4).
#
# Arming goes through the real mark-code-changed.sh, so the session-state
# contract between the two hooks (lib/session-event.sh) is under test, not a
# hand-written file. The gate must
# run only after this session wrote code in this checkout (#145), and it must
# not block a session on failures that name only files another session left
# uncommitted in a shared checkout (#198). When it can't tell, it still blocks,
# and says which changes are not the session's. How a path in the output is
# matched, and that a timeout is never downgraded, are function tests in
# lib/tests/stop-gate-attribute.test.sh.
#
# Usage: verify-before-stop-attribution.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${1:-$HERE/../verify-before-stop.sh}"
MARK="$HERE/../mark-code-changed.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
SID="vbs-attr-$$"
RAN="$ROOT/ran"
trap 'rm -rf "$ROOT"; rm -f /tmp/.myspec-session-writes-'"$SID"'-*' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

mkdir -p "$REPO/.claude"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf '{"aiDir":".ai"}\n' > "$REPO/.myspec.json"
printf '.claude/state/\n' > "$REPO/.gitignore"
printf 'export const a = 1;\n' > "$REPO/app.ts"
printf 'export const b = 2;\n' > "$REPO/other.ts"
printf '{}\n' > "$REPO/tsconfig.json"
printf '{"checks":[]}\n' > "$REPO/.claude/verification.json"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

# set_checks <command>...: one required check per command, each touching $RAN
# first so a run is visible. Committed, so it is not an uncommitted change.
set_checks() {
  local json='[]' i=0 c
  for c in "$@"; do
    i=$((i + 1))
    json=$(printf '%s' "$json" | jq --arg n "check$i" --arg c "touch $RAN; $c" '. + [{name: $n, command: $c, required: true}]')
  done
  printf '{"checks":%s}\n' "$json" > "$REPO/.claude/verification.json"
  git -C "$REPO" add .claude/verification.json
  git -C "$REPO" commit -q -m checks >/dev/null || true
}

reset_tree() {
  git -C "$REPO" checkout -q -- .
  git -C "$REPO" clean -qfd
}

mark_write() {  # mark_write <sid> <file>: the Write tool wrote <file>
  jq -n --arg s "$SID-$1" --arg d "$REPO" --arg f "$2" '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}}' \
    | bash "$MARK" >/dev/null 2>&1
}

mark_bash() {  # mark_bash <sid> <command>
  jq -n --arg s "$SID-$1" --arg d "$REPO" --arg c "$2" '{session_id: $s, tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' \
    | bash "$MARK" >/dev/null 2>&1
}

stop() {  # stop <sid> -> hook stdout
  rm -f "$RAN"
  jq -n --arg s "$SID-$1" --arg d "$REPO" '{session_id: $s, cwd: $d}' | bash "$HOOK" 2>/dev/null
}

decision() { printf '%s' "$1" | jq -r '.decision // "none"' 2>/dev/null || printf 'not-json'; }
text()     { printf '%s' "$1" | jq -r '(.reason // "") + (.systemMessage // "")' 2>/dev/null; }

expect_decision() {  # expect_decision <want> <out> <desc>
  local got
  got=$(decision "$2")
  if [ "$got" = "$1" ]; then ok; else fail "$3 (want $1, got $got: $(text "$2" | head -3))"; fi
}

expect_text() {  # expect_text <out> <fixed string> <desc>
  if text "$1" | grep -qF -- "$2"; then ok; else fail "$3 (text lacks: $2)"; fi
}

expect_no_text() {
  if text "$1" | grep -qF -- "$2"; then fail "$3 (text has: $2)"; else ok; fi
}

ran()     { [ -e "$RAN" ]; }

# A linter-like check: names every file holding BROKEN, fails if any does.
LINT='! grep -H BROKEN app.ts other.ts tsconfig.json'

# --- arming (R1, R2) -------------------------------------------------------------
set_checks "$LINT"
printf 'BROKEN\n' >> "$REPO/other.ts"

OUT=$(stop 1)
expect_decision approve "$OUT" "no write, no ledger: approved"
ran && fail "no write runs no check" || ok

mark_bash 2 'cat app.ts 2>/dev/null; grep -c x other.ts > /dev/null'
OUT=$(stop 2)
expect_decision approve "$OUT" "#145: a read-only Bash command does not arm the gate"
ran && fail "#145: a read-only Bash command runs no check" || ok

mark_write 3 "$REPO/notes.md"
OUT=$(stop 3)
expect_decision approve "$OUT" "a doc-only write does not arm the gate"
ran && fail "a doc-only write runs no check" || ok

ELSEWHERE="$ROOT/elsewhere"
git init -q -b main "$ELSEWHERE"
mark_write 4 "$ELSEWHERE/x.ts"
OUT=$(stop 4)
expect_decision approve "$OUT" "#145: a code write in another repository does not arm this one"
ran && fail "#145: a write elsewhere runs no check here" || ok
reset_tree

# --- #198: another session's uncommitted breakage ---------------------------------
printf 'BROKEN\n' >> "$REPO/other.ts"
printf 'export const a = 3;\n' > "$REPO/app.ts"
mark_write 10 "$REPO/app.ts"
OUT=$(stop 10)
expect_decision approve "$OUT" "#198: failures naming only another session's file do not block"
ran && ok || fail "#198: the checks still run"
expect_text "$OUT" 'names only files changed outside this session: other.ts' "#198: the warning names the foreign file"
expect_text "$OUT" 'worktree per session' "#198: the warning points at isolation"
OUT=$(stop 10)
ran && fail "a warned run counts as verified: no re-run without a new write" || ok

# A silent failure can't be attributed: block, but say whose changes are whose.
set_checks '! grep -q BROKEN other.ts'
mark_write 13 "$REPO/app.ts"
OUT=$(stop 13)
expect_decision block "$OUT" "#198: a failure that names no file still blocks"
expect_text "$OUT" 'uncommitted changes this session did not write (other.ts)' "the block lists the changes that are not the session's"
expect_text "$OUT" 'names none of the changed files' "the block says the failure names none of them"
expect_text "$OUT" 'Do not edit files changed outside this session' "the block tells the agent to leave them alone"
expect_no_text "$OUT" 'Fix failures before completing' "the block no longer orders every failure fixed"

# The session's own failure blocks even with foreign changes around.
set_checks "$LINT"
printf 'BROKEN\n' >> "$REPO/app.ts"
mark_write 14 "$REPO/app.ts"
OUT=$(stop 14)
expect_decision block "$OUT" "a failure naming the session's file blocks"
expect_text "$OUT" 'names files this session wrote: app.ts' "the block says which failure is the session's"
reset_tree

# A check run from a cwd prints its paths relative to it (src/Foo.php for
# api/src/Foo.php), and full-mode attribution must still find the foreign
# file by that path (#255 review): a failure naming only another session's
# file warns, as it does from the root.
mkdir -p "$REPO/api/src"
printf '<?php\n' > "$REPO/api/src/Foo.php"
git -C "$REPO" add api && git -C "$REPO" commit -q -m api
jq -n --arg c "touch $RAN; ! grep -H BROKEN src/Foo.php" '{checks: [{name: "phpcs", command: $c, required: true, cwd: "api"}]}' > "$REPO/.claude/verification.json"
git -C "$REPO" add .claude/verification.json && git -C "$REPO" commit -q -m checks
printf 'BROKEN\n' >> "$REPO/api/src/Foo.php"
printf 'export const a = 4;\n' > "$REPO/app.ts"
mark_write 16 "$REPO/app.ts"
OUT=$(stop 16)
expect_decision approve "$OUT" "cwd: a failure naming another session's file relative to the cwd warns"
expect_text "$OUT" 'names only files changed outside this session: api/src/Foo.php' "cwd: the warning names the foreign file repo-relative"
# A path that only resolves at the root still does, and the session's own
# file, named relative to the cwd, still blocks.
printf 'BROKEN\n' >> "$REPO/api/src/Foo.php"
mark_write 17 "$REPO/api/src/Foo.php"
OUT=$(stop 17)
expect_decision block "$OUT" "cwd: a failure naming the session's own file relative to the cwd blocks"
expect_text "$OUT" 'names files this session wrote: api/src/Foo.php' "cwd: the block says which failure is the session's"
reset_tree

# --- single session: nothing uncommitted is anyone else's --------------------------
set_checks "$LINT"
printf 'BROKEN\n' >> "$REPO/app.ts"
mark_write 20 "$REPO/app.ts"
OUT=$(stop 20)
expect_decision block "$OUT" "a single session's failure blocks"
expect_no_text "$OUT" 'did not write' "no attribution paragraph when every change is the session's"
reset_tree

# A config file the session edited is its own, so a failure naming it blocks.
printf 'BROKEN\n' >> "$REPO/tsconfig.json"
mark_write 21 "$REPO/tsconfig.json"
printf 'export const a = 4;\n' > "$REPO/app.ts"
mark_write 21 "$REPO/app.ts"
OUT=$(stop 21)
expect_decision block "$OUT" "a failure naming a non-code file the session wrote blocks"
reset_tree

# --- the ledger outlives a run ----------------------------------------------------
set_checks "$LINT"
printf 'export const a = 5;\n' > "$REPO/app.ts"
mark_write 30 "$REPO/app.ts"
OUT=$(stop 30)
expect_decision approve "$OUT" "a clean run approves"
printf 'export const x = 1;\n' > "$REPO/new.ts"
printf 'BROKEN\n' >> "$REPO/app.ts"
mark_write 30 "$REPO/new.ts"
OUT=$(stop 30)
expect_decision block "$OUT" "a file written before the last run still counts as the session's"
expect_no_text "$OUT" 'did not write' "an earlier write is not reported as someone else's change"
reset_tree

# --- cwd = main checkout, edits in a linked worktree (#201) ------------------------
set_checks "$LINT"
WT="$ROOT/wt"
git -C "$REPO" worktree add -q -b wt "$WT"
printf 'BROKEN\n' >> "$WT/app.ts"
mark_write 35 "$WT/app.ts"
OUT=$(stop 35)
expect_decision block "$OUT" "a session that broke a worktree from a main-checkout cwd is blocked"
expect_text "$OUT" "[in $WT]" "the report names the worktree the check ran in"
git -C "$REPO" worktree remove --force "$WT"

# --- PR #203 review: many matches do not kill the hook (SIGPIPE) ------------------
# ~50 KB of matched paths: `head` in the pipeline used to exit early, and under
# pipefail the hook died with 141 and printed no decision.
mkdir -p "$REPO/gen"
for i in $(seq 1 1000); do printf 'BROKEN\n' > "$REPO/gen/generated-component-with-a-long-name-$i.ts"; done
set_checks '! grep -l BROKEN gen/*.ts'
mark_write 36 "$REPO/app.ts"
OUT=$(stop 36); RC=$?
[ "$RC" -eq 0 ] && ok || fail "the hook exits 0 when a failure names 1000 changed paths (exit $RC)"
expect_decision approve "$OUT" "1000 foreign paths named: still a decision, and a warning"
expect_text "$OUT" 'and 990 more' "the foreign list is cut to ten"
reset_tree

# --- the session's files reach the checks -----------------------------------------
set_checks "printf '%s\n' \"\$MYSPEC_SESSION_FILES\" > $ROOT/session-files"
printf 'export const a = 6;\n' > "$REPO/app.ts"
mark_write 37 "$REPO/app.ts"
mark_write 37 "$REPO/tsconfig.json"
OUT=$(stop 37)
[ "$(cat "$ROOT/session-files")" = "$(printf 'app.ts\ntsconfig.json')" ] && ok || fail "MYSPEC_SESSION_FILES lists the files this session wrote (got: $(tr '\n' ' ' < "$ROOT/session-files"))"
reset_tree

# --- #225: a subagent's write arms the parent's gate -------------------------------
# Subagents share the parent's session_id; their events add agent_id, which the
# ledger records as a fourth field. The Stop hook (main session, no agent_id)
# must still verify the checkout and count the file as the session's.
mark_agent() {  # mark_agent <sid> <file> <agent_id>
  jq -n --arg s "$SID-$1" --arg d "$REPO" --arg f "$2" --arg a "$3" \
    '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}, agent_id: $a, agent_type: "general-purpose"}' \
    | bash "$MARK" >/dev/null 2>&1
}
set_checks "printf '%s\n' \"\$MYSPEC_SESSION_FILES\" > $ROOT/session-files; $LINT"
printf 'BROKEN\n' >> "$REPO/app.ts"
mark_agent 50 "$REPO/app.ts" a6baef07
OUT=$(stop 50)
ran && ok || fail "#225: a subagent's code write arms the parent's Stop gate"
expect_decision block "$OUT" "#225: a failure naming the subagent's file blocks the parent"
expect_no_text "$OUT" 'did not write' "#225: the subagent's file counts as this session's"
[ "$(cat "$ROOT/session-files")" = "app.ts" ] && ok || fail "#225: MYSPEC_SESSION_FILES lists the subagent's file by path alone (got: $(tr '\n' ' ' < "$ROOT/session-files"))"
OUT=$(stop 50)
ran && fail "#225: the subagent's write counts as verified after the run" || ok
reset_tree

# --- #231: an ignorePaths write never arms the gate --------------------------------
set_checks "$LINT"
printf '{"aiDir":".ai","hooks":{"markCodeChanged":{"ignorePaths":["gen/**"]}}}\n' > "$REPO/.myspec.json"
git -C "$REPO" commit -q -am ignore-gen
mkdir -p "$REPO/gen"
printf 'BROKEN\n' > "$REPO/gen/out.ts"
printf 'BROKEN\n' >> "$REPO/app.ts"
mark_write 51 "$REPO/gen/out.ts"
OUT=$(stop 51)
expect_decision approve "$OUT" "#231: a code write under ignorePaths alone does not arm the gate"
ran && fail "#231: an ignored write runs no check" || ok
printf '{"aiDir":".ai"}\n' > "$REPO/.myspec.json"
git -C "$REPO" commit -q -am unignore
reset_tree

# --- PR #203 review: an edit inside a submodule verifies the superproject ----------
MOD="$ROOT/modsrc"
git init -q -b main "$MOD"
git -C "$MOD" config user.email t@t
git -C "$MOD" config user.name t
printf 'ok\n' > "$MOD/m.ts"
git -C "$MOD" add -A
git -C "$MOD" commit -q -m init
git -C "$REPO" -c protocol.file.allow=always submodule add -q "$MOD" mod >/dev/null 2>&1
git -C "$REPO" commit -q -m submodule
set_checks '! grep -H BROKEN mod/m.ts'
printf 'BROKEN\n' >> "$REPO/mod/m.ts"
mark_write 38 "$REPO/mod/m.ts"
OUT=$(stop 38)
expect_decision block "$OUT" "a broken submodule file blocks through the superproject's checks"
OUT=$(stop 38)
ran && fail "the submodule write counts as verified after the run" || ok
git -C "$REPO/mod" checkout -q -- m.ts

# --- the /tmp ledger of the previous release is imported once ----------------------
# One minor release of migration (docs/stop-gate.md "Session writes"). The
# path is the old hook's, so this case writes to /tmp itself; the trap cleans up.
set_checks "$LINT"
printf 'BROKEN\n' >> "$REPO/app.ts"
printf 'code\t%s\tapp.ts\n' "$REPO" > "/tmp/.myspec-session-writes-$SID-41"
OUT=$(stop 41)
expect_decision block "$OUT" "a session armed by the old /tmp ledger is still verified after the upgrade"
expect_no_text "$OUT" 'did not write' "the imported writes count as the session's"
[ -f "/tmp/.myspec-session-writes-$SID-41.imported" ] && [ ! -e "/tmp/.myspec-session-writes-$SID-41" ] \
  && ok || fail "the old ledger is renamed .imported"
OUT=$(stop 41)
ran && fail "the imported session is verified, and not re-imported" || ok
reset_tree

# --- TMPDIR does not move the state ---------------------------------------------------
set_checks "$LINT"
printf 'BROKEN\n' >> "$REPO/app.ts"
mkdir -p "$ROOT/tmpdir-a" "$ROOT/tmpdir-b"
jq -n --arg s "$SID-42" --arg d "$REPO" --arg f "$REPO/app.ts" '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}}' \
  | TMPDIR="$ROOT/tmpdir-a" bash "$MARK" >/dev/null 2>&1
rm -f "$RAN"
OUT=$(jq -n --arg s "$SID-42" --arg d "$REPO" '{session_id: $s, cwd: $d}' | TMPDIR="$ROOT/tmpdir-b" bash "$HOOK" 2>/dev/null)
expect_decision block "$OUT" "a write under one TMPDIR arms a stop under another"
[ -f "$REPO/.claude/state/sessions/$SID-42.jsonl" ] && ok || fail "the state file is in the main checkout"
reset_tree

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
