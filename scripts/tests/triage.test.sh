#!/usr/bin/env bash
# Regression fixture for scripts/triage/: the title classifier the
# issue-triage workflow runs on every opened issue, and the label sync.
#
# The classifier labels real issues without review, so a false area label is
# worse than none: each case pairs a title that must match with a look-alike
# that must not. The sync script runs against a fake gh that records calls.
#
# Usage: triage.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
CLASSIFY="$REPO_ROOT/scripts/triage/area-labels.mjs"
SYNC="$REPO_ROOT/scripts/triage/sync-labels.sh"

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect_eq() { if [ "$1" = "$2" ]; then ok; else fail "$3 (got: $(printf %q "$1"), want: $(printf %q "$2"))"; fi; }

# ── area-labels.mjs ──────────────────────────────────────────────────────────

FIX="$TMP/repo"
mkdir -p "$FIX/skills/feature-plan" "$FIX/skills/doctor" "$FIX/skills/code-review" "$FIX/skills/feature-status-audit" \
  "$FIX/hooks" "$FIX/lib/feature-status-audit"
touch "$FIX/skills/feature-plan/SKILL.md" "$FIX/skills/doctor/SKILL.md" "$FIX/skills/code-review/SKILL.md" \
  "$FIX/skills/feature-status-audit/SKILL.md" "$FIX/hooks/verify-before-stop.sh" "$FIX/lib/setup-doctor.mjs"
# A skills/ directory without SKILL.md is not a skill.
mkdir -p "$FIX/skills/stale"

classify() { node "$CLASSIFY" --root "$FIX" "$@" | flat; }
flat() { tr '\n' ' ' | sed 's/ $//'; }

expect_eq "$(classify 'feature-plan: group small tasks')" "area:skills status:needs-triage" "skill before the colon"
expect_eq "$(classify 'verify-before-stop: cap leaves a check running')" "area:hooks status:needs-triage" "hook named without .sh"
expect_eq "$(classify 'setup-doctor wiring ignores the matcher')" "area:lib status:needs-triage" "lib helper as first word, no colon"
expect_eq "$(classify 'feature-plan/verify-before-stop: two components')" "area:skills area:hooks status:needs-triage" "components joined by /"
expect_eq "$(classify 'feature-status-audit misses drift')" "area:skills area:lib status:needs-triage" "a name that is both a skill and a lib dir"
expect_eq "$(classify 'doctor findings (2.6.0): several things')" "area:skills status:needs-triage" "parenthesised version in the prefix"
expect_eq "$(classify '`verify-before-stop.sh`: backticked file name')" "area:hooks status:needs-triage" "backticks and extension stripped"
expect_eq "$(classify 'Remove the code-review skill')" "status:needs-triage" "a component mid-sentence is not the subject"
expect_eq "$(classify 'Isolation decision leaks: wrong session id')" "status:needs-triage" "prose prefix names nothing"
expect_eq "$(classify 'stale: not a skill')" "status:needs-triage" "skills/<x>/ without SKILL.md"
expect_eq "$(classify 'Feature-plan: capitalised')" "status:needs-triage" "tokens are matched case-sensitively like the tree"
expect_eq "$(classify --existing 'type:bug,status:ready' 'feature-plan: x')" "area:skills" "existing status label suppresses needs-triage"
expect_eq "$(classify --existing 'type:bug' 'feature-plan: x')" "area:skills status:needs-triage" "a non-status label does not"

node "$CLASSIFY" --root "$FIX" >/dev/null 2>&1
expect_eq "$?" "2" "no title is a usage error"
node "$CLASSIFY" --root "$FIX" a b >/dev/null 2>&1
expect_eq "$?" "2" "two titles is a usage error"

# The real repo: titles of issues that shipped, so the tree lookup keeps working.
expect_eq "$(node "$CLASSIFY" 'mark-code-changed.sh marks read-only Bash commands' | flat)" "area:hooks status:needs-triage" "real hook"
expect_eq "$(node "$CLASSIFY" 'memory-doctor duplicate-id: a memory deleted' | flat)" "area:lib status:needs-triage" "real lib .mjs"

# ── sync-labels.sh ───────────────────────────────────────────────────────────

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "label list" ]; then printf '%s\n' $FAKE_LABELS; exit 0; fi
printf '%s\n' "$*" >> "$GH_LOG"
[ -z "${GH_FAIL:-}" ] || exit 1
SH
chmod +x "$BIN/gh"
sync() { : > "$TMP/gh.log"; PATH="$BIN:$PATH" GH_LOG="$TMP/gh.log" bash "$SYNC" "$@" >/dev/null 2>&1; STATUS=$?; }

