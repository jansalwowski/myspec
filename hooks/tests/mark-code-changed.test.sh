#!/usr/bin/env bash
# Regression fixture for mark-code-changed.sh.
#
# Four things have to hold. The live log lands in .claude/state/sessions/ of
# the PRIMARY checkout — never in a linked worktree, never in the doc tree —
# and records every code path under `## Files touched`, exactly once, because
# that list is how a skill finds its own session. Bash writes create a log
# too, but only for what the command writes: a doc heredoc that merely mentions
# a code path, a grep over one, a script it runs, or a redirect to /dev/null
# must not (#145, #179). The ledger for the Stop hook records every written
# file under the root of the checkout holding it, so a write elsewhere never
# arms this checkout. And a repository without .myspec.json gets ledger lines
# (code did change) but no log.
#
# Usage: mark-code-changed.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mark-code-changed.sh}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/checkout"
mkdir -p "$REPO/src"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
printf '{"aiDir":".ai","frameworkVersion":"2.0.0"}\n' > "$REPO/.myspec.json"
STATE="$REPO/.claude/state/sessions"
SID="mct-$$"
trap 'rm -rf "$ROOT"; rm -f /tmp/.myspec-session-writes-'"$SID"'-*' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

write() {  # write <sid> <cwd> <file-path>
  printf '{"session_id":%s,"tool_name":"Write","cwd":%s,"tool_input":{"file_path":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$3" | jq -Rs .)" | bash "$HOOK" >/dev/null 2>&1
}

bashcmd() {  # bashcmd <sid> <cwd> <command>
  printf '{"session_id":%s,"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$3" | jq -Rs .)" | bash "$HOOK" >/dev/null 2>&1
}

expect_log() {  # expect_log <sid> <desc>
  if [ -f "$STATE/$1.md" ]; then ok; else fail "$2 (no log at .claude/state/sessions/$1.md)"; fi
}

expect_no_log() {
  if [ -f "$STATE/$1.md" ]; then fail "$2 (unexpected log at .claude/state/sessions/$1.md)"; else ok; fi
}

# ledger_has <sid> <kind> <root> <rel>: the Stop-hook ledger holds that line.
ledger_has() {
  grep -qxF -- "$(printf '%s\t%s\t%s' "$2" "$3" "$4")" "/tmp/.myspec-session-writes-$1" 2>/dev/null
}

# no_code_for <sid> <root>: nothing in the ledger arms <root>.
no_code_for() {
  ! grep -q -- "^code	$2	" "/tmp/.myspec-session-writes-$1" 2>/dev/null
}

expect_in() {  # expect_in <sid> <fixed-string> <desc>
  if grep -qF -- "$2" "$STATE/$1.md" 2>/dev/null; then ok; else fail "$3 (log lacks: $2)"; fi
}

# --- Write tool: log in the state dir, files touched, once each ---------------
write "$SID-1" "$REPO" "$REPO/src/a.ts"
expect_log "$SID-1" "first code edit creates the log"
expect_in "$SID-1" "session_id: $SID-1" "log carries the session id"
expect_in "$SID-1" '- `src/a.ts`' "first path recorded under Files touched"
expect_in "$SID-1" 'Auto-created on first code edit' "context names the trigger"
if grep -q '^cwd:' "$STATE/$SID-1.md"; then fail "no cwd: placeholder is written any more"; else ok; fi
ledger_has "$SID-1" code "$REPO" src/a.ts && ok || fail "the ledger records the code write under its checkout"
[ ! -e "$REPO/.ai/memory/sessions/active" ] && ok || fail "nothing is written under the doc tree"

write "$SID-1" "$REPO" "$REPO/src/b.ts"
write "$SID-1" "$REPO" "$REPO/src/a.ts"
expect_in "$SID-1" '- `src/b.ts`' "second path appended"
[ "$(grep -cF -- '- `src/a.ts`' "$STATE/$SID-1.md")" -eq 1 ] && ok || fail "a repeated path is recorded once"
[ "$(grep -c '^## Files touched' "$STATE/$SID-1.md")" -eq 1 ] && ok || fail "the Files touched heading is not duplicated"

# --- a doc edit is not a code edit --------------------------------------------
write "$SID-2" "$REPO" "$REPO/.ai/features/x/spec.md"
expect_no_log "$SID-2" "a doc edit creates no log"
ledger_has "$SID-2" file "$REPO" .ai/features/x/spec.md && ok || fail "a doc edit is recorded as a file write"
no_code_for "$SID-2" "$REPO" && ok || fail "a doc edit does not arm the gate"

# --- Bash writes ----------------------------------------------------------------
printf 'a\n' > "$REPO/src/c.ts"
bashcmd "$SID-3" "$REPO" "sed -i '' 's/a/b/' src/c.ts"
expect_log "$SID-3" "sed -i on a code file creates the log"
expect_in "$SID-3" 'Auto-created on a Bash write' "context names the Bash trigger"
expect_in "$SID-3" '- `src/c.ts`' "the sed target is recorded"

