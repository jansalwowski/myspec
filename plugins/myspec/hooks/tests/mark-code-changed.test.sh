#!/usr/bin/env bash
# Regression fixture for mark-code-changed.sh.
#
# Four things have to hold. The live log lands in .claude/state/sessions/ of
# the PRIMARY checkout — never in a linked worktree, never in the doc tree —
# and records every code path under `## Files touched`, exactly once, because
# that list is how a skill finds its own session. Bash writes create a log
# too, but only for what the command writes: a doc heredoc that merely mentions
# a code path, a grep over one, a script it runs, or a redirect to /dev/null
# must not (#145, #179). The ledger for the Stop hook (write events in the
# session-state file, lib/session-event.sh) records every written file under
# the root of the checkout holding it, so a write elsewhere never arms this
# checkout. A repository with neither .myspec.json nor a stop gate gets
# neither ledger nor log. A Bash command running `session-event.sh implement
# start|stop`, directly or through bash, sh, env or command, records the implement event with the payload's session id.
#
# Usage: mark-code-changed.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mark-code-changed.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"
SESSION_EVENT="$(cd "$(dirname "$HOOK")" && pwd)/../lib/session-event.sh"

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
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# ledger <sid>: the session's write events as `<kind>\t<root>\t<rel>[\t<agent>]`,
# from every session-state file under $ROOT: each lives in the main checkout
# of the repository written to.
ledger() {
  find "$ROOT" -path "*/.claude/state/sessions/$1.jsonl" -exec cat {} + 2>/dev/null \
    | jq -r 'select(.t == "write") | [.kind, .root, .rel] + (if .agent then [.agent] else [] end) | join("\t")' 2>/dev/null
}

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
  grep -qxF -- "$(printf '%s\t%s\t%s' "$2" "$3" "$4")" <(ledger "$1") 2>/dev/null
}

# no_code_for <sid> <root>: nothing in the ledger arms <root>.
no_code_for() {
  ! grep -q -- "^code	$2	" <(ledger "$1") 2>/dev/null
}

expect_in() {  # expect_in <sid> <fixed-string> <desc>
  if grep -qF -- "$2" "$STATE/$1.md" 2>/dev/null; then ok; else fail "$3 (log lacks: $2)"; fi
}

# --- Write tool: log in the state dir, files touched, once each ---------------
write "$SID-1" "$REPO" "$REPO/src/a.ts"
expect_log "$SID-1" "first code edit creates the log"
expect_in "$SID-1" "session_id: $SID-1" "log carries the session id"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-1" '- `src/a.ts`' "first path recorded under Files touched"
expect_in "$SID-1" 'Auto-created on first code edit' "context names the trigger"
if grep -q '^cwd:' "$STATE/$SID-1.md"; then fail "no cwd: placeholder is written any more"; else ok; fi
ledger_has "$SID-1" code "$REPO" src/a.ts && ok || fail "the ledger records the code write under its checkout"
[ ! -e "$REPO/.ai/memory/sessions/active" ] && ok || fail "nothing is written under the doc tree"

write "$SID-1" "$REPO" "$REPO/src/b.ts"
write "$SID-1" "$REPO" "$REPO/src/a.ts"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-1" '- `src/b.ts`' "second path appended"
# shellcheck disable=SC2016 # literal text, not an expansion
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
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-3" '- `src/c.ts`' "the sed target is recorded"

bashcmd "$SID-4" "$REPO" 'echo "x" >> src/d.ts'
expect_log "$SID-4" "a redirect into a code file creates the log"
# shellcheck disable=SC2016 # literal text, not an expansion
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
  [ -z "$(ledger "$SID-$N")" ] && ok || fail "read-only command records nothing: $c"
done

