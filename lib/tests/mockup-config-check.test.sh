#!/usr/bin/env bash
# Tests for lib/mockup-config-check.mjs: update's list of the mockup blueprint
# questions a generated ${aiDir}/conventions/mockup-design.md was never asked
# in their current form (rows of the blueprint's *Question changes* table
# newer than the file's myspec_version stamp), and --stamp, which writes only
# that frontmatter line, with the plugin's own version.
#
# Usage: mockup-config-check.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../mockup-config-check.mjs}"
REAL_BLUEPRINT="$HERE/../../blueprints/mockup.md"
PLUGIN_VERSION=$(sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' "$HERE/../../framework-files/manifest.json" | head -1)

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

table() {           # table <rows…>: a blueprint whose Question changes table holds the rows
  {
    printf '# Blueprint: Mockup\n\n## Question changes\n\nIntro.\n\n| Question | Writes | Since |\n|---|---|---|\n'
    printf '%s\n' "$@"
    # shellcheck disable=SC2016 # literal backticks in a markdown table
    printf '\n### Writes forms\n\nThe *Writes* cell forms:\n\n| Form | Example | How |\n|---|---|---|\n| `## X (new section)` | ex | how |\n\n## Output Location\n| Q15 | Outside | 5.0.0 |\n'
  } > "$BLUEPRINT"
}

stamped_file() { printf -- '---\ntitle: "Mockup Design Conventions"\nmyspec_version: %s\n---\n\n## Always\n| Rule | Detail |\n' "$1" > "$FILE"; }

table '| Q13 | ## Motion (new section) | 3.8.0 |' '| 2 | ## Style baseline (in section) | v4.0 |'

# --- 1. the shipped blueprint parses -----------------------------------------

# Rows carry the release they ship in, which can be newer than the manifest
# until /release bumps it, so only parsing is asserted: exit 0 or 3, never 2.
stamped_file "$PLUGIN_VERSION"
OUTPUT=$(cd "$REPO" && node "$SCRIPT" 2>&1 </dev/null); STATUS=$?
if [ "$STATUS" = 0 ] || [ "$STATUS" = 3 ]; then ok; else fail "shipped blueprint does not parse (exit $STATUS): $OUTPUT"; fi
printf '# Mockup Design Conventions\n' > "$FILE"
OUTPUT=$(cd "$REPO" && node "$SCRIPT" 2>&1 </dev/null); STATUS=$?
expect_line '^ask: Q2  writes: ## Component library \(replaces section\)  \(since 1\.21\.0\)$' "shipped Q2 row offered to an unstamped v1.20.0 file"

# --- 2. only rows newer than the stamp, only the section's first table -------

stamped_file 3.7.0
run
expect_status 3 "newer rows exit 3"
expect_line '^file: ai/conventions/mockup-design\.md  myspec_version: 3\.7\.0$' "file and stamp"
expect_line '^ask: Q13  writes: ## Motion \(new section\)  \(since 3\.8\.0\)$' "Q13 offered"
expect_line '^ask: Q2  writes: ## Style baseline \(in section\)  \(since 4\.0\.0\)$' "bare number and loose v4.0 read"
expect_no_line 'Q15|Form|ask: Q?X' "forms table and rows outside the section ignored"
expect_line '^mockup-config-check: 2 question\(s\) to ask$' "summary"

stamped_file 3.8.0
run
expect_no_line '^ask: Q13 ' "a row is not newer than its own version"

stamped_file '"v4.0" # quoted, commented'
run
expect_status 0 "quoted loose stamp with a comment reads as 4.0.0"

# One row per question: the newest form of a question changed twice.
table '| Q2 | ## Style baseline (in section) | 3.8.0 |' '| Q2 | ## Style baseline (replaces section) | 3.9.0 |' '| Q13 | ## Motion (new section) | 3.8.0 |'
stamped_file 3.7.0
run
expect_line '^ask: Q2  writes: ## Style baseline \(replaces section\)  \(since 3\.9\.0\)$' "newest Q2 row asked"
if [ "$(grep -c '^ask: Q2 ' <<<"$OUTPUT")" = 1 ]; then ok; else fail "Q2 asked more than once: $OUTPUT"; fi
expect_line '^mockup-config-check: 2 question\(s\) to ask$' "deduped summary"
table '| Q2 | ## Style baseline (in section) | 3.8.0 |' '| Q2 | ## Component library (replaces section) | 3.9.0 |'
run
expect_line '^ask: Q2  writes: ## Style baseline \(in section\)  \(since 3\.8\.0\)$' "a Q2 change to another target is kept"
expect_line '^ask: Q2  writes: ## Component library \(replaces section\)' "and the newer target asked too"
table '| Q2 | ## Style baseline (in section) | 3.8.0 |' '| Q2 | ## Style baseline (replaces section) | 3.9.0 |'
stamped_file 3.7.0
stamped_file 3.8.5
run
expect_line '^ask: Q2  writes: ## Style baseline \(replaces section\)' "only the change after the stamp"

# Blank lines between rows are part of the table.
table '| Q13 | ## Motion (new section) | 3.8.0 |' '' '| Q14 | ## Print (new section) | 3.9.0 |'
stamped_file 3.7.0
run
expect_line '^ask: Q14 ' "a row after a blank line is read"

# An escaped pipe is a literal pipe in its cell.
# shellcheck disable=SC2016 # literal backticks in a markdown row
table '| Q14 | ## Notes \| misc (new section) | 3.9.0 |'
run
expect_status 3 "escaped pipe row readable"
# shellcheck disable=SC2016 # literal backticks in the expected line
expect_line '^ask: Q14  writes: ## Notes \| misc \(new section\)' "escaped pipe unescaped in the Writes cell"

# --- 3. a row it cannot read stops the check ---------------------------------

for bad in 'Q13 | Motion | 3.8.0 |' 'Some prose after the table.' '| Q13 | Motion | soon |' '| Q13 | Motion |' '| Q13 | Motion | 3.8.0 | note |' '| Thirteen | Motion | 3.8.0 |' '| Q13 |  | 3.8.0 |'; do
  table "$bad"
  run
  expect_status 2 "unreadable row exits 2: $bad"
  expect_line 'cannot read the ## Question changes line' "unreadable line named: $bad"
done
# A Writes cell must use a known form.
for bad in '| Q13 | ## Motion (new) | 3.8.0 |' '| Q13 | Motion | 3.8.0 |' '| Q13 | .myspec.json mockups | 3.8.0 |'; do
  table "$bad"
  run
  expect_status 2 "unknown Writes form exits 2: $bad"
  expect_line 'names no known Writes form' "unknown form named: $bad"
done
table '| Q13 | .myspec.json mockups.commands.audit | 3.8.0 |'
stamped_file 3.7.0
run
expect_line '^ask: Q13  writes: \.myspec\.json mockups\.commands\.audit ' "a .myspec.json key form is read"

# A table without its header line would lose its first row.
printf '## Question changes\n\n| Q2 | ## X (new section) | 3.0.0 |\n| Q3 | ## Y (new section) | 3.0.0 |\n' > "$BLUEPRINT"
run
expect_status 2 "a table without its header row exits 2"
expect_line 'must start with its header row' "missing header named"

# A trailing space on the section heading still finds it.
printf '## Question changes \n\n| Question | Writes | Since |\n|---|---|---|\n| Q13 | ## Motion (new section) | 3.8.0 |\n' > "$BLUEPRINT"
stamped_file 3.7.0
run
expect_line '^ask: Q13 ' "heading with a trailing space found"

table '| Q13 | ## Motion (new section) | 3.8.0 |'

# --- 4. unstamped and odd files ----------------------------------------------

printf '# Mockup Design Conventions\n' > "$FILE"
run
expect_status 3 "no frontmatter counts as the base version"
expect_line '^file: .*  myspec_version: unstamped \(counted as 1\.20\.0\)$' "unstamped reported"

printf '\xef\xbb\xbf---\r\nmyspec_version: 4.0.0\r\n---\r\n' > "$FILE"
run
expect_status 0 "BOM and CRLF frontmatter: stamp read"

printf -- '\n\n---\nmyspec_version: 4.0.0\n---\n' > "$FILE"
run
expect_line 'myspec_version: unstamped' "frontmatter must start on line 1"
run --stamp
expect_status 2 "a block after blank lines is refused, never given a second one"
if [ "$(grep -c '^---$' "$FILE")" = 2 ]; then ok; else fail "file changed: $(cat "$FILE")"; fi

printf -- '---\n\nSome intro\n\n---\n\n## Always\n' > "$FILE"
run --stamp
expect_status 2 "a pair of horizontal rules is not frontmatter"
if ! grep -q myspec_version "$FILE"; then ok; else fail "stamp written into the body: $(cat "$FILE")"; fi

printf -- '---\ntitle: x\n---- note\nmyspec_version: 4.0.0\n---\n' > "$FILE"
run
expect_line 'myspec_version: unstamped' "a ---- line is not YAML, so the block is not frontmatter"
printf -- '---\ntitle: x\n--- \n\nbody\n\n---\nmore\n' > "$FILE"
run --stamp
if [ "$(sed -n 3p "$FILE")" = "myspec_version: $PLUGIN_VERSION" ] && [ "$(sed -n 4p "$FILE")" = '--- ' ]; then ok; else fail "stamp not inside a frontmatter closed by '--- ': $(cat "$FILE")"; fi

# --- 5. --stamp writes only the stamp line, with the plugin's version --------

stamped_file 3.0.0
BODY=$(tail -n +4 "$FILE")
run --stamp
expect_status 0 "stamp exits 0"
expect_line "^stamped: ai/conventions/mockup-design\.md  myspec_version: $PLUGIN_VERSION\$" "stamped with the plugin manifest version"
if [ "$(sed -n 3p "$FILE")" = "myspec_version: $PLUGIN_VERSION" ] && [ "$(tail -n +4 "$FILE")" = "$BODY" ]; then ok; else fail "stamp touched more than its line: $(cat "$FILE")"; fi

printf -- '---\ntitle: x\n---\nbody\n' > "$FILE"
run --stamp
expect_file "$(printf -- '---\ntitle: x\nmyspec_version: %s\n---\nbody' "$PLUGIN_VERSION")" "missing stamp key added before the closing ---"

printf '\xef\xbb\xbf---\r\nmyspec_version: 3.0.0\r\n---\r\nbody\n' > "$FILE"
run --stamp
if [ "$(head -c 3 "$FILE" | od -An -tx1 | tr -d ' ')" = efbbbf ]; then ok; else fail "BOM dropped"; fi
if [ "$(grep -c $'\r$' "$FILE")" = 3 ] && grep -q $'^myspec_version: .*\r$' "$FILE"; then ok; else fail "CRLF endings not kept"; fi

printf -- '---\ntitle: x\nbody\n' > "$FILE"
run --stamp
expect_status 2 "an unclosed frontmatter is refused"
expect_line 'no closed frontmatter block' "refusal named"
expect_file "$(printf -- '---\ntitle: x\nbody')" "unclosed frontmatter left untouched"

printf '## Always\nbody\n' > "$FILE"
run --stamp
expect_status 2 "a file without frontmatter is refused, never given a block"
expect_file "$(printf '## Always\nbody')" "file without frontmatter untouched"

# --root defaults to the nearest directory holding .myspec.json.
stamped_file 3.7.0
mkdir -p "$REPO/packages/preview"
OUTPUT=$(cd "$REPO/packages/preview" && node "$SCRIPT" --blueprint "$BLUEPRINT" 2>&1 </dev/null); STATUS=$?
expect_line '^file: ai/conventions/mockup-design\.md  myspec_version: 3\.7\.0$' "found from a subdirectory"

# --- 6. errors -----------------------------------------------------------------

stamped_file 3.0.0
run --stamp 3.9.0
expect_status 2 "--stamp takes no value"
run --bogus x
expect_status 2 "unknown flag exits 2"
run toString x
expect_status 2 "an Object.prototype name is not a flag"
chmod 444 "$FILE"
run --stamp
chmod 644 "$FILE"
expect_status 2 "read-only file exits 2, not a crash"
expect_line '^mockup-config-check: .*(EACCES|permission denied)' "write error named"
cp "$BLUEPRINT" "$REPO/bp.md"
OUTPUT=$(cd "$ROOT" && node "$SCRIPT" --root proj --blueprint bp.md 2>&1 </dev/null); STATUS=$?
expect_line '^file: ai/conventions/mockup-design\.md ' "--blueprint resolves against --root, like --file"
rm "$REPO/bp.md"
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

grep -q '^## Question changes$' "$REAL_BLUEPRINT" && ok || fail "shipped blueprint lost its Question changes heading"

printf '\nmockup-config-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
