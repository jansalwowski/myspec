#!/usr/bin/env bash
# Tests for lib/mockup-config-check.mjs: update's check of a generated
# ${aiDir}/conventions/mockup-design.md against the framework-owned parts of
# the mockup blueprint's output template (section headings, fixed rows and
# bullets). Missing parts are reported, then patched in with --apply; project
# content, adapted rows and the feedback log are left alone.
#
# Usage: mockup-config-check.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../mockup-config-check.mjs}"
BLUEPRINT="$HERE/../../blueprints/mockup.md"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
FILE="$REPO/ai/conventions/mockup-design.md"
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
expect_in_file() {  # expect_in_file <fixed string> <description>
  if grep -Fq -- "$1" "$FILE"; then ok; else fail "$2 (file lacks: $1)"; fi
}
expect_count() {    # expect_count <fixed string> <n> <description>
  local n
  n=$(grep -Fc -- "$1" "$FILE")
  if [ "$n" = "$2" ]; then ok; else fail "$3 (found $n, want $2: $1)"; fi
}
line_no() { grep -nF -- "$1" "$FILE" | head -1 | cut -d: -f1; }

run() { OUTPUT=$(cd "$REPO" && node "$SCRIPT" --blueprint "$BLUEPRINT" "$@" 2>&1); STATUS=$?; }

mkdir -p "$(dirname "$FILE")"
printf '{"aiDir":"ai"}\n' > "$REPO/.myspec.json"

FRONTMATTER_ROW=$(grep -F '| Frontmatter |' "$BLUEPRINT")
STATES_ROW=$(grep -F '| States & modals |' "$BLUEPRINT")
TOGGLE=$(grep -F -- '- In-page mock state toggle:' "$BLUEPRINT")

# A file generated before the blueprint carried the fixed rows and the toggle
# pattern (as by v3.0), with no Cross-mockup consistency section either.
old_file() {
  cat > "$FILE" <<'MD'
---
title: "Mockup Design Conventions"
updated: 2026-08-03
myspec_version: 3.0.0
---

# Mockup Design Conventions

## Always
| Rule | Detail |
|---|---|
| Tokens | Semantic tokens only on chrome |

## Style baseline
| Rule | Detail |
|---|---|
| Density | Compact tables |

## Imports

### Allowed
| Package | Purpose |
|---|---|
| @corp/ui | components |

### Forbidden
| Package | Why |
|---|---|
| api-client | mockups mirror types inline |

## Data model source
db/schema.sql — copy enum values exactly.

## Component library
@corp/ui — external dependency.
Configured against: @corp/ui@4.2.0

## Detection patterns
- Raw palette classes on chrome · Medium · map to semantic token

## Repeated user feedback

### 2026-08-10 — destructive actions name the entity
- **Why**: users confirmed the wrong record
MD
}

# --- 1. check mode reports what is missing and writes nothing ----------------

old_file
BEFORE=$(cat "$FILE")
run
expect_status 3 "missing parts exit 3"
expect_line '^file: ai/conventions/mockup-design\.md  myspec_version: 3\.0\.0$' "reports the file and its stamp"
expect_line '^missing-section: ## Cross-mockup consistency  ask: Q10$' "missing section names its question"
expect_line '^missing-line: ## Style baseline  \| Frontmatter \|' "missing Frontmatter row"
expect_line '^missing-line: ## Style baseline  \| States & modals \|' "missing States & modals row"
expect_line '^missing-line: ## Detection patterns  - In-page mock state toggle:' "missing toggle pattern"
expect_no_line 'missing-section: ## (Always|Imports|Repeated user feedback)' "present sections are not reported"
expect_line '^mockup-config-check: 4 missing, 0 differ$' "summary"
if [ "$(cat "$FILE")" = "$BEFORE" ]; then ok; else fail "check mode wrote the file"; fi

# --- 2. --apply inserts in place and keeps project content -------------------