# --- only the write target is recorded, not every code path in the command -----
bashcmd "$SID-30" "$REPO" 'node scripts/gen.mjs src/router.js > src/out.ts'
# shellcheck disable=SC2016 # literal text, not an expansion
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
[ "$(grep -c 'src/m2.ts' <(ledger "$SID-31"))" -eq 1 ] && ok || fail "a copy does not record its source"

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
[ "$(grep -c 'package.json' <(ledger "$SID-37"))" -eq 1 ] && ok || fail "a repeated write is recorded once"
bash "$SESSION_EVENT" --root "$REPO" append "$SID-37" "$(jq -nc --arg r "$REPO" '{t: "verified", root: $r}')"
write "$SID-37" "$REPO" "$REPO/package.json"
[ "$(grep -c 'package.json' <(ledger "$SID-37"))" -eq 2 ] && ok || fail "a write after a verified run is recorded again"

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
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-44" '- `src/copy.ts`' "the redirect target is recorded"
# shellcheck disable=SC2016 # literal text, not an expansion
if grep -qF -- '- `src/a.ts`' "$STATE/$SID-44.md" 2>/dev/null; then fail "the file only read is not recorded"; else ok; fi

mkdir -p "$REPO/src/lib"
bashcmd "$SID-45" "$REPO" 'cp src/a.ts src/lib/'
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-45" '- `src/lib/a.ts`' "cp into a directory records the destination file"
# shellcheck disable=SC2016 # literal text, not an expansion
if grep -qF -- '- `src/a.ts`' "$STATE/$SID-45.md" 2>/dev/null; then fail "cp does not record its source"; else ok; fi

printf 'a\n' > "$REPO/src/g.ts"
bashcmd "$SID-46" "$REPO" 'cd src && sed -i "" -e "s/a/b/" g.ts'
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-46" '- `src/g.ts`' "a relative path after cd resolves against the new directory"

bashcmd "$SID-48" "$REPO" '(cd src && echo x > sub.ts); echo x > top.ts'
ledger_has "$SID-48" code "$REPO" src/sub.ts && ok || fail "a cd inside a subshell applies within it"
ledger_has "$SID-48" code "$REPO" top.ts && ok || fail "and ends with it"

# --- PR #203 review: sed/perl forms, patch options, quoted targets -------------
for f in r1 r2 r3 r4 r6 r10; do printf 'a\n' > "$REPO/src/$f.ts"; done
printf 'x\n' > "$REPO/fix.diff"
bashcmd "$SID-50" "$REPO" "/usr/bin/sed -i '' 's/a/b/' src/r1.ts"
ledger_has "$SID-50" code "$REPO" src/r1.ts && ok || fail "sed by its full path still arms"
bashcmd "$SID-51" "$REPO" "sed -e 's/a/b/' -i '' src/r2.ts"
ledger_has "$SID-51" code "$REPO" src/r2.ts && ok || fail "sed with -i after another option still arms"
bashcmd "$SID-52" "$REPO" "sed --silent -n 's/a/b/p' src/r2.ts"
[ -z "$(ledger "$SID-52")" ] && ok || fail "sed without -i records nothing"
bashcmd "$SID-53" "$REPO" "perl -pi -e 's/a/b/' src/r3.ts"
ledger_has "$SID-53" code "$REPO" src/r3.ts && ok || fail "perl -pi arms"
bashcmd "$SID-54" "$REPO" "perl -Mstrict -e 'print 1' src/r3.ts"
[ -z "$(ledger "$SID-54")" ] && ok || fail "a perl -M module name is not -i"
bashcmd "$SID-55" "$REPO" 'patch -i fix.diff src/r4.ts'
ledger_has "$SID-55" code "$REPO" src/r4.ts && ok || fail "patch -i records the file it edits"
grep -q 'fix.diff' <(ledger "$SID-55") && fail "patch -i does not record the diff it reads" || ok
bashcmd "$SID-56" "$REPO" 'patch -o src/r5.ts src/r4.ts fix.diff'
ledger_has "$SID-56" code "$REPO" src/r5.ts && ok || fail "patch -o records the file it writes"
bashcmd "$SID-57" "$REPO" "sed -i '' 's/a/b/' \"src/r6.ts\""
ledger_has "$SID-57" code "$REPO" src/r6.ts && ok || fail "a quoted sed target is recorded"
bashcmd "$SID-58" "$REPO" 'echo x > "src/r7 spaced.ts"'
ledger_has "$SID-58" code "$REPO" 'src/r7 spaced.ts' && ok || fail "a quoted redirect target with a space is recorded"
bashcmd "$SID-59" "$REPO" 'cd "src" && echo x > r8.ts'
ledger_has "$SID-59" code "$REPO" src/r8.ts && ok || fail "a quoted cd target moves the base directory"
bashcmd "$SID-60" "$REPO" 'echo "a > b.ts" > src/r9.ts'
ledger_has "$SID-60" code "$REPO" src/r9.ts && ok || fail "the real redirect target is recorded"
[ "$(ledger "$SID-60" | wc -l)" -eq 1 ] && ok || fail "a > inside quotes is not a redirect"
# shellcheck disable=SC2016 # literal text, not an expansion
bashcmd "$SID-61" "$REPO" 'sed -i "" "s/a/b/" "$F" src/r10.ts'
ledger_has "$SID-61" code "$REPO" src/r10.ts && ok || fail "a variable operand does not hide the literal one after it"

