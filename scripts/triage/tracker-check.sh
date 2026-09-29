#!/usr/bin/env bash
# When an issue closes, check its parent tracker. If every sub-issue of that
# parent is now closed, re-queue the parent for triage: comment, swap its
# status:* label (status:blocked, normally) for status:needs-triage.
#
# It never closes the parent. A tracker can hold sections that were never
# split out (#134 keeps two deferred items), so only /triage decides whether
# anything is left. Runs in .github/workflows/issue-triage.yml on `closed`.
#
# Usage: scripts/triage/tracker-check.sh <closed-issue-number> [--repo owner/name]
# Exit: 0 done or nothing to do, 1 a gh call failed, 2 usage error.

set -uo pipefail

NUMBER=""
REPO="${GITHUB_REPOSITORY:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "tracker-check: --repo needs a value" >&2; exit 2; }; REPO="$2"; shift ;;
    *) [ -z "$NUMBER" ] || { echo "tracker-check: one issue number only" >&2; exit 2; }; NUMBER="$1" ;;
  esac
  shift
done
[[ "$NUMBER" =~ ^[0-9]+$ ]] || { echo "tracker-check: usage: tracker-check.sh <issue-number> [--repo owner/name]" >&2; exit 2; }
[ -n "$REPO" ] || { echo "tracker-check: no repo (pass --repo or set GITHUB_REPOSITORY)" >&2; exit 2; }

# No parent is the common case and answers 404; any other failure is real.
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
if ! PARENT_JSON=$(gh api "repos/$REPO/issues/$NUMBER/parent" 2>"$ERR"); then
  if grep -q 'HTTP 404' "$ERR"; then echo "tracker-check: #$NUMBER has no parent"; exit 0; fi
  cat "$ERR" >&2
  exit 1
fi
PARENT=$(jq -r '.number' <<<"$PARENT_JSON")
PARENT_STATE=$(jq -r '.state' <<<"$PARENT_JSON")
[ "$PARENT_STATE" = "open" ] || { echo "tracker-check: parent #$PARENT is already $PARENT_STATE"; exit 0; }

SUBS=$(gh api --paginate "repos/$REPO/issues/$PARENT/sub_issues?per_page=100" --jq '.[] | "\(.number) \(.state)"') || exit 1
[ -n "$SUBS" ] || { echo "tracker-check: parent #$PARENT lists no sub-issues"; exit 0; }
OPEN=$(awk '$2 != "closed" { printf "#%s ", $1 }' <<<"$SUBS")
if [ -n "$OPEN" ]; then echo "tracker-check: parent #$PARENT still has open sub-issues: $OPEN"; exit 0; fi

LABELS=$(gh api "repos/$REPO/issues/$PARENT/labels" --jq '.[].name') || exit 1
# Already queued: a child closed, reopened and closed again must not repeat the comment.
if grep -Fxq 'status:needs-triage' <<<"$LABELS"; then echo "tracker-check: parent #$PARENT already queued"; exit 0; fi

CLOSED=$(awk '{ printf "#%s ", $1 }' <<<"$SUBS")
gh issue comment "$PARENT" --repo "$REPO" --body "All sub-issues are closed (${CLOSED% }). Re-queued for triage: close this tracker if its mapping comment leaves nothing open, otherwise split or relabel what remains." >/dev/null || exit 1
# Exactly one status:* label: drop whichever the tracker carries.
REMOVE=()
while IFS= read -r l; do
  case "$l" in status:*) REMOVE+=(--remove-label "$l") ;; esac
done <<<"$LABELS"
gh issue edit "$PARENT" --repo "$REPO" --add-label status:needs-triage ${REMOVE[@]+"${REMOVE[@]}"} >/dev/null || exit 1
echo "tracker-check: parent #$PARENT re-queued"
