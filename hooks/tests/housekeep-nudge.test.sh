#!/usr/bin/env bash
# Regression fixture for the SessionStart hook housekeep-nudge.sh.
#
# The hook runs before every session, so it must stay quiet unless the
# sweep is overdue: nothing outside a myspec project, nothing on the first
# session (it starts the clock instead), one systemMessage line after 7 days.
#
# Usage: housekeep-nudge.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${1:-$HERE/../housekeep-nudge.sh}"
[ -f "$HOOK" ] || { echo "FATAL: hook not found: $HOOK" >&2; exit 1; }
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"
PLAIN="$ROOT/plain"
git init -q -b main "$REPO"
git init -q -b main "$PLAIN"
echo '{ "aiDir": ".ai" }' > "$REPO/.myspec.json"
STAMP="$REPO/.claude/state/housekeep-last-run"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# run_in <dir>: sets OUT and STATUS
run_in() {
  OUT=$(jq -cn --arg c "$1" '{session_id:"s1",cwd:$c,hook_event_name:"SessionStart",source:"startup"}' | bash "$HOOK" 2>/dev/null)
  STATUS=$?
}

run_in "$PLAIN"
[ "$STATUS" -eq 0 ] && [ -z "$OUT" ] && ok || fail "not a myspec project: silent, exit 0 (got $STATUS: $OUT)"
[ ! -e "$PLAIN/.claude" ] && ok || fail "not a myspec project: writes nothing"

run_in "$REPO"
[ "$STATUS" -eq 0 ] && [ -z "$OUT" ] && ok || fail "no stamp: silent (got: $OUT)"
[ -f "$STAMP" ] && ok || fail "no stamp: the first session writes one"

run_in "$REPO"
[ -z "$OUT" ] && ok || fail "fresh stamp: silent (got: $OUT)"

echo $(( $(date +%s) - 6 * 86400 )) > "$STAMP"
run_in "$REPO"
[ -z "$OUT" ] && ok || fail "6 days: silent (got: $OUT)"

echo $(( $(date +%s) - 9 * 86400 )) > "$STAMP"
run_in "$REPO"
MSG=$(printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null)
printf '%s' "$MSG" | grep -qF '9 days ago' && ok || fail "9 days: names the age (got: $OUT)"
printf '%s' "$MSG" | grep -qF '/myspec:housekeep' && ok || fail "9 days: names the skill"
[ "$STATUS" -eq 0 ] && ok || fail "9 days: exits 0"

echo garbage > "$STAMP"
run_in "$REPO"
printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null | grep -qF 'no readable record' && ok || fail "unreadable stamp: says so rather than inventing an age (got: $OUT)"

# A linked worktree reads the main checkout's stamp.
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$ROOT/wt" -b feat
echo $(( $(date +%s) - 8 * 86400 )) > "$STAMP"
run_in "$ROOT/wt"
printf '%s' "$OUT" | grep -qF '8 days ago' && ok || fail "worktree: reads the main checkout's stamp (got: $OUT)"
[ ! -e "$ROOT/wt/.claude/state/housekeep-last-run" ] && ok || fail "worktree: writes no stamp of its own"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