# --- an edit inside a linked worktree logs in the PRIMARY checkout -----------
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/wt-a" -b wt-a
WT="$REPO/.claude/worktrees/wt-a"
mkdir -p "$WT/src"
write "$SID-9" "$WT" "$WT/src/w.ts"
expect_log "$SID-9" "worktree edit logs in the main checkout"
[ ! -e "$WT/.claude/state" ] && ok || fail "no state tree grows inside the worktree"
expect_in "$SID-9" 'worktree: "wt-a"' "worktree marker names the linked worktree"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-9" '- `.claude/worktrees/wt-a/src/w.ts`' "path is recorded relative to the main checkout"

bashcmd "$SID-47" "$WT" 'echo x > src/v.ts'
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-47" '- `.claude/worktrees/wt-a/src/v.ts`' "a relative Bash write in a worktree records the worktree file"
expect_in "$SID-47" 'worktree: "wt-a"' "and marks the worktree"
ledger_has "$SID-47" code "$WT" src/v.ts && ok || fail "the ledger keys a worktree write by the worktree's root"

# --- a 1.x log without the section gains it on the next edit ----------------
mkdir -p "$STATE"
printf -- '---\nsession_id: %s-10\nstatus: active\n---\n\n# old\n\n## Outcome\n' "$SID" > "$STATE/$SID-10.md"
write "$SID-10" "$REPO" "$REPO/src/f.ts"
expect_in "$SID-10" '## Files touched' "an older log gains the section"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-10" '- `src/f.ts`' "and the path"

# --- settings: extraCodeExtensions and ignorePaths (#231) ----------------------
CFG="$ROOT/cfg"
mkdir -p "$CFG/src" "$CFG/templates" "$CFG/generated/api"
git init -q -b main "$CFG"
git -C "$CFG" config user.email t@t
git -C "$CFG" config user.name t
cat > "$CFG/.myspec.json" <<'JSON'
{"aiDir":".ai","hooks":{"markCodeChanged":{
  "extraCodeExtensions":["twig",".proto","not an ext","c++"],
  "ignorePaths":["generated/**","**/*.gen.ts","../outside/**",
    "src/(old)/**","lib/a$b.ts","src/v?.ts","*.gen.ts"]}}}
JSON
git -C "$CFG" add .myspec.json
git -C "$CFG" commit -q -m init

write "$SID-70" "$CFG" "$CFG/templates/page.twig"
ledger_has "$SID-70" code "$CFG" templates/page.twig && ok || fail "an extra code extension arms the gate"
# shellcheck disable=SC2016 # literal text, not an expansion
grep -qxF -- '- `templates/page.twig`' "$CFG/.claude/state/sessions/$SID-70.md" 2>/dev/null \
  && ok || fail "an extra code extension is logged as a code path"
