#!/usr/bin/env bash
# Regression fixture for scripts/check-framework-headers.sh. rules/
# visual-questions.md shipped with no frontmatter for several releases because
# nothing checked framework-files/ (#460). This keeps the check honest on
# fixture repos and runs it on this repo, so CI fails on the next one.
#
# Usage: framework-headers.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/check-framework-headers.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect_eq()  { if [ "$1" = "$2" ]; then ok; else fail "$3 (got: $(printf %q "$1"), want: $(printf %q "$2"))"; fi; }
expect_has() { case "$1" in *"$2"*) ok ;; *) fail "$3 (missing [$2] in: $1)" ;; esac; }
run() { OUTPUT=$(bash "$SCRIPT" "$FIX" 2>&1); STATUS=$?; }

FIX="$TMP/repo"
mkdir -p "$FIX/framework-files/rules" "$FIX/framework-files/templates"
git -C "$FIX" init -q
# file <path>: write stdin to framework-files/<path> and track it.
file() { cat > "$FIX/framework-files/$1"; git -C "$FIX" add "framework-files/$1"; }

file rules/good.md <<'MD'
---
title: "Good"
purpose: "A rule with the sibling header"
updated: 2026-11-01
---

# Good
MD
# A template carries placeholder dates and other identity fields.
file templates/memory.md <<'MD'
---
id: P{NNN}
type: procedural
created: YYYY-MM-DD
---
MD

run
expect_eq "$STATUS" 0 "clean fixture passes"

# The #460 shape: a rule that opens with its heading.
file rules/bare.md <<'MD'
# Bare

| a | b |
|---|---|
MD
run
expect_eq "$STATUS" 1 "a rule with no frontmatter fails"
expect_has "$OUTPUT" "framework-files/rules/bare.md: missing frontmatter block entirely" "names the file and the issue"

# A header without a temporal field fails too.
file rules/bare.md <<'MD'
---
title: "Bare"
---
MD
run
expect_eq "$STATUS" 1 "a header without a temporal field fails"
expect_has "$OUTPUT" "missing temporal field" "names the missing field"

# A rule needs the sibling header, not just any identity and temporal field.
file rules/bare.md <<'MD'
---
name: x
created: 2026-01-01
---
MD
run
expect_eq "$STATUS" 1 "a rule with name and created but no title, purpose, updated fails"
expect_has "$OUTPUT" "framework-files/rules/bare.md: missing 'title'" "names the missing title"
expect_has "$OUTPUT" "framework-files/rules/bare.md: missing 'purpose'" "names the missing purpose"
expect_has "$OUTPUT" "framework-files/rules/bare.md: missing 'updated'" "names the missing updated"

# A `---` block below line 1 is not frontmatter.
file rules/bare.md <<'MD'
# Bare

---
title: "Bare"
purpose: "p"
updated: 2026-11-01
---
MD
run
expect_eq "$STATUS" 1 "a --- block below line 1 fails"
expect_has "$OUTPUT" "framework-files/rules/bare.md: frontmatter must start on line 1" "says it must start on line 1"

# An untracked file is not shipped and is not judged.
git -C "$FIX" rm -q --cached framework-files/rules/bare.md
rm "$FIX/framework-files/rules/bare.md"
run
expect_eq "$STATUS" 0 "untracked files are skipped"

# Paths are read raw: non-ASCII, `&` and `|` print as they are.
good_header() { printf -- '---\ntitle: "G"\npurpose: "p"\nupdated: 2026-11-01\n---\n'; }
good_header | file "rules/zażółć.md"
run
expect_eq "$STATUS" 0 "a non-ASCII path with a header passes: $OUTPUT"
printf '# no header\n' | file "rules/a&b.md"
printf '# no header\n' | file "rules/c|d.md"
run
expect_eq "$STATUS" 1 "headerless files with & and | in the path fail"
expect_has "$OUTPUT" "framework-files/rules/a&b.md: missing frontmatter block entirely" "an & path prints verbatim"
expect_has "$OUTPUT" "framework-files/rules/c|d.md: missing frontmatter block entirely" "a | path prints verbatim"

# A tracked file that cannot be read is an error (2), not a finding (1), even
# when a finding follows it. Here the missing file sorts before the findings.
good_header | file "rules/0-gone.md"
rm "$FIX/framework-files/rules/0-gone.md"
run
expect_eq "$STATUS" 2 "an unreadable file exits 2 even with findings after it"
expect_has "$OUTPUT" "ERROR framework-files/rules/0-gone.md: could not read its frontmatter" "names the unreadable file"
git -C "$FIX" rm -q --cached "framework-files/rules/0-gone.md" "framework-files/rules/a&b.md" "framework-files/rules/c|d.md"
# ...and when a finding comes first.
good_header | file "rules/zz-gone.md"
rm "$FIX/framework-files/rules/zz-gone.md"
printf '# no header\n' | file "rules/a-bare.md"
run
expect_eq "$STATUS" 2 "an unreadable file exits 2 after a finding"
git -C "$FIX" rm -q --cached "framework-files/rules/zz-gone.md" "framework-files/rules/a-bare.md"

# This repo.
OUTPUT=$(bash "$SCRIPT" 2>&1); STATUS=$?
expect_eq "$STATUS" 0 "this repo's framework files all have frontmatter: $OUTPUT"

echo "framework-headers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
