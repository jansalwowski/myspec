#!/usr/bin/env bash
# Regression fixture for mark-code-changed.sh fixes the main fixture
# (mark-code-changed.test.sh) does not cover. One case per past fix:
#
#   67f0814  .mjs, .cjs, .sh and .bash were not code extensions, so a session
#            that only edited those files left no marker: the Stop hook never
#            ran verification and no session log was created.
#   #145     Read-only Bash commands armed the Stop hook: `2>/dev/null` counted
#            as a write, and every code path in the command was recorded, not
#            just the write target. A write outside any repository (/tmp, a
#            scratchpad) counted too, and `.graphql` was not a code extension.
#   #152     The marker was an empty file, so an edit in a sibling repository
#            armed this repository's Stop gate. It now names the repo root.
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
trap 'rm -rf "$ROOT"; rm -f /tmp/.myspec-code-changed-'"$SID"'-*' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

write() {  # write <sid> <file-path>
  printf '{"session_id":%s,"tool_name":"Write","cwd":%s,"tool_input":{"file_path":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
}

bashcmd() {  # bashcmd <sid> <command>
  printf '{"session_id":%s,"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
}

no_trace() {  # no_trace <sid> <desc>
  [ ! -e "/tmp/.myspec-code-changed-$1" ] && ok || fail "$2 arms no Stop-hook marker"
  [ ! -e "$REPO/.claude/state/sessions/$1.md" ] && ok || fail "$2 writes no session log"
}

# --- 67f0814: script extensions count as code ---------------------------------
for ext in mjs cjs sh bash; do
  sid="$SID-$ext"
  write "$sid" "$REPO/src/tool.$ext"
  [ -f "/tmp/.myspec-code-changed-$sid" ] && ok || fail "a .$ext edit writes the Stop-hook marker"
  [ -f "$REPO/.claude/state/sessions/$sid.md" ] && ok || fail "a .$ext edit creates the session log"
done

# --- control: a non-code file still does not count ----------------------------
write "$SID-txt" "$REPO/src/notes.txt"
[ ! -f "/tmp/.myspec-code-changed-$SID-txt" ] && ok || fail "a .txt edit writes no marker"

# --- #145: read-only commands record nothing ----------------------------------
bashcmd "$SID-boot" "jq '{aiDir}' .myspec.json; node .claude/lib/memory-doctor.mjs --quiet 2>&1 | tail -2; ls .claude/state/sessions/ 2>/dev/null"
no_trace "$SID-boot" "the bootstrap orientation command"
bashcmd "$SID-cat" 'cat foo.py 2>/dev/null'
no_trace "$SID-cat" "cat with stderr to /dev/null"
bashcmd "$SID-grep" 'grep -c x src/router.js 2>/dev/null'
no_trace "$SID-grep" "grep with stderr to /dev/null"
bashcmd "$SID-dup" 'node src/run.mjs >&2 2>&1'
no_trace "$SID-dup" "fd duplications"

# --- #145: only the write target of a segment is recorded -------------------
bashcmd "$SID-seg" 'node src/gen.mjs --check 2>/dev/null; grep -n x src/other.ts; echo x > src/out.ts'
LOG="$REPO/.claude/state/sessions/$SID-seg.md"
grep -qF -- '- `src/out.ts`' "$LOG" 2>/dev/null && ok || fail "the real write target is recorded"
TOUCHED=$(sed -n '/^## Files touched/,$p' "$LOG" 2>/dev/null | grep '^- `' | tr '\n' ' ')
[ "$TOUCHED" = '- `src/out.ts` ' ] && ok || fail "only the write target is recorded (got: $TOUCHED)"

# --- #145: a write outside any repository is not a code change --------------
SCRATCH="$ROOT/scratch"
mkdir -p "$SCRATCH"
bashcmd "$SID-tmp" "echo x > $SCRATCH/probe.py"
no_trace "$SID-tmp" "a redirect into a scratch directory"
bashcmd "$SID-tmp2" "sed -i -e s/a/b/ $SCRATCH/probe.py; cp src/a.ts $SCRATCH/"
no_trace "$SID-tmp2" "sed -i and cp into a scratch directory"
write "$SID-tmp3" "$SCRATCH/probe.ts"
no_trace "$SID-tmp3" "a Write into a scratch directory"

# --- #152: .graphql is code ---------------------------------------------------
bashcmd "$SID-gql" 'echo x > api/schema.graphql'
[ -f "/tmp/.myspec-code-changed-$SID-gql" ] && ok || fail "a write to a .graphql file arms the Stop-hook marker"

# --- #152: the marker names the repository the edit belongs to -------------
SIB="$ROOT/sibling"
mkdir -p "$SIB/src"
git init -q -b main "$SIB"
write "$SID-sib" "$SIB/src/app.js"
M="/tmp/.myspec-code-changed-$SID-sib"
grep -qxF "$SIB" "$M" 2>/dev/null && ok || fail "a sibling-repo edit writes the sibling root into the marker"
grep -qxF "$REPO" "$M" 2>/dev/null && fail "a sibling-repo edit does not name this repo in the marker" || ok
write "$SID-sib" "$REPO/src/a.ts"
write "$SID-sib" "$REPO/src/b.ts"
grep -qxF "$REPO" "$M" 2>/dev/null && ok || fail "a later edit here adds this repo to the marker"
[ "$(grep -cxF "$REPO" "$M" 2>/dev/null)" = 1 ] && ok || fail "a repo root is written to the marker once"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