write "$SID-71" "$CFG" "$CFG/src/api.proto"
ledger_has "$SID-71" code "$CFG" src/api.proto && ok || fail "an extra extension given with its dot is code too"
write "$SID-72" "$CFG" "$CFG/src/a.ts"
ledger_has "$SID-72" code "$CFG" src/a.ts && ok || fail "the default extensions still count"
write "$SID-73" "$CFG" "$CFG/src/notes.md"
ledger_has "$SID-73" file "$CFG" src/notes.md && ok || fail "an extension in neither list stays file"

write "$SID-74" "$CFG" "$CFG/generated/api/client.ts"
ledger_has "$SID-74" file "$CFG" generated/api/client.ts && ok || fail "an ignorePaths match records a code write as file"
no_code_for "$SID-74" "$CFG" && ok || fail "an ignorePaths match does not arm the gate"
[ ! -f "$CFG/.claude/state/sessions/$SID-74.md" ] && ok || fail "an ignored write creates no log"
write "$SID-75" "$CFG" "$CFG/src/schema.gen.ts"
ledger_has "$SID-75" file "$CFG" src/schema.gen.ts && ok || fail "a **/ glob matches below the root"
bashcmd "$SID-76" "$CFG" 'echo x > generated/out.twig'
ledger_has "$SID-76" file "$CFG" generated/out.twig && ok || fail "ignorePaths applies to a Bash write and wins over an extra extension"

# Glob metacharacters are literal (PR #243 review): an unescaped . made
# *.gen.ts match codegen.ts, and ( ) $ made a glob never match.
write "$SID-84" "$CFG" "$CFG/codegen.ts"
ledger_has "$SID-84" code "$CFG" codegen.ts && ok || fail "*.gen.ts does not match the near-miss codegen.ts"
write "$SID-84" "$CFG" "$CFG/x.gen.ts"
ledger_has "$SID-84" file "$CFG" x.gen.ts && ok || fail "*.gen.ts matches x.gen.ts"
write "$SID-84" "$CFG" "$CFG/src/(old)/legacy.ts"
ledger_has "$SID-84" file "$CFG" "src/(old)/legacy.ts" && ok || fail "src/(old)/** matches a path under src/(old)/"
write "$SID-84" "$CFG" "$CFG/src/old/legacy.ts"
ledger_has "$SID-84" code "$CFG" src/old/legacy.ts && ok || fail "src/(old)/** does not match src/old/"
write "$SID-84" "$CFG" "$CFG/lib/a\$b.ts"
# shellcheck disable=SC2016 # literal text, not an expansion
ledger_has "$SID-84" file "$CFG" 'lib/a$b.ts' && ok || fail "a glob with \$ matches its literal path"
write "$SID-84" "$CFG" "$CFG/src/v1.ts"
ledger_has "$SID-84" file "$CFG" src/v1.ts && ok || fail "? matches one character"
write "$SID-84" "$CFG" "$CFG/src/v12.ts"
ledger_has "$SID-84" code "$CFG" src/v12.ts && ok || fail "? does not match two characters"
write "$SID-84" "$CFG" "$CFG/src/a/b/c/deep.gen.ts"
ledger_has "$SID-84" file "$CFG" src/a/b/c/deep.gen.ts && ok || fail "**/ crosses several levels"

# An extension with an ERE metacharacter is literal (PR #243 review): c++
# made CODE_RE uncompilable on macOS, so every write was recorded as file.
write "$SID-85" "$CFG" "$CFG/src/b.c++"
ledger_has "$SID-85" code "$CFG" src/b.c++ && ok || fail "an extra extension c++ arms the gate"
write "$SID-85" "$CFG" "$CFG/src/a.ts"
ledger_has "$SID-85" code "$CFG" src/a.ts && ok || fail "with c++ configured, a.ts still arms the gate"
write "$SID-85" "$CFG" "$CFG/src/b.cc"
ledger_has "$SID-85" file "$CFG" src/b.cc && ok || fail "c++ is not read as one-or-more c"

