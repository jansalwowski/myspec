#!/usr/bin/env bash
# Regression fixture for mark-code-changed.sh fixes the main fixture
# (mark-code-changed.test.sh) does not cover. One case per past fix:
#
#   67f0814  .mjs, .cjs, .sh and .bash were not code extensions, so a session
#            that only edited those files left no marker: the Stop hook never
#            ran verification and no session log was created.
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
trap 'rm -rf "$ROOT"; rm -f /tmp/.myspec-session-writes-'"$SID"'-*' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

write() {  # write <sid> <file-path>
  printf '{"session_id":%s,"tool_name":"Write","cwd":%s,"tool_input":{"file_path":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
}

# --- 67f0814: script extensions count as code ---------------------------------
for ext in mjs cjs sh bash; do
  sid="$SID-$ext"
  write "$sid" "$REPO/src/tool.$ext"
  grep -q "^code	" "/tmp/.myspec-session-writes-$sid" 2>/dev/null && ok || fail "a .$ext edit arms the Stop hook"
  [ -f "$REPO/.claude/state/sessions/$sid.md" ] && ok || fail "a .$ext edit creates the session log"
done

# --- control: a non-code file still does not count ----------------------------
write "$SID-txt" "$REPO/src/notes.txt"
! grep -q "^code	" "/tmp/.myspec-session-writes-$SID-txt" 2>/dev/null && ok || fail "a .txt edit does not arm the Stop hook"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
