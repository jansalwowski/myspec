#!/usr/bin/env bash
# Tests for lib/mockup-config-check.mjs: update's list of the mockup blueprint
# questions a generated ${aiDir}/conventions/mockup-design.md was never asked
# (rows of the blueprint's *Added questions* table newer than the file's
# myspec_version stamp), and --stamp, which writes only that frontmatter line.
#
# Usage: mockup-config-check.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../mockup-config-check.mjs}"
REAL_BLUEPRINT="$HERE/../../blueprints/mockup.md"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
FILE="$REPO/ai/conventions/mockup-design.md"
BLUEPRINT="$ROOT/mockup.md"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect_status() {   # expect_status <code> <description>
  if [ "$STATUS" = "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1; output: $OUTPUT)"; fi
}
expect_line() {     # expect_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi
}
expect_no_line() {  # expect_no_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi
}
expect_file() {     # expect_file <expected content> <description>
  if [ "$(cat "$FILE")" = "$1" ]; then ok; else fail "$2 (got: $(cat "$FILE"))"; fi
}

run() { OUTPUT=$(cd "$REPO" && node "$SCRIPT" --blueprint "$BLUEPRINT" "$@" 2>&1 </dev/null); STATUS=$?; }

mkdir -p "$(dirname "$FILE")"
printf '{"aiDir":"ai"}\n' > "$REPO/.myspec.json"

cat > "$BLUEPRINT" <<'MD'
# Blueprint: Mockup

## Added questions

| Question | Section | Since |
|---|---|---|
| Q13 | Motion | 3.8.0 |
| Q14 | Print layouts | v4.0.0 |

**Asking only the added questions.** Not a row: | Q99 | Nope | 9.9.9 |

## Output Location
| Q15 | Outside the table | 5.0.0 |
MD

stamped_file() { printf -- '---\ntitle: "Mockup Design Conventions"\nmyspec_version: %s\n---\n\n## Always\n| Rule | Detail |\n' "$1" > "$FILE"; }

# --- 1. the real blueprint parses, and lists nothing for a current file -----

stamped_file 3.6.0
OUTPUT=$(cd "$REPO" && node "$SCRIPT" 2>&1 </dev/null); STATUS=$?
expect_status 0 "shipped blueprint parses (default --blueprint)"
expect_line '^mockup-config-check: 0 question\(s\) to ask$' "shipped table lists nothing newer than 3.6.0"

# --- 2. only rows newer than the stamp, only inside the table --------------

stamped_file 3.7.0
run
expect_status 3 "newer questions exit 3"
expect_line '^file: ai/conventions/mockup-design\.md  myspec_version: 3\.7\.0$' "file and stamp"
expect_line '^ask: Q13  ## Motion  \(since 3\.8\.0\)$' "Q13 offered"
expect_line '^ask: Q14  ## Print layouts  \(since 4\.0\.0\)$' "v-prefixed version read"
expect_no_line 'Q99|Q15' "rows outside the table ignored"
expect_line '^mockup-config-check: 2 question\(s\) to ask$' "summary"

stamped_file 3.8.0
run
expect_line '^ask: Q14 ' "Q14 still newer than 3.8.0"
expect_no_line '^ask: Q13 ' "Q13 not newer than its own version"

stamped_file '"v4.0"'
run
expect_status 0 "quoted loose stamp v4.0 reads as 4.0.0"

# --- 3. unstamped and odd files ----------------------------------------------

printf '# Mockup Design Conventions\n' > "$FILE"
run
expect_status 3 "no frontmatter counts as the base version"
expect_line '^file: .*  myspec_version: unstamped \(counted as 1\.20\.0\)$' "unstamped reported"

printf '\xef\xbb\xbf---\r\nmyspec_version: 4.0.0\r\n---\r\n' > "$FILE"
run
expect_status 0 "BOM and CRLF frontmatter: stamp read"

# --- 4. --stamp writes only the stamp line -----------------------------------

stamped_file 3.0.0
BODY=$(tail -n +4 "$FILE")
run --stamp 3.9.0
expect_status 0 "stamp exits 0"
expect_line '^stamped: ai/conventions/mockup-design\.md  myspec_version: 3\.9\.0$' "stamp reported"
if [ "$(sed -n 3p "$FILE")" = 'myspec_version: 3.9.0' ] && [ "$(tail -n +4 "$FILE")" = "$BODY" ]; then ok; else fail "stamp touched more than its line: $(cat "$FILE")"; fi
run
expect_line '^ask: Q14 ' "after stamping 3.9.0 only Q14 remains"

printf -- '---\ntitle: x\n---\nbody\n' > "$FILE"
run --stamp 3.9.0
expect_file "$(printf -- '---\ntitle: x\nmyspec_version: 3.9.0\n---\nbody')" "missing stamp key added before the closing ---"

printf '\xef\xbb\xbf---\r\nmyspec_version: 3.0.0\r\n---\r\nbody\n' > "$FILE"
run --stamp 3.9.0
if [ "$(head -c 3 "$FILE" | od -An -tx1 | tr -d ' ')" = efbbbf ]; then ok; else fail "BOM dropped"; fi
if [ "$(grep -c $'\r$' "$FILE")" = 3 ] && grep -q $'^myspec_version: 3.9.0\r$' "$FILE"; then ok; else fail "CRLF endings not kept: $(od -c "$FILE" | head -3)"; fi

printf 'no frontmatter\n' > "$FILE"
run --stamp 3.9.0
expect_status 2 "nothing to stamp exits 2"
expect_file 'no frontmatter' "file without frontmatter untouched"

# --- 5. errors -----------------------------------------------------------------

stamped_file 3.0.0
run --stamp nonsense
expect_status 2 "bad stamp version exits 2"
run --bogus x
expect_status 2 "unknown flag exits 2"
chmod 444 "$FILE"
run --stamp 3.9.0
chmod 644 "$FILE"
expect_status 2 "read-only file exits 2, not a crash"
expect_line '^mockup-config-check: .*(EACCES|permission denied)' "write error named"
printf '# no table\n' > "$ROOT/empty.md"
OUTPUT=$(cd "$REPO" && node "$SCRIPT" --blueprint "$ROOT/empty.md" 2>&1 </dev/null); STATUS=$?
expect_status 2 "blueprint without the section exits 2"
rm "$FILE"
run
expect_status 4 "missing file exits 4"

mkdir -p "$REPO/.ai/conventions"
printf '{"aiDir":""}\n' > "$REPO/.myspec.json"
printf -- '---\nmyspec_version: 4.0.0\n---\n' > "$REPO/.ai/conventions/mockup-design.md"
run
expect_line '^file: \.ai/conventions/mockup-design\.md ' "empty aiDir resolves to the schema default"

grep -q '^## Added questions$' "$REAL_BLUEPRINT" && ok || fail "shipped blueprint lost its Added questions heading"

printf '\nmockup-config-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