# Fail closed: a code pattern that does not compile falls back to the
# defaults with a warning instead of recording every write as file.
FALLBACK=$(CODE_EXT='(ts|py)' bash -c "$(sed -n '/^code_re_or_default()/,/^}/p' "$HOOK")"'
  code_re_or_default "\\.(ts|(x)\$"' 2>"$ROOT/fallback.err")
[ "$FALLBACK" = '\.(ts|py)$' ] && ok || fail "an uncompilable CODE_RE falls back to the default (got: $FALLBACK)"
grep -qF 'does not compile' "$ROOT/fallback.err" && ok || fail "an uncompilable CODE_RE is warned about on stderr"
KEPT=$(CODE_EXT='(ts|py)' bash -c "$(sed -n '/^code_re_or_default()/,/^}/p' "$HOOK")"'
  code_re_or_default "\\.(ts|c\\+\\+)\$"' 2>/dev/null)
[ "$KEPT" = '\.(ts|c\+\+)$' ] && ok || fail "a compilable CODE_RE is kept (got: $KEPT)"

# Settings come from the checkout holding the file, not the cwd.
write "$SID-77" "$REPO" "$CFG/templates/x.twig"
ledger_has "$SID-77" code "$CFG" templates/x.twig && ok || fail "a write into a configured checkout uses its settings from another cwd"
write "$SID-78" "$CFG" "$REPO/src/y.twig"
ledger_has "$SID-78" file "$REPO" src/y.twig && ok || fail "a write into an unconfigured checkout ignores the cwd's settings"
write "$SID-79" "$CFG" "$REPO/generated/z.ts"
ledger_has "$SID-79" code "$REPO" generated/z.ts && ok || fail "the cwd's ignorePaths does not reach another checkout"

# A linked worktree reads its own committed settings.
git -C "$CFG" worktree add -q "$CFG/.claude/worktrees/wt-c" -b wt-c
CWT="$CFG/.claude/worktrees/wt-c"
mkdir -p "$CWT/generated"
write "$SID-80" "$CWT" "$CWT/generated/w.ts"
ledger_has "$SID-80" file "$CWT" generated/w.ts && ok || fail "a worktree applies ignorePaths repo-relative to itself"
write "$SID-81" "$CWT" "$CWT/w.twig"
ledger_has "$SID-81" code "$CWT" w.twig && ok || fail "a worktree applies extraCodeExtensions"

# Fail closed: a wrong type falls back to the defaults and is named.
BAD="$ROOT/bad"
mkdir -p "$BAD/generated"
git init -q -b main "$BAD"
printf '{"hooks":{"markCodeChanged":{"ignorePaths":"generated/**","extraCodeExtensions":"twig"}}}\n' > "$BAD/.myspec.json"
ERR=$(printf '{"session_id":"%s-82","tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/generated/a.ts"}}' "$SID" "$BAD" "$BAD" | bash "$HOOK" 2>&1 >/dev/null)
ledger_has "$SID-82" code "$BAD" generated/a.ts && ok || fail "a malformed ignorePaths does not loosen the gate"
case "$ERR" in *hooks.markCodeChanged.ignorePaths*) ok ;; *) fail "a malformed setting is named (stderr: $ERR)" ;; esac
ERR=$(printf '{"session_id":"%s-83","tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/b.twig"}}' "$SID" "$CFG" "$CFG" | bash "$HOOK" 2>&1 >/dev/null)
case "$ERR" in *"not an ext"*"not an extension"*) ok ;; *) fail "an invalid extension entry is named (stderr: $ERR)" ;; esac
case "$ERR" in *"../outside/**"*"leaves the checkout"*) ok ;; *) fail "a glob leaving the checkout is named (stderr: $ERR)" ;; esac

# --- subagents: agent_id is recorded, session_id stays the key (#225) ----------
write_agent() {  # write_agent <sid> <cwd> <file-path> <agent_id> [agent_type]
  jq -n --arg s "$1" --arg d "$2" --arg f "$3" --arg a "$4" --arg t "${5:-}" \
    '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}, agent_id: $a}
     + (if $t == "" then {} else {agent_type: $t} end)' | bash "$HOOK" >/dev/null 2>&1
}
write_agent "$SID-90" "$REPO" "$REPO/src/sub.ts" a6baef07 general-purpose
grep -qxF -- "$(printf 'code\t%s\tsrc/sub.ts\ta6baef07' "$REPO")" <(ledger "$SID-90") \
  && ok || fail "a subagent write is recorded with its agent_id under the parent's session_id"