FAKE_LABELS="bug breaking wontfix area:skills" sync --prune
LOG=$(cat "$TMP/gh.log")
grep -q '^label edit bug --name type:bug ' <<<"$LOG" && ok || fail "renamedFrom renames the old label in place"
grep -q '^label create type:bug ' <<<"$LOG" && fail "a renamed label must not also be created" || ok
grep -q '^label edit breaking --color' <<<"$LOG" && ok || fail "existing label is updated, not recreated"
grep -q '^label edit area:skills --color' <<<"$LOG" && ok || fail "existing new-style label is updated"
grep -q '^label create area:hooks ' <<<"$LOG" && ok || fail "missing label is created"
grep -q '^label delete wontfix --yes' <<<"$LOG" && ok || fail "--prune deletes a label not in labels.json"
grep -q '^label delete bug' <<<"$LOG" && fail "--prune must not delete a label it just renamed" || ok
expect_eq "$STATUS" "0" "sync exits 0 when every call succeeds"

FAKE_LABELS="wontfix" sync
grep -q '^label delete' "$TMP/gh.log" && fail "no deletes without --prune" || ok

FAKE_LABELS="" GH_FAIL=1 sync
expect_eq "$STATUS" "1" "a failed gh call exits 1"

FAKE_LABELS="" sync --bogus
expect_eq "$STATUS" "2" "unknown flag is a usage error"

# ── tracker-check.sh ─────────────────────────────────────────────────────────

TRACK="$REPO_ROOT/scripts/triage/tracker-check.sh"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/r/issues/"*"/parent")
    [ -n "${FAKE_PARENT:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [ "$FAKE_PARENT" != "error" ] || { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    printf '%s\n' "$FAKE_PARENT" ;;
  *"/sub_issues"*) printf '%b' "${FAKE_SUBS:-}" ;;
  *"/labels --jq"*) printf '%b' "${FAKE_PLABELS:-}" ;;
  *) printf '%s\n' "$*" >> "$GH_LOG" ;;
esac
SH
chmod +x "$BIN/gh"
track() { : > "$TMP/gh.log"; OUTPUT=$(PATH="$BIN:$PATH" GH_LOG="$TMP/gh.log" bash "$TRACK" "$@" --repo o/r 2>&1); STATUS=$?; LOG=$(cat "$TMP/gh.log"); }
OPENP='{"number":152,"state":"open"}'

FAKE_PARENT="" track 158
expect_eq "$STATUS" "0" "no parent (404) exits 0"
expect_eq "$LOG" "" "no parent writes nothing"

FAKE_PARENT=error track 158
expect_eq "$STATUS" "1" "a non-404 parent lookup failure exits 1"

FAKE_PARENT="$OPENP" FAKE_SUBS='158 closed\n159 open\n' track 158
expect_eq "$LOG" "" "an open sibling leaves the parent alone"

FAKE_PARENT='{"number":152,"state":"closed"}' FAKE_SUBS='158 closed\n' track 158
expect_eq "$LOG" "" "a closed parent is left alone"

FAKE_PARENT="$OPENP" FAKE_SUBS='158 closed\n159 closed\n' FAKE_PLABELS='type:bug\nstatus:blocked\nP1\n' track 159
expect_eq "$STATUS" "0" "re-queue exits 0"
grep -q '^issue comment 152 --repo o/r --body All sub-issues are closed (#158 #159)' <<<"$LOG" && ok || fail "re-queue comments on the parent with the closed children"
grep -q '^issue edit 152 --repo o/r --add-label status:needs-triage --remove-label status:blocked$' <<<"$LOG" && ok || fail "re-queue swaps status:blocked for status:needs-triage"
grep -q 'issue close' <<<"$LOG" && fail "tracker-check must never close the parent" || ok

FAKE_PARENT="$OPENP" FAKE_SUBS='158 closed\n' FAKE_PLABELS='status:ready\n' track 158
grep -q -- '--remove-label status:ready$' <<<"$LOG" && ok || fail "any other status label is swapped out too"

FAKE_PARENT="$OPENP" FAKE_SUBS='158 closed\n' FAKE_PLABELS='status:needs-triage\n' track 158
expect_eq "$LOG" "" "an already queued parent gets no second comment"

track
expect_eq "$STATUS" "2" "missing issue number is a usage error"

printf 'triage: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