run --apply --stamp 3.7.0
expect_status 0 "apply exits 0"
expect_line '^added-section: ## Cross-mockup consistency  ask: Q10$' "apply reports the added section"
expect_line '^stamped: myspec_version 3\.7\.0$' "apply reports the stamp"
expect_in_file 'myspec_version: 3.7.0' "stamp written"
expect_count 'myspec_version:' 1 "stamp replaced, not duplicated"
expect_in_file "$FRONTMATTER_ROW" "Frontmatter row added"
expect_in_file "$STATES_ROW" "States & modals row added"
expect_in_file "$TOGGLE" "toggle pattern added"
expect_in_file '| Density | Compact tables |' "project row kept"
expect_in_file '- Raw palette classes on chrome · Medium · map to semantic token' "project pattern kept"
expect_in_file '### 2026-08-10 — destructive actions name the entity' "feedback log kept"
expect_in_file 'Configured against: @corp/ui@4.2.0' "library pin kept"
# Rows go after the table's last row, inside Style baseline.
if [ "$(line_no '| Density |')" -lt "$(line_no '| Frontmatter |')" ] \
  && [ "$(line_no '| States & modals |')" -lt "$(line_no '## Imports')" ]; then ok; else fail "rows not appended to the Style baseline table"; fi
# The toggle goes first in Detection patterns.
if [ "$(line_no '- In-page mock state toggle:')" -lt "$(line_no '- Raw palette classes')" ]; then ok; else fail "toggle pattern not first"; fi
# The missing section lands in template order: after Component library, before Detection patterns.
if [ "$(line_no 'Configured against:')" -lt "$(line_no '## Cross-mockup consistency')" ] \
  && [ "$(line_no '## Cross-mockup consistency')" -lt "$(line_no '## Detection patterns')" ]; then ok; else fail "section not in template order"; fi

# --- 3. a patched file is clean, and a re-run changes nothing ----------------

AFTER=$(cat "$FILE")
run
expect_status 0 "patched file checks clean"
expect_line '^mockup-config-check: 0 missing, 0 differ$' "clean summary"
run --apply
if [ "$(cat "$FILE")" = "$AFTER" ]; then ok; else fail "re-apply changed the file"; fi

# --- 4. an adapted row is reported as differing, never rewritten -------------

# shellcheck disable=SC2016 # literal backticks in a markdown row
ADAPTED='| Frontmatter | A `<!-- title: … -->` comment block, one `controls:` line per state switch. |'
awk -v row="$ADAPTED" '/^\| Frontmatter \|/{print row; next} {print}' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
run --apply
expect_status 0 "differs alone does not fail"
expect_line '^differs: ## Style baseline  plugin: \| Frontmatter \|' "adapted row reported"
expect_line '^mockup-config-check: 0 added, 1 differ \(left as is\)$' "differs summary"
expect_in_file "$ADAPTED" "adapted row kept"
expect_count '| Frontmatter |' 1 "no second Frontmatter row"

# --- 5. headings in code fences do not count; unstamped file -----------------

cat > "$FILE" <<'MD'
# Mockup Design Conventions

```markdown
## Always
```
MD
run --apply --stamp 3.7.0
expect_status 0 "apply on a sparse file"
expect_line '^file: ai/conventions/mockup-design\.md  myspec_version: unstamped$' "unstamped reported"
expect_line '^added-section: ## Always  ask: Q2, Q3, Q4, Q11$' "fenced heading ignored, range expanded"
expect_line '^added-section: ## Repeated user feedback$' "feedback section added without ask"
expect_no_line '^stamped:' "no frontmatter, no stamp"
expect_in_file '> Append-only log of design corrections' "feedback section body added"
expect_count '## Always' 2 "real Always heading added beside the fenced one"

# --- 6. errors -----------------------------------------------------------------

rm "$FILE"
run
expect_status 4 "missing file exits 4"
run --bogus
expect_status 2 "usage error exits 2"
printf '# no template here\n' > "$ROOT/empty.md"
printf -- '---\n---\n' > "$FILE"
OUTPUT=$(cd "$REPO" && node "$SCRIPT" --blueprint "$ROOT/empty.md" 2>&1); STATUS=$?
expect_status 2 "blueprint without the template exits 2"

printf '\nmockup-config-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