bashcmd "$SID-4" "$REPO" 'echo "x" >> src/d.ts'
expect_log "$SID-4" "a redirect into a code file creates the log"
expect_in "$SID-4" '- `src/d.ts`' "the redirect target is recorded"

bashcmd "$SID-5" "$REPO" $'cat > notes.md <<\'EOF\'\nsee src/a.ts for details\nEOF'
expect_no_log "$SID-5" "a doc heredoc that mentions a code path creates no log"

bashcmd "$SID-6" "$REPO" 'grep -rn foo src/a.ts'
expect_no_log "$SID-6" "a read-only command over a code file creates no log"

bashcmd "$SID-7" "$REPO" 'yarn test src/e.ts 2>&1'
expect_no_log "$SID-7" "2>&1 is not a write"

bashcmd "$SID-8" "$REPO" 'git apply fix.patch'
expect_no_log "$SID-8" "a write verb with no visible code path creates no log"

# --- #145/#179: reading, running or silencing is not writing -------------------
printf 'x\n' > "$REPO/src/router.js"
N=20
for c in 'cat src/router.js 2>/dev/null' \
         'grep -c x src/router.js 2>/dev/null' \
         'ls src/router.js 2>/dev/null' \
         'cat src/router.js > /dev/null' \
         'yarn lint src/router.js >&2' \
         "jq '{aiDir}' .myspec.json; node .claude/lib/memory-doctor.mjs --quiet 2>&1 | tail -2; ls .claude/state/sessions/ 2>/dev/null"; do
  N=$((N + 1))
  bashcmd "$SID-$N" "$REPO" "$c"
  expect_no_log "$SID-$N" "read-only command creates no log: $c"
  [ ! -s "/tmp/.myspec-session-writes-$SID-$N" ] && ok || fail "read-only command records nothing: $c"
done

# --- only the write target is recorded, not every code path in the command -----
bashcmd "$SID-30" "$REPO" 'node scripts/gen.mjs src/router.js > src/out.ts'
expect_in "$SID-30" '- `src/out.ts`' "the redirect target is recorded"
TOUCHED=$(sed -n '/^## Files touched/,$p' "$STATE/$SID-30.md")
if printf '%s' "$TOUCHED" | grep -qF -e 'scripts/gen.mjs' -e 'src/router.js'; then
  fail "a script run or an input read is not recorded as a write"
else ok; fi

printf 'x\n' > "$REPO/src/m1.ts"
bashcmd "$SID-31" "$REPO" 'mv src/m1.ts src/m2.ts && cp src/m2.ts src/m3.ts'
ledger_has "$SID-31" code "$REPO" src/m1.ts && ok || fail "a move records its source"
ledger_has "$SID-31" code "$REPO" src/m2.ts && ok || fail "a move records its destination"
ledger_has "$SID-31" code "$REPO" src/m3.ts && ok || fail "a copy records its destination"
[ "$(grep -c 'src/m2.ts' "/tmp/.myspec-session-writes-$SID-31")" -eq 1 ] && ok || fail "a copy does not record its source"

mkdir -p "$REPO/lib"
printf 'x\n' > "$REPO/src/m4.ts"
bashcmd "$SID-32" "$REPO" 'cp src/m4.ts lib/'
ledger_has "$SID-32" code "$REPO" lib/m4.ts && ok || fail "a copy into a directory records the file it lands as"

bashcmd "$SID-33" "$REPO/src" 'echo x > rel.ts'
ledger_has "$SID-33" code "$REPO" src/rel.ts && ok || fail "a relative target resolves against the payload cwd"

bashcmd "$SID-34" "$REPO" 'echo x | tee -a src/t1.ts src/t2.ts'
ledger_has "$SID-34" code "$REPO" src/t1.ts && ledger_has "$SID-34" code "$REPO" src/t2.ts && ok || fail "every tee operand is recorded"

# --- GraphQL is code (#152 §3) --------------------------------------------------
mkdir -p "$REPO/api"
bashcmd "$SID-35" "$REPO" 'echo "type Q { a: Int }" > api/schema.graphql'
ledger_has "$SID-35" code "$REPO" api/schema.graphql && ok || fail "a .graphql write is a code write"

# --- a write outside the checkout does not arm it (#145, #152 §3) --------------
mkdir -p "$ROOT/scratch"
bashcmd "$SID-36" "$REPO" "echo x > $ROOT/scratch/tmp.ts"
no_code_for "$SID-36" "$REPO" && ok || fail "a scratch write outside any checkout arms nothing"
expect_no_log "$SID-36" "a scratch write outside any checkout creates no log"

