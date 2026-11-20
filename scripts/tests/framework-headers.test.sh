#!/usr/bin/env bash
# Regression fixture for scripts/check-framework-headers.sh. rules/
# visual-questions.md shipped with no frontmatter for several releases because
# nothing checked framework-files/ (#460), and framework docs changed without
# their `updated:` changing (#462). This keeps the check honest on fixture
# repos and runs it on this repo, so CI fails on the next one.
#
# Usage: framework-headers.test.sh

set -uo pipefail
# Fixture commits must not depend on the developer's git config (signing).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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
# run_base: the same, against the `base` branch (rule 2).
run_base() { OUTPUT=$(bash "$SCRIPT" --base base "$FIX" 2>&1); STATUS=$?; }

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

# Nothing committed yet: rule 1 needs no history, so a staged file passes.
run
expect_eq "$STATUS" 0 "a repo with no commits passes rule 1: $OUTPUT"

# Dates that are not dates, or in the future, fail without any history.
sethdr() { printf -- '---\ntitle: "G"\npurpose: "p"\nupdated: %s\n---\n%s\n' "$2" "${3:-}" | file "$1"; }
sethdr rules/good.md 2026-13-40
run
expect_eq "$STATUS" 1 "a month 13 fails"
expect_has "$OUTPUT" "framework-files/rules/good.md: updated: '2026-13-40' is not a real YYYY-MM-DD date" "names the bad date"
sethdr rules/good.md 2026-02-29
run
expect_eq "$STATUS" 1 "Feb 29 in a common year fails"
sethdr rules/good.md 2099-01-01
run
expect_eq "$STATUS" 1 "a future date fails"
expect_has "$OUTPUT" "updated: 2099-01-01 is in the future" "says it is in the future"
sethdr rules/good.md 2028-02-29
run
expect_has "$OUTPUT" "2028-02-29 is in the future" "Feb 29 in a leap year is a real date"
# An `updated:` below the frontmatter is body text, not the date.
sethdr rules/good.md '"2026-11-01"' 'updated: 2099-01-01'
run
expect_eq "$STATUS" 0 "a quoted date passes and a body updated: is ignored: $OUTPUT"

# commit <YYYY-MM-DD>: commit what is staged, authored and committed that day.
commit() {
  GIT_AUTHOR_DATE="$1T12:00:00+0000" GIT_COMMITTER_DATE="$1T12:00:00+0000" \
    git -C "$FIX" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "c $1" \
    || { echo "FATAL: fixture commit failed" >&2; exit 1; }
}
# mark_base: the base branch is what is committed now.
mark_base() { git -C "$FIX" branch -f base HEAD; }

# #462, rule 2: a PR that changes a file must move its updated: past the base's.
sethdr rules/good.md 2026-11-01 'Body.'
commit 2026-11-01
mark_base
sethdr rules/good.md 2026-11-01 'Body, changed.'
commit 2026-11-12
run_base
expect_eq "$STATUS" 1 "a change without an updated: bump fails"
expect_has "$OUTPUT" "framework-files/rules/good.md: changed since base, but updated: still says 2026-11-01" "names the file and the date"
run
expect_eq "$STATUS" 0 "without --base, rule 2 does not run: $OUTPUT"

# Commit dates play no part: a bump passes whatever day the commit carries,
# as on main after a squash merge made on a later day.
sethdr rules/good.md 2026-11-12 'Body, changed.'
commit 2027-03-01
run_base
expect_eq "$STATUS" 0 "a bumped date passes, whatever the commit date: $OUTPUT"

# A date earlier than the base's fails.
sethdr rules/good.md 2026-10-01 'Body, changed.'
commit 2026-11-12
run_base
expect_eq "$STATUS" 1 "a date moved back fails"
expect_has "$OUTPUT" "updated: 2026-10-01 is earlier than 2026-11-01 on base" "says it went back"

# The base already dated today: a second change today keeps the date.
TODAY=$(date -u +%Y-%m-%d)
sethdr rules/good.md "$TODAY" 'Body, today.'
commit 2026-11-12
mark_base
sethdr rules/good.md "$TODAY" 'Body, today, again.'
commit 2026-11-12
run_base
expect_eq "$STATUS" 0 "a same-day change on a file the base dates today passes: $OUTPUT"

# A file new since the base, and a template with no updated:, are not compared.
sethdr rules/new.md 2026-01-01
printf '# body\n' >> "$FIX/framework-files/templates/memory.md"
git -C "$FIX" add framework-files/templates/memory.md
commit 2026-11-20
run_base
expect_eq "$STATUS" 0 "a new file and an undated template are not compared: $OUTPUT"

# A tracked file whose frontmatter cannot be read is an error, not a skip.
mkdir -p "$TMP/bin"
REAL_AWK=$(command -v awk)
cat > "$TMP/bin/awk" <<SH
#!/bin/sh
case "\$1" in *"NR == 1 { if"*) exit 3 ;; esac
exec "$REAL_AWK" "\$@"
SH
chmod +x "$TMP/bin/awk"
OUTPUT=$(PATH="$TMP/bin:$PATH" bash "$SCRIPT" --base base "$FIX" 2>&1); STATUS=$?
expect_eq "$STATUS" 2 "a failing frontmatter_region exits 2"
expect_has "$OUTPUT" "ERROR framework-files/rules/good.md: could not read its frontmatter" "names the file"

# A shallow clone has no merge base: rule 2 refuses, rule 1 still runs.
printf '# no header\n' | file rules/bare.md
commit 2026-11-21
git -C "$FIX" branch -f base HEAD~1
git clone -q --depth 1 --no-single-branch "file://$FIX" "$TMP/shallow" 2>/dev/null
OUTPUT=$(bash "$SCRIPT" --base origin/base "$TMP/shallow" 2>&1); STATUS=$?
expect_eq "$STATUS" 2 "a shallow clone with --base exits 2"
expect_has "$OUTPUT" "shallow clone" "says why"
expect_has "$OUTPUT" "framework-files/rules/bare.md: missing frontmatter block entirely" "rule 1 still reports in a shallow clone"
OUTPUT=$(bash "$SCRIPT" "$TMP/shallow" 2>&1); STATUS=$?
expect_eq "$STATUS" 1 "a shallow clone without --base runs rule 1 alone"

# This repo, against the PR's base branch in CI (main otherwise, when known).
BASE_REF="origin/${GITHUB_BASE_REF:-main}"
if git -C "$REPO_ROOT" rev-parse -q --verify "$BASE_REF^{commit}" >/dev/null; then
  OUTPUT=$(bash "$SCRIPT" --base "$BASE_REF" 2>&1); STATUS=$?
else
  echo "note: $BASE_REF not found; this repo is checked without rule 2"
  OUTPUT=$(bash "$SCRIPT" 2>&1); STATUS=$?
fi
expect_eq "$STATUS" 0 "this repo's framework files have valid headers: $OUTPUT"

echo "framework-headers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
