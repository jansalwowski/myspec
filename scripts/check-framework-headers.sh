#!/usr/bin/env bash
# check-framework-headers.sh
# Fails when a framework file (framework-files/**/*.md) breaks a header rule.
#
#   1. Frontmatter (no history needed). Every file needs a `---` block on
#      line 1 with an identity field and a temporal field:
#      lib/content-checks.sh `frontmatter_issues`, the validator
#      validate-frontmatter.sh applies to a project's ${aiDir} docs. A rule or
#      doc (any file outside framework-files/templates/) also needs the header
#      its siblings carry: `title`, `purpose` and `updated`. The memory and
#      session templates carry their own fields (id, type, created, ...).
#      An `updated:` must be a real YYYY-MM-DD date, no later than tomorrow
#      (UTC; tomorrow covers authors ahead of UTC).
#   2. Dates against a base (only with --base). A file whose content differs
#      from the merge base of <ref> and HEAD must carry a later `updated:`
#      than the base's. The same date passes only when the base's is already
#      yesterday or later (UTC): the file was dated on the day of this change.
#      A file new since the base, or with no `updated:` there, is not compared.
#
# Why: rules/visual-questions.md started as a template the setup blueprint
# wrote, moved into framework-files/ without a header, and shipped that way
# through several releases (#460). And `updated:` is written by hand, so
# edits landed without it (#462): `update` copies the header as
# framework-owned, every project got a date older than its content, a doctor
# pass flagged it as stale, and the project could not fix it. Nothing checked
# framework-files/: rules install to .claude/rules/, and the frontmatter hook
# judges only what an agent writes into the aiDir.
#
# Rule 2 compares file content with the base, never commit dates, so the way
# a PR is merged (merge commit, squash, rebase) cannot change its verdict.
# With no --base it does not run. Its merge base needs history, so in a
# shallow clone rule 2 refuses (exit 2) and rule 1 still runs.
#
# Repo-only check (CI runs it from scripts/tests/framework-headers.test.sh,
# with --base origin/<the PR's base branch>).
#
# Usage: scripts/check-framework-headers.sh [--base <ref>] [repo root]
#        (default root: this repo)
# Exit 0 clean; 1 a finding; 2 a command failed or the clone is shallow.

set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# content-checks.sh is sourced after hook-core.sh (its header says so).
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/content-checks.sh
. "$LIB/content-checks.sh"