expect_log "$SID-90" "a subagent's first code edit creates the parent's log"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-90" '- `src/sub.ts` (subagent a6baef07, general-purpose)' "the log tags a subagent's path"
write "$SID-90" "$REPO" "$REPO/src/sub.ts"
grep -qxF -- "$(printf 'code\t%s\tsrc/sub.ts' "$REPO")" <(ledger "$SID-90") \
  && ok || fail "the main session's write of the same path gets its own three-field line"
# shellcheck disable=SC2016 # literal text, not an expansion
grep -qxF -- '- `src/sub.ts`' "$STATE/$SID-90.md" && ok || fail "the main session's own edit is logged untagged beside the subagent's"
write_agent "$SID-90" "$REPO" "$REPO/src/sub.ts" a6baef07 general-purpose
# shellcheck disable=SC2016 # literal text, not an expansion
[ "$(grep -cF -- '- `src/sub.ts`' "$STATE/$SID-90.md")" -eq 2 ] && ok || fail "each line is logged once"
write_agent "$SID-91" "$REPO" "$REPO/src/odd.ts" $'b1\tx`y'
grep -qxF -- "$(printf 'code\t%s\tsrc/odd.ts\tb1xy' "$REPO")" <(ledger "$SID-91") \
  && ok || fail "an agent_id is reduced to id-safe characters"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_in "$SID-91" '- `src/odd.ts` (subagent b1xy)' "a tag without agent_type names the id only"

# --- not a myspec project: no state there; a stop gate alone gets the ledger ----
OTHER="$ROOT/other"
mkdir -p "$OTHER/src"
git init -q -b main "$OTHER"
write "$SID-11" "$OTHER" "$OTHER/src/x.ts"
[ -z "$(ledger "$SID-11")" ] && ok || fail "a repository without .myspec.json or a stop gate gets no ledger"
[ ! -e "$OTHER/.claude/state" ] && ok || fail "no state tree outside a myspec project"
mkdir -p "$OTHER/.claude"
printf '{"checks":[]}\n' > "$OTHER/.claude/verification.json"
write "$SID-12" "$OTHER" "$OTHER/src/x.ts"
ledger_has "$SID-12" code "$OTHER" src/x.ts && ok || fail "a repository with a stop gate gets the ledger"
[ ! -e "$OTHER/.claude/state/sessions/$SID-12.md" ] && ok || fail "but no log outside a myspec project"

# --- feature-implement's state: recorded from the command, by session id -----
implement_events() {  # implement_events <sid> -> the implement states, in order
  find "$ROOT" -path "*/.claude/state/sessions/$1.jsonl" -exec cat {} + 2>/dev/null \
    | jq -r 'select(.t == "implement") | .state' | tr '\n' ' '
}
# shellcheck disable=SC2016 # literal text, not an expansion
bashcmd "$SID-95" "$REPO" '"$(git rev-parse --show-toplevel)"/.claude/lib/session-event.sh implement start'
[ "$(implement_events "$SID-95")" = "start " ] && ok || fail "implement start is recorded for the payload's session (got: $(implement_events "$SID-95"))"
# shellcheck disable=SC2016 # literal text, not an expansion
bashcmd "$SID-95" "$REPO/src" '"$(git rev-parse --show-toplevel)/.claude/lib/session-event.sh" implement stop && echo done'
[ "$(implement_events "$SID-95")" = "start stop " ] && ok || fail "a fully quoted path and a cwd below the root still record (got: $(implement_events "$SID-95"))"
bashcmd "$SID-96" "$REPO" 'echo "session-event.sh implement start" > notes.txt; grep implement session-event.sh'
[ -z "$(implement_events "$SID-96")" ] && ok || fail "a mention of the command is not a run of it"
bashcmd "$SID-97" "$REPO/.claude/worktrees/wt-a" '.claude/lib/session-event.sh implement start'
[ -f "$STATE/$SID-97.jsonl" ] && [ "$(implement_events "$SID-97")" = "start " ] && ok || fail "from a linked worktree the event lands in the main checkout's file"
# The script run through an interpreter or a wrapper is still a run of it.
n=0
for c in 'bash .claude/lib/session-event.sh implement start' \
         'sh .claude/lib/session-event.sh implement start' \
         'env -i PATH=/usr/bin .claude/lib/session-event.sh implement start' \
         'command bash -e .claude/lib/session-event.sh implement start' \
         'env -u HOME -- bash -euo pipefail .claude/lib/session-event.sh implement start'; do
  n=$((n + 1))
  bashcmd "$SID-98-$n" "$REPO" "$c"
  [ "$(implement_events "$SID-98-$n")" = "start " ] && ok || fail "'$c' records implement start (got: $(implement_events "$SID-98-$n"))"
