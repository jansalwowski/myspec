#!/usr/bin/env bash
# check-framework-headers.sh
# Fails when a framework file (framework-files/**/*.md) has
#   1. no valid frontmatter: a `---` block on line 1 with an identity field
#      and a temporal field. The test is lib/content-checks.sh
#      `frontmatter_issues`, the same one validate-frontmatter.sh applies to a
#      project's ${aiDir} docs, so a framework file passes here exactly when
#      `update` could write it into the aiDir.
#   2. an `updated:` date older than the last commit that changed the file
#      (its author date, in the author's timezone: the day they wrote it;
#      merge commits left out).
#      A file with no `updated: YYYY-MM-DD` in its frontmatter (the memory
#      templates) has no date to keep and is skipped.
#
# Why: rules/visual-questions.md started as a template the setup blueprint
# wrote, moved into framework-files/ without a header, and shipped that way
# through several releases (#460). And `updated:` is written by hand, so
# edits landed without it (#462): `update` copies the header as
# framework-owned, every project got a date older than its content, a
# doctor pass flagged it as stale, and the project could not fix it. Nothing
# checked framework-files/: the frontmatter hook covers the aiDir only, and
# .claude/rules/ is outside it.
#
# Rule 2 reads history, so it refuses a shallow clone (exit 2) rather than
# date every file to the clone's one commit. It assumes merge commits, not
# squash merges: a squash commit's author date is the day it was made.
#
# Repo-only check (CI runs it from scripts/tests/framework-headers.test.sh).
#
# Usage: scripts/check-framework-headers.sh [repo root]   (default: this repo)
# Exit 0 clean; 1 a finding; 2 a command failed or the clone is shallow.

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/content-checks.sh
. "$LIB/content-checks.sh"

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

files=$(git ls-files -- 'framework-files/*.md' 'framework-files/**/*.md' | sort -u) || exit 2
[ -n "$files" ] || { echo "no framework-files/**/*.md tracked under $ROOT"; exit 2; }

shallow=$(git rev-parse --is-shallow-repository) || exit 2
[ "$shallow" = false ] || { echo "shallow clone: the updated: check needs full history (fetch-depth: 0)"; exit 2; }

status=0
while IFS= read -r f; do
  rc=0
  issues=$(frontmatter_issues "$f") || rc=$?
  [ "$rc" -eq 0 ] || { echo "ERROR $f: could not read its frontmatter"; status=2; continue; }
  if [ -n "$issues" ]; then
    printf '%s\n' "$issues" | sed "s|^|$f: |"
    [ "$status" -eq 2 ] || status=1
    continue
  fi
  updated=$(frontmatter_region "$f" | sed -n 's/^updated:[[:space:]]*["'"'"']\{0,1\}\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' | head -n 1) # lint: sigpipe-ok
  [ -n "$updated" ] || continue
  # The newest author date among the commits that changed it. Merges are left
  # out: a merge that touches a file changed on both sides (CI's synthetic
  # PR merge among them) carries the day it was made, not the day of an edit.
  log=$(git log --no-merges --date=short --format=%ad -- "$f") || { echo "ERROR $f: git log failed"; status=2; continue; }
  changed=$(printf '%s\n' "$log" | sort | tail -n 1)
  # Added but not committed yet: nothing to compare.
  [ -n "$changed" ] || continue
  if [[ "$updated" < "$changed" ]]; then
    echo "$f: updated: $updated predates its last change on $changed"
    [ "$status" -eq 2 ] || status=1
  fi
done <<< "$files"

if [ "$status" -eq 1 ]; then
  echo
  echo "Every framework file starts with the frontmatter its siblings carry (title, purpose, updated),"
  echo "and a change to one sets its updated: to the day of the change."
fi
[ "$status" -ne 0 ] || echo "OK: every framework file has frontmatter and an updated: no older than its last change"
exit "$status"
