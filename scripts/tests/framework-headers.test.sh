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

# An untracked file is not shipped and is not judged.
git -C "$FIX" rm -q --cached framework-files/rules/bare.md
run
expect_eq "$STATUS" 0 "untracked files are skipped"

# This repo.
OUTPUT=$(bash "$SCRIPT" 2>&1); STATUS=$?
expect_eq "$STATUS" 0 "this repo's framework files all have frontmatter: $OUTPUT"

echo "framework-headers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
