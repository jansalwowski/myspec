#!/usr/bin/env bash
# Regression fixture for mark-code-changed.sh fixes the main fixture
# (mark-code-changed.test.sh) does not cover. One case per past fix:
#
#   67f0814  .mjs, .cjs, .sh and .bash were not code extensions, so a session
#            that only edited those files left no marker: the Stop hook never
#            ran verification and no session log was created.
#   #249     a Bash command longer than a pipe buffer (a heredoc that writes a
#            file) killed the hook with SIGPIPE: `printf | tr | head -c 120`
#            under pipefail and set -e exited 141 before the ledger line.
#   (globs)  ignorePaths had its own glob compiler, where a trailing `/`
#            matched nothing, unlike checks[].paths; all three glob settings
#            now share lib/glob-regex.sh.
#   #254     a write into a plain clone nested in the project (not a
#            submodule, no .myspec.json of its own) was dropped, so it no
#            longer armed the project's stop gate. It is filed with the cwd's
#            checkout, under its own root, and verified through it.
#   (review) a linked worktree whose branch adds .claude/verification.json,
#            while the main checkout has no myspec config, dropped every write:
#            tracking was asked of the main checkout only.
#   (review) in a bare repository with worktrees each worktree kept its own
#            state file, so an edit in worktree B from a session whose cwd is
#            worktree A was never verified (R3a).
#   (review) a session upgraded mid feature-implement had the 2.x marker
#            (.claude/state/implement-in-progress.json) and no implement
#            event, so its failures blocked where they had warned.
#
# Usage: mark-code-changed-regression.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mark-code-changed.sh}"

if [ ! -f "$HOOK" ]; then
  echo "FATAL: hook not found: $HOOK" >&2
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
SID="mcr-$$"
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

write() {  # write <sid> <file-path>
  printf '{"session_id":%s,"tool_name":"Write","cwd":%s,"tool_input":{"file_path":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
}

# --- 67f0814: script extensions count as code ---------------------------------
for ext in mjs cjs sh bash; do
  sid="$SID-$ext"
  write "$sid" "$REPO/src/tool.$ext"
  grep -q "^code	" <(ledger "$sid") 2>/dev/null && ok || fail "a .$ext edit arms the Stop hook"
  [ -f "$REPO/.claude/state/sessions/$sid.md" ] && ok || fail "a .$ext edit creates the session log"
done

# --- #249: a 100 KiB Bash heredoc write still reaches the ledger -------------
sid="$SID-big"
big_cmd=$(awk 'BEGIN { printf "cat > src/big.ts <<'"'"'EOF'"'"'\n"; for (i = 0; i < 4000; i++) printf "export const value%05d = %05d;\n", i, i; printf "EOF" }')
[ "${#big_cmd}" -ge 102400 ] && ok || fail "the #249 fixture command is at least 100 KiB (got ${#big_cmd})"
rc=0
printf '{"session_id":%s,"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' \
  "$(printf '%s' "$sid" | jq -Rs .)" "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s' "$big_cmd" | jq -Rs .)" \
  | bash "$HOOK" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || fail "a 100 KiB Bash heredoc write exits 0 (got $rc)"
grep -q "^code	$REPO	src/big.ts$" <(ledger "$sid") 2>/dev/null && ok || fail "a 100 KiB Bash heredoc write lands in the ledger"

# --- (globs) ignorePaths "gen/" covers everything under gen/ ------------------
GLOBREPO="$ROOT/globs"
mkdir -p "$GLOBREPO/gen/x" "$GLOBREPO/src"
git init -q -b main "$GLOBREPO"
printf '{"aiDir":".ai","hooks":{"markCodeChanged":{"ignorePaths":["gen/"]}}}\n' > "$GLOBREPO/.myspec.json"
for f in gen/x/a.ts src/b.ts; do
  sid="$SID-glob-${f//\//-}"
  printf '{"session_id":"%s","tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/%s"}}' "$sid" "$GLOBREPO" "$GLOBREPO" "$f" \
    | bash "$HOOK" >/dev/null 2>&1