# --- a non-code write is recorded, once per verification cycle -----------------
write "$SID-37" "$REPO" "$REPO/package.json"
write "$SID-37" "$REPO" "$REPO/package.json"
[ "$(grep -c 'package.json' "/tmp/.myspec-session-writes-$SID-37")" -eq 1 ] && ok || fail "a repeated write is recorded once"
printf 'verified\t%s\t-\n' "$REPO" >> "/tmp/.myspec-session-writes-$SID-37"
write "$SID-37" "$REPO" "$REPO/package.json"
[ "$(grep -c 'package.json' "/tmp/.myspec-session-writes-$SID-37")" -eq 2 ] && ok || fail "a write after a verified run is recorded again"

# --- only what a segment WRITES is recorded (#201) ----------------------------
bashcmd "$SID-40" "$REPO" 'cat src/a.ts 2>/dev/null'
expect_no_log "$SID-40" "a read with stderr to /dev/null creates no log"
no_code_for "$SID-40" "$REPO" && ok || fail "a read with stderr to /dev/null arms nothing"

bashcmd "$SID-41" "$REPO" 'git log -- src/a.ts > /dev/null'
expect_no_log "$SID-41" "a redirect to /dev/null is not a write"

bashcmd "$SID-42" "$REPO" 'ls src/a.ts >/dev/null 2>&1'
expect_no_log "$SID-42" "an fd dup plus /dev/null is not a write"

bashcmd "$SID-43" "$REPO" 'grep -n foo src/a.ts > out.txt'
expect_no_log "$SID-43" "a redirect into a non-code file does not record the code file read"

bashcmd "$SID-44" "$REPO" 'cat src/a.ts > src/copy.ts'
expect_log "$SID-44" "a redirect into a code file still creates the log"
expect_in "$SID-44" '- `src/copy.ts`' "the redirect target is recorded"
if grep -qF -- '- `src/a.ts`' "$STATE/$SID-44.md" 2>/dev/null; then fail "the file only read is not recorded"; else ok; fi

mkdir -p "$REPO/src/lib"
bashcmd "$SID-45" "$REPO" 'cp src/a.ts src/lib/'
expect_in "$SID-45" '- `src/lib/a.ts`' "cp into a directory records the destination file"
if grep -qF -- '- `src/a.ts`' "$STATE/$SID-45.md" 2>/dev/null; then fail "cp does not record its source"; else ok; fi

printf 'a\n' > "$REPO/src/g.ts"
bashcmd "$SID-46" "$REPO" 'cd src && sed -i "" -e "s/a/b/" g.ts'
expect_in "$SID-46" '- `src/g.ts`' "a relative path after cd resolves against the new directory"

bashcmd "$SID-48" "$REPO" '(cd src && echo x > sub.ts); echo x > top.ts'
ledger_has "$SID-48" code "$REPO" src/sub.ts && ok || fail "a cd inside a subshell applies within it"
ledger_has "$SID-48" code "$REPO" top.ts && ok || fail "and ends with it"

# --- an edit inside a linked worktree logs in the PRIMARY checkout -----------
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/wt-a" -b wt-a
WT="$REPO/.claude/worktrees/wt-a"
mkdir -p "$WT/src"
write "$SID-9" "$WT" "$WT/src/w.ts"
expect_log "$SID-9" "worktree edit logs in the main checkout"
[ ! -e "$WT/.claude/state" ] && ok || fail "no state tree grows inside the worktree"
expect_in "$SID-9" 'worktree: "wt-a"' "worktree marker names the linked worktree"
expect_in "$SID-9" '- `.claude/worktrees/wt-a/src/w.ts`' "path is recorded relative to the main checkout"

bashcmd "$SID-47" "$WT" 'echo x > src/v.ts'
expect_in "$SID-47" '- `.claude/worktrees/wt-a/src/v.ts`' "a relative Bash write in a worktree records the worktree file"
expect_in "$SID-47" 'worktree: "wt-a"' "and marks the worktree"
ledger_has "$SID-47" code "$WT" src/v.ts && ok || fail "the ledger keys a worktree write by the worktree's root"

# --- a 1.x log without the section gains it on the next edit ----------------
mkdir -p "$STATE"
printf -- '---\nsession_id: %s-10\nstatus: active\n---\n\n# old\n\n## Outcome\n' "$SID" > "$STATE/$SID-10.md"
write "$SID-10" "$REPO" "$REPO/src/f.ts"
expect_in "$SID-10" '## Files touched' "an older log gains the section"
expect_in "$SID-10" '- `src/f.ts`' "and the path"

# --- not a myspec project: marker, but no log -----------------------------------
OTHER="$ROOT/other"
mkdir -p "$OTHER/src"
git init -q -b main "$OTHER"
write "$SID-11" "$OTHER" "$OTHER/src/x.ts"
ledger_has "$SID-11" code "$OTHER" src/x.ts && ok || fail "the ledger still records a write outside a myspec project"
[ ! -e "$OTHER/.claude/state" ] && ok || fail "no log outside a myspec project"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