done
bashcmd "$SID-99" "$REPO" 'bash -c "echo session-event.sh implement start"'
[ -z "$(implement_events "$SID-99")" ] && ok || fail "bash -c with the words in its string is not a run of the script"

# --- snapshots of a Bash write, for the Stop gate's content checks (R14) ------------
# PreToolUse records the file's blob before the write ("" when absent), only
# for a file the content checks cover; PostToolUse records the write with
# via and the blob after. Neither records an implement event twice.
events() { jq -r "$2" "$STATE/$1.jsonl" 2>/dev/null | tr '\n' ' '; }
pre() {  # pre <sid> <cwd> <command>
  jq -nc --arg s "$1" --arg c "$2" --arg cmd "$3" '{hook_event_name: "PreToolUse", session_id: $s, tool_name: "Bash", cwd: $c, tool_input: {command: $cmd}}' \
    | bash "$HOOK" >/dev/null 2>&1
}
mkdir -p "$REPO/docs"
printf 'before\n' > "$REPO/docs/snap.md"
CMD="printf 'after\n' > docs/snap.md && printf 'x\n' > docs/new.md && printf 'y\n' > src/snap.ts"
pre "$SID-sn" "$REPO" "$CMD"
BEFORE=$(git -C "$REPO" hash-object docs/snap.md)
[ "$(events "$SID-sn" 'select(.t == "pre") | [.rel, .blob] | join("=")')" = "docs/snap.md=$BEFORE docs/new.md= " ] && ok \
  || fail "PreToolUse snapshots each covered target, \"\" for a new file, nothing for code (got: $(events "$SID-sn" 'select(.t == "pre")'))"
[ -z "$(events "$SID-sn" 'select(.t == "write")')" ] && ok || fail "PreToolUse records no write"
[ ! -f "$STATE/$SID-sn.md" ] && ok || fail "PreToolUse creates no session log"
(cd "$REPO" && eval "$CMD")
bashcmd "$SID-sn" "$REPO" "$CMD"
AFTER=$(git -C "$REPO" hash-object docs/snap.md)
[ "$(events "$SID-sn" 'select(.t == "write" and .rel == "docs/snap.md") | [.via, .blob] | join("=")')" = "bash=$AFTER " ] && ok \
  || fail "PostToolUse records the Bash write with its blob after (got: $(events "$SID-sn" 'select(.t == "write")'))"
git -C "$REPO" cat-file -e "$AFTER" && ok || fail "the blob after is in the object store"
[ "$(events "$SID-sn" 'select(.t == "write" and .rel == "src/snap.ts") | (.via + "=" + (.blob // "none"))')" = "bash=none " ] && ok \
  || fail "a code file gets no blob"
write "$SID-sn" "$REPO" "$REPO/docs/snap.md"
[ "$(events "$SID-sn" 'select(.t == "write" and .via == "tool") | .rel')" = 'docs/snap.md ' ] && ok || fail "a Write is recorded via tool"
pre "$SID-sn2" "$REPO" 'bash .claude/lib/session-event.sh implement start'
[ -z "$(implement_events "$SID-sn2")" ] && ok || fail "PreToolUse records no implement event"
rm -rf "$REPO/docs" "$REPO/src/snap.ts"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