done
grep -q "^file	$GLOBREPO	gen/x/a.ts$" <(ledger "$SID-glob-gen-x-a.ts") 2>/dev/null && ok || fail "ignorePaths gen/ records gen/x/a.ts as file"
grep -q "^code	$GLOBREPO	src/b.ts$" <(ledger "$SID-glob-src-b.ts") 2>/dev/null && ok || fail "ignorePaths gen/ leaves src/b.ts code"

# --- #254: a write into a nested non-submodule clone arms the project's gate -
STOP="$(dirname "$HOOK")/verify-before-stop.sh"
PROJ="$ROOT/nested-project"
mkdir -p "$PROJ/.claude" "$PROJ/vendored"
git init -q -b main "$PROJ"
git -C "$PROJ" config user.email t@t
git -C "$PROJ" config user.name t
printf '{"aiDir":".ai"}\n' > "$PROJ/.myspec.json"
printf '.claude/state/\nvendored/\n' > "$PROJ/.gitignore"
printf '{"checks":[{"name":"red","command":"false","required":true}]}\n' > "$PROJ/.claude/verification.json"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m init
git init -q -b main "$PROJ/vendored"
printf 'export const x = 1;\n' > "$PROJ/vendored/x.ts"
sid="$SID-nested"
jq -n --arg s "$sid" --arg d "$PROJ" --arg f "$PROJ/vendored/x.ts" '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}}' \
  | bash "$HOOK" >/dev/null 2>&1
grep -q "^code	$PROJ/vendored	x.ts$" <(ledger "$sid") 2>/dev/null && ok || fail "a nested clone's write is filed with the cwd's project under its own root (got: $(ledger "$sid"))"
[ ! -e "$PROJ/vendored/.claude" ] && ok || fail "no state tree in the nested clone"
got=$(jq -n --arg s "$sid" --arg d "$PROJ" '{session_id: $s, cwd: $d}' | bash "$STOP" 2>/dev/null | jq -r '.decision // "none"' 2>/dev/null)
[ "$got" = block ] && ok || fail "the Stop hook blocks on the project's red check after a nested-clone write (got: $got)"
git init -q -b main "$ROOT/plain"
jq -n --arg s "$SID-outside" --arg d "$PROJ" --arg f "$ROOT/plain/c.ts" '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}}' \
  | bash "$HOOK" >/dev/null 2>&1
[ ! -e "$PROJ/.claude/state/sessions/$SID-outside.jsonl" ] && ok || fail "a write in an untracked repository outside the cwd's checkout is not filed with it"

# --- (review) a worktree-only stop gate still arms --------------------------
WTMAIN="$ROOT/wt-only"
mkdir -p "$WTMAIN"
git init -q -b main "$WTMAIN"
git -C "$WTMAIN" config user.email t@t
git -C "$WTMAIN" config user.name t
printf '.claude/state/\n' > "$WTMAIN/.gitignore"
git -C "$WTMAIN" add -A
git -C "$WTMAIN" commit -q -m init
git -C "$WTMAIN" worktree add -q "$ROOT/wt-only-b" -b gate
WTB="$ROOT/wt-only-b"
mkdir -p "$WTB/.claude"
printf '{"checks":[{"name":"red","command":"false","required":true}]}\n' > "$WTB/.claude/verification.json"
git -C "$WTB" add -A
git -C "$WTB" commit -q -m gate
printf 'export const w = 1;\n' > "$WTB/w.ts"
sid="$SID-wtonly"
jq -n --arg s "$sid" --arg d "$WTB" --arg f "$WTB/w.ts" '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}}' \
  | bash "$HOOK" >/dev/null 2>&1
