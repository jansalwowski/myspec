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

# --- control: a non-code file still does not count ----------------------------
write "$SID-txt" "$REPO/src/notes.txt"
! grep -q "^code	" <(ledger "$SID-txt") 2>/dev/null && ok || fail "a .txt edit does not arm the Stop hook"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