BASE=""
if [ "${1:-}" = "--base" ]; then
  [ $# -ge 2 ] || { echo "usage: $0 [--base <ref>] [repo root]"; exit 2; }
  BASE="$2"
  shift 2
fi
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# -z: paths come out raw, not C-quoted (core.quotePath). In a pathspec `*`
# also matches `/`, so this one pattern covers every depth.
git ls-files -z -- 'framework-files/*.md' > "$TMP/files" || { echo "ERROR: git ls-files failed under $ROOT"; exit 2; }
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < "$TMP/files"
[ "${#files[@]}" -gt 0 ] || { echo "no framework-files/*.md tracked under $ROOT"; exit 2; }

status=0
finding() { printf '%s: %s\n' "$1" "$2"; [ "$status" -eq 2 ] || status=1; }
error() { echo "ERROR $1"; status=2; }

# utc_day <days from today> -> YYYY-MM-DD (GNU date, then BSD date).
utc_day() {
  local t=$(( $(date -u +%s) + $1 * 86400 ))
  date -u -d "@$t" +%Y-%m-%d 2>/dev/null || date -u -r "$t" +%Y-%m-%d
}
# valid_day <YYYY-MM-DD>: a real calendar day.
valid_day() {
  [[ "$1" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]})) max
  case "$m" in
    1|3|5|7|8|10|12) max=31 ;;
    4|6|9|11) max=30 ;;
    2) max=28; if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then max=29; fi ;;
    *) return 1 ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$max" ]
}
# updated_of <frontmatter> -> the first `updated:` value, quotes stripped;
# nothing when there is no `updated:` line. 2 when grep fails.
updated_of() {
  local line rc=0
  line=$(grep -m 1 -E '^updated:' <<< "$1") || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && return 0; return 2; }
  line=${line#updated:}
  line=${line//$'\r'/}
  line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^[\"']\\(.*\\)[\"']\$/\\1/")
  printf '%s' "$line"
}

TOMORROW=$(utc_day 1) || { echo "ERROR: date failed"; exit 2; }
YESTERDAY=$(utc_day -1) || { echo "ERROR: date failed"; exit 2; }

# Rule 2 setup: the files whose content differs from the merge base.
changed=$'\n'
mb=""
if [ -n "$BASE" ]; then
  shallow=$(git rev-parse --is-shallow-repository) || exit 2
  if [ "$shallow" != false ]; then
    echo "shallow clone: the updated: check against $BASE needs full history (fetch-depth: 0); only the frontmatter rule ran"
    status=2
  elif ! mb=$(git merge-base "$BASE" HEAD); then
    error "no merge base of $BASE and HEAD"
    mb=""
  elif git diff -z --name-only "$mb" -- 'framework-files/*.md' > "$TMP/changed"; then
    while IFS= read -r -d '' f; do changed="$changed$f"$'\n'; done < "$TMP/changed"
  else
    error "git diff against $mb failed"
    mb=""
  fi
fi

for f in "${files[@]}"; do
  rc=0
  issues=$(frontmatter_issues "$f") || rc=$?
  [ "$rc" -eq 0 ] || { error "$f: could not read its frontmatter"; continue; }
  if [ -n "$issues" ]; then
    while IFS= read -r l; do finding "$f" "$l"; done <<< "$issues"
    continue
  fi
  fm=$(frontmatter_region "$f") || { error "$f: could not read its frontmatter"; continue; }
  case "$f" in
    framework-files/templates/*) ;;
    *)
      rc=0
      for key in title purpose updated; do
        out=$(_need_line "^$key:" "$fm" "missing '$key' (rules and docs carry title, purpose and updated)") || rc=$?
        [ -z "$out" ] || finding "$f" "$out"
      done
      [ "$rc" -eq 0 ] || { error "$f: could not read its frontmatter"; continue; }
      ;;
  esac
  updated=$(updated_of "$fm") || { error "$f: could not read its updated:"; continue; }
  [ -n "$updated" ] || continue
  if ! valid_day "$updated"; then
    finding "$f" "updated: '$updated' is not a real YYYY-MM-DD date"
    continue
  fi
  if [[ "$updated" > "$TOMORROW" ]]; then
    finding "$f" "updated: $updated is in the future"
    continue
  fi

  # Rule 2.
  [ -n "$mb" ] || continue
  case "$changed" in *$'\n'"$f"$'\n'*) ;; *) continue ;; esac
  git cat-file -e "$mb:$f" 2>/dev/null || continue
  git show "$mb:$f" > "$TMP/base.md" || { error "$f: git show $mb failed"; continue; }
  base_fm=$(frontmatter_region "$TMP/base.md") || { error "$f: could not read its base frontmatter"; continue; }
  was=$(updated_of "$base_fm") || { error "$f: could not read its base updated:"; continue; }
  valid_day "$was" || continue
  if [[ "$updated" < "$was" ]]; then
    finding "$f" "updated: $updated is earlier than $was on $BASE"
  elif [ "$updated" = "$was" ] && [[ "$was" < "$YESTERDAY" ]]; then
    finding "$f" "changed since $BASE, but updated: still says $was; set it to the day of the change"
  fi
done

if [ "$status" -eq 1 ]; then
  echo
  echo "Every framework file starts with frontmatter; rules and docs carry the header their siblings carry (title, purpose, updated),"
  echo "and a change to one sets its updated: to the day of the change."
fi
[ "$status" -ne 0 ] || echo "OK: every framework file has a valid header${BASE:+, and every one changed since $BASE has a new updated:}"
exit "$status"