grep -q "^code	$WTB	w.ts$" <(ledger "$sid") 2>/dev/null && ok || fail "a write in a worktree with its own stop gate is recorded (got: $(ledger "$sid"))"
got=$(jq -n --arg s "$sid" --arg d "$WTB" '{session_id: $s, cwd: $d}' | bash "$STOP" 2>/dev/null | jq -r '.decision // "none"' 2>/dev/null)
[ "$got" = block ] && ok || fail "the worktree's Stop gate blocks on its red check (got: $got)"

# --- (review) bare repository: an edit in worktree B from cwd A is verified --
git init -q -b main "$ROOT/bsrc"
git -C "$ROOT/bsrc" config user.email t@t
git -C "$ROOT/bsrc" config user.name t
mkdir -p "$ROOT/bsrc/.claude"
printf '{"aiDir":".ai"}\n' > "$ROOT/bsrc/.myspec.json"
printf '.claude/state/\n' > "$ROOT/bsrc/.gitignore"
printf '{"checks":[{"name":"red","command":"false","required":true}]}\n' > "$ROOT/bsrc/.claude/verification.json"
git -C "$ROOT/bsrc" add -A
git -C "$ROOT/bsrc" commit -q -m init
git clone -q --bare "$ROOT/bsrc" "$ROOT/b.git"
git -C "$ROOT/b.git" worktree add -q -b wa "$ROOT/b-wa" >/dev/null 2>&1
git -C "$ROOT/b.git" worktree add -q -b wb "$ROOT/b-wb" >/dev/null 2>&1
printf 'export const b = 1;\n' > "$ROOT/b-wb/b.ts"
sid="$SID-bare"
jq -n --arg s "$sid" --arg d "$ROOT/b-wa" --arg f "$ROOT/b-wb/b.ts" '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}}' \
  | bash "$HOOK" >/dev/null 2>&1
[ -f "$ROOT/b.git/myspec-state/sessions/$sid.jsonl" ] && ok || fail "a bare repository's worktree write is filed under its common dir"
got=$(jq -n --arg s "$sid" --arg d "$ROOT/b-wa" '{session_id: $s, cwd: $d}' | bash "$STOP" 2>/dev/null | jq -r '.decision // "none"' 2>/dev/null)
[ "$got" = block ] && ok || fail "the Stop gate from worktree A verifies worktree B's edit (got: $got)"

# --- (review) the legacy implement marker carries a run across the upgrade ---
printf '{"started_at":%d,"feature":"f"}\n' "$(date +%s)" > "$PROJ/.claude/state/implement-in-progress.json"
sid="$SID-upgrade"
for n in 1 2; do
  printf 'export const u = %d;\n' "$n" > "$PROJ/u.ts"
  jq -n --arg s "$sid" --arg d "$PROJ" --arg f "$PROJ/u.ts" '{session_id: $s, tool_name: "Write", cwd: $d, tool_input: {file_path: $f}}' \
    | bash "$HOOK" >/dev/null 2>&1
  out=$(jq -n --arg s "$sid" --arg d "$PROJ" '{session_id: $s, cwd: $d}' | bash "$STOP" 2>/dev/null)
  got=$(printf '%s' "$out" | jq -r '.decision // "none"' 2>/dev/null)
  [ "$got" != block ] && printf '%s' "$out" | grep -q 'feature-implement' && ok || fail "stop $n during an upgraded feature-implement run warns (got: $got)"
done
n=$(jq -r 'select(.t == "implement") | .state' "$PROJ/.claude/state/sessions/$sid.jsonl" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 1 ] && [ -f "$PROJ/.claude/state/implement-in-progress.json.imported" ] && ok || fail "the marker is imported once (implement events: $n)"

# --- control: a non-code file still does not count ----------------------------
write "$SID-txt" "$REPO/src/notes.txt"
! grep -q "^code	" <(ledger "$SID-txt") 2>/dev/null && ok || fail "a .txt edit does not arm the Stop hook"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
