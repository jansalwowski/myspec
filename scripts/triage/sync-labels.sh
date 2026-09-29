#!/usr/bin/env bash
# Make the repo's GitHub labels match .github/labels.json.
#
# Creates missing labels and updates colour and description on existing ones.
# An entry with `renamedFrom` renames the old label in place, so the issues
# and PRs that carry it keep it under the new name. The release skill's
# breaking gate reads the `breaking` label by name; keep that entry as is.
#
# Usage: scripts/triage/sync-labels.sh [--dry-run] [--prune] [--repo owner/name]
#   --dry-run  print the gh commands instead of running them
#   --prune    also delete labels that are not in labels.json
# Exit: 0 in sync, 1 a gh call failed, 2 usage error.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILE="$HERE/../../.github/labels.json"
DRY=0
PRUNE=0
REPO_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --prune) PRUNE=1 ;;
    --repo) [ $# -ge 2 ] || { echo "sync-labels: --repo needs a value" >&2; exit 2; }; REPO_ARGS=(--repo "$2"); shift ;;
    *) echo "sync-labels: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo "sync-labels: jq is required" >&2; exit 2; }
jq -e 'type == "array"' "$FILE" >/dev/null || { echo "sync-labels: $FILE is not a JSON array" >&2; exit 2; }

# ${arr[@]+...} keeps an empty array from tripping set -u on bash 3.2.
if ! CURRENT=$(gh label list ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --limit 500 --json name --jq '.[].name'); then
  echo "sync-labels: gh label list failed" >&2
  exit 1
fi
has() { grep -Fxq -- "$1" <<<"$CURRENT"; }

STATUS=0
run() {
  if [ "$DRY" -eq 1 ]; then printf 'gh'; printf ' %q' "$@"; printf '\n'; return 0; fi
  gh "$@" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} || { echo "sync-labels: failed: gh $*" >&2; STATUS=1; }
}

WANTED=""
while IFS=$'\t' read -r name color desc from; do
  WANTED+="$name"$'\n'
  if has "$name"; then
    run label edit "$name" --color "$color" --description "$desc"
  elif [ -n "$from" ] && has "$from"; then
    run label edit "$from" --name "$name" --color "$color" --description "$desc"
  else
    run label create "$name" --color "$color" --description "$desc"
  fi
done < <(jq -r '.[] | [.name, .color, .description, (.renamedFrom // "")] | @tsv' "$FILE")

if [ "$PRUNE" -eq 1 ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -Fxq -- "$name" <<<"$WANTED" && continue
    # A label renamed above no longer exists under its old name.
    jq -e --arg n "$name" 'any(.[]; .renamedFrom == $n)' "$FILE" >/dev/null && continue
    run label delete "$name" --yes
  done <<<"$CURRENT"
fi
exit $STATUS
