#!/usr/bin/env bash
# overdue-stubs.sh: list the retirement stubs that have outlived their one
# minor cycle. Maintainer tooling, not shipped: run by the /release skill as
# its stub gate, Step 2 (RELEASING.md "Breaking changes", "Retirement stubs").
#
# A stub is a skills/<name>/SKILL.md whose frontmatter has
# `disable-model-invocation: true` and which says "Retired in myspec X.Y" (its
# description) or carries a "Remove this stub" note (the 2.0 stubs). Either
# alone makes it a stub; a manual-only skill with neither is not one. Its
# retirement version is that X.Y, or the one in "Remove this stub one minor
# cycle after X.Y".
#
# Rule: a stub retired in X.Y ships for one minor cycle after that release and
# is deleted in the next. Cutting X.(Y+1).0 it is "due" (delete it next);
# cutting X.(Y+2).0 or later, or a higher major, it is "overdue".
#
# Usage: scripts/overdue-stubs.sh --version X.Y.Z [--root <repo>]
#
# Output: one line per stub, "<state>\t<name>\tretired <X.Y>". Exit 0 when no
# stub is overdue, 1 when one is, 2 on bad usage or a stub whose retirement
# version cannot be read.
#
# bash 3.2 compatible (macOS /bin/bash).

set -uo pipefail

VERSION="" ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "overdue-stubs: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || { echo "overdue-stubs: --version X.Y.Z is required" >&2; exit 2; }
CUT_MAJOR="${BASH_REMATCH[1]}" CUT_MINOR="${BASH_REMATCH[2]}"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$ROOT/skills" ] || { echo "overdue-stubs: no skills/ under $ROOT" >&2; exit 2; }

# frontmatter <file>: the first --- block, for the manual-only flag.
frontmatter() { awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"; }

# retired_version <file>: X.Y from the description, else from the removal note.
retired_version() {
  local v
  v=$(grep -o 'Retired in myspec [0-9][0-9]*\.[0-9][0-9]*' "$1" | head -1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*$')
  [ -n "$v" ] || v=$(grep -o 'Remove this stub one minor cycle after [0-9][0-9]*\.[0-9][0-9]*' "$1" | head -1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*$')
  printf '%s' "$v"
}

overdue=0 unreadable=0
for f in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  frontmatter "$f" | grep -q '^disable-model-invocation: *true *$' || continue
  grep -q 'Retired in myspec\|Remove this stub' "$f" || continue
  name=$(basename "$(dirname "$f")")
  v=$(retired_version "$f")
  if [ -z "$v" ]; then
    echo "overdue-stubs: $name: no \"Retired in myspec X.Y\" in its description (the retirement version)" >&2
    unreadable=1
    continue
  fi
  major="${v%%.*}" minor="${v#*.}"
  if [ "$CUT_MAJOR" -gt "$major" ] || { [ "$CUT_MAJOR" -eq "$major" ] && [ "$CUT_MINOR" -ge $((minor + 2)) ]; }; then
    state=overdue; overdue=1
  elif [ "$CUT_MAJOR" -eq "$major" ] && [ "$CUT_MINOR" -eq $((minor + 1)) ]; then
    state=due
  else
    state=shipping
  fi
  printf '%s\t%s\tretired %s\n' "$state" "$name" "$v"
done

[ "$unreadable" = 0 ] || exit 2
exit "$overdue"
