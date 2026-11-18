#!/usr/bin/env bash
# check-framework-headers.sh
# Fails when a framework file (framework-files/**/*.md) has no valid
# frontmatter: a `---` block on line 1 with an identity field and a temporal
# field. The test is lib/content-checks.sh `frontmatter_issues`, the same one
# validate-frontmatter.sh applies to a project's ${aiDir} docs, so a framework
# file passes here exactly when `update` could write it into the aiDir.
#
# Why: rules/visual-questions.md started as a template the setup blueprint
# wrote, moved into framework-files/ without a header, and shipped that way
# through several releases (#460). Nothing checked framework-files/: the
# frontmatter hook covers the aiDir only, and .claude/rules/ is outside it.
#
# Repo-only check (CI runs it from scripts/tests/framework-headers.test.sh).
#
# Usage: scripts/check-framework-headers.sh [repo root]   (default: this repo)
# Exit 0 clean; 1 a finding; 2 a command failed.

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=lib/content-checks.sh
. "$LIB/content-checks.sh"

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

files=$(git ls-files -- 'framework-files/*.md' 'framework-files/**/*.md' | sort -u) || exit 2
[ -n "$files" ] || { echo "no framework-files/**/*.md tracked under $ROOT"; exit 2; }

status=0
while IFS= read -r f; do
  rc=0
  issues=$(frontmatter_issues "$f") || rc=$?
  [ "$rc" -eq 0 ] || { echo "ERROR $f: could not read its frontmatter"; status=2; continue; }
  [ -z "$issues" ] && continue
  printf '%s\n' "$issues" | sed "s|^|$f: |"
  [ "$status" -eq 2 ] || status=1
done <<< "$files"

if [ "$status" -eq 1 ]; then
  echo
  echo "Every framework file starts with the frontmatter its siblings carry (title, purpose, updated)."
fi
[ "$status" -ne 0 ] || echo "OK: every framework file has frontmatter"
exit "$status"
