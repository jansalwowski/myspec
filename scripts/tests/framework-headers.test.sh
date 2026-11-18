#!/usr/bin/env bash
# Regression fixture for scripts/check-framework-headers.sh. rules/
# visual-questions.md shipped with no frontmatter for several releases because
# nothing checked framework-files/ (#460), and framework docs changed without
# their `updated:` changing (#462). This keeps the check honest on fixture
# repos and runs it on this repo, so CI fails on the next one.
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
# commit <YYYY-MM-DD>: commit what is staged, authored at noon that day.
commit() {
  GIT_AUTHOR_DATE="$1T12:00:00+0000" GIT_COMMITTER_DATE="$1T12:00:00+0000" \
    git -C "$FIX" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "c $1"
}

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
commit 2026-11-01

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
rm "$FIX/framework-files/rules/bare.md"
run
expect_eq "$STATUS" 0 "untracked files are skipped"

# #462: a later change that keeps the old date fails.
printf '\nA new line.\n' >> "$FIX/framework-files/rules/good.md"
git -C "$FIX" add framework-files/rules/good.md
commit 2026-11-12
run
expect_eq "$STATUS" 1 "a change without an updated: bump fails"
expect_has "$OUTPUT" "framework-files/rules/good.md: updated: 2026-11-01 predates its last change on 2026-11-12" "names the file and both dates"

# Bumping it on the day of the bump passes, as does a second change that day.
sed -i.bak 's/^updated: 2026-11-01$/updated: 2026-11-15/' "$FIX/framework-files/rules/good.md" && rm "$FIX/framework-files/rules/good.md.bak"
git -C "$FIX" add framework-files/rules/good.md
commit 2026-11-15
printf 'Same day.\n' >> "$FIX/framework-files/rules/good.md"
git -C "$FIX" add framework-files/rules/good.md
commit 2026-11-15
run
expect_eq "$STATUS" 0 "a bumped date passes, a same-day change too: $OUTPUT"

# A quoted date reads the same.
sed -i.bak 's/^updated: 2026-11-15$/updated: "2026-11-15"/' "$FIX/framework-files/rules/good.md" && rm "$FIX/framework-files/rules/good.md.bak"
git -C "$FIX" add framework-files/rules/good.md
commit 2026-11-15
run
expect_eq "$STATUS" 0 "a quoted date passes: $OUTPUT"

# A file with no updated: (the memory templates) has no date to keep.
printf '# body\n' >> "$FIX/framework-files/templates/memory.md"
git -C "$FIX" add framework-files/templates/memory.md
commit 2026-11-20
run
expect_eq "$STATUS" 0 "a file without updated: is not dated: $OUTPUT"

# An `updated:` below the frontmatter is body text, not the date.
file rules/late.md <<'MD'
---
title: "Late"
created: 2026-11-20
---

updated: 2026-01-01
MD
commit 2026-11-20
run
expect_eq "$STATUS" 0 "updated: outside the frontmatter is ignored: $OUTPUT"

# A new file not committed yet has no change date to compare.
file rules/new.md <<'MD'
---
title: "New"
updated: 2026-01-01
---
MD
run
expect_eq "$STATUS" 0 "a staged, uncommitted file is not dated: $OUTPUT"
git -C "$FIX" rm -q --cached framework-files/rules/new.md

# A shallow clone has one commit for every file: refuse rather than guess.
git clone -q --depth 1 "file://$FIX" "$TMP/shallow" 2>/dev/null
OUTPUT=$(bash "$SCRIPT" "$TMP/shallow" 2>&1); STATUS=$?
expect_eq "$STATUS" 2 "a shallow clone exits 2"
expect_has "$OUTPUT" "shallow clone" "says why"

# This repo.
OUTPUT=$(bash "$SCRIPT" 2>&1); STATUS=$?
expect_eq "$STATUS" 0 "this repo's framework files all have frontmatter: $OUTPUT"

echo "framework-headers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
