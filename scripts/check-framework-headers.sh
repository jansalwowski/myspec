#!/usr/bin/env bash
# check-framework-headers.sh
# Fails when a framework file (framework-files/**/*.md) has no valid
# frontmatter. Every file needs a `---` block on line 1 with an identity field
# and a temporal field: lib/content-checks.sh `frontmatter_issues`, the
# validator validate-frontmatter.sh applies to a project's ${aiDir} docs.
# A rule or doc (any file outside framework-files/templates/) also needs the
# header its siblings carry: `title`, `purpose` and `updated`. The memory and
# session templates carry their own fields (id, type, created, ...).
#
# Why: rules/visual-questions.md started as a template the setup blueprint
# wrote, moved into framework-files/ without a header, and shipped that way
# through several releases (#460). Nothing checked framework-files/: rules
# install to .claude/rules/, and the frontmatter hook judges only what an
# agent writes into the aiDir.
#
# Repo-only check (CI runs it from scripts/tests/framework-headers.test.sh).
#
# Usage: scripts/check-framework-headers.sh [repo root]   (default: this repo)
# Exit 0 clean; 1 a finding; 2 a command failed.

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# content-checks.sh is sourced after hook-core.sh (its header says so).
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/content-checks.sh
. "$LIB/content-checks.sh"

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

# -z: paths come out raw, not C-quoted (core.quotePath). In a pathspec `*`
# also matches `/`, so this one pattern covers every depth.
list=$(mktemp) || exit 2
git ls-files -z -- 'framework-files/*.md' > "$list" || { rm -f "$list"; echo "ERROR: git ls-files failed under $ROOT"; exit 2; }
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < "$list"
rm -f "$list"
[ "${#files[@]}" -gt 0 ] || { echo "no framework-files/*.md tracked under $ROOT"; exit 2; }

# report <file> <issues>: one "<file>: <issue>" line per issue.
report() {
  local l
  while IFS= read -r l; do printf '%s: %s\n' "$1" "$l"; done <<< "$2"
}

status=0
for f in "${files[@]}"; do
  rc=0
  issues=$(frontmatter_issues "$f") || rc=$?
  [ "$rc" -eq 0 ] || { echo "ERROR $f: could not read its frontmatter"; status=2; continue; }
  if [ -z "$issues" ]; then
    case "$f" in
      framework-files/templates/*) ;;
      *)
        rc=0
        fm=$(frontmatter_region "$f") || rc=$?
        [ "$rc" -eq 0 ] || { echo "ERROR $f: could not read its frontmatter"; status=2; continue; }
        for key in title purpose updated; do
          out=$(_need_line "^$key:" "$fm" "missing '$key' (rules and docs carry title, purpose and updated)") || rc=$?
          [ -z "$out" ] || issues="${issues:+$issues$'\n'}$out"
        done
        [ "$rc" -eq 0 ] || { echo "ERROR $f: could not read its frontmatter"; status=2; continue; }
        ;;
    esac
  fi
  [ -z "$issues" ] && continue
  report "$f" "$issues"
  [ "$status" -eq 2 ] || status=1
done

if [ "$status" -eq 1 ]; then
  echo
  echo "Every framework file starts with frontmatter; rules and docs carry the header their siblings carry (title, purpose, updated)."
fi
[ "$status" -ne 0 ] || echo "OK: every framework file has frontmatter"
exit "$status"
