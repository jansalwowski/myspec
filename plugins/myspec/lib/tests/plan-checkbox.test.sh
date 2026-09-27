#!/usr/bin/env bash
# Regression fixture for plan-checkbox.sh.
#
# Issue #93: a controller flipped plan checkboxes with an ad-hoc index script
# that matched `### Milestone 2` and the `| 2 | Task 2: ... |` rows of the
# Execution Order table, and corrupted the plan. The property under test: a
# flip touches only the checkbox lines of the addressed task's own section —
# never a table row, a milestone section, a barrier, a sibling task whose
# number shares a prefix (Task 1 vs Task 10), or a fenced code sample — and a
# failed lookup leaves the file byte-identical.
#
# Usage: plan-checkbox.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../plan-checkbox.sh}"
FIXTURE="$HERE/fixtures/plan-checkbox/plan.md"

if [ ! -x "$SCRIPT" ]; then
  echo "FATAL: script not executable: $SCRIPT" >&2
  exit 1
fi

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PLAN="$ROOT/plan.md"

PASS=0
FAIL=0

ok() {  # ok <condition-desc> <0|1>
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$1" >&2
  fi
}

fresh() { cp "$FIXTURE" "$PLAN"; }

# Line numbers (space-separated) where the plan differs from the fixture.
changed_lines() {
  awk 'NR == FNR { a[FNR] = $0; next } a[FNR] != $0 { printf "%s%d", sep, FNR; sep = " " }' \
    "$FIXTURE" "$PLAN"
}

line_of() {  # line_of <fixed string> — first matching line number in the fixture
  grep -nF -- "$1" "$FIXTURE" | head -1 | cut -d: -f1
}

TODAY=$(date +%F)
FM=$(line_of 'last_updated:')

# --- Task 2: section ends at the next task; the Execution Order row, the fenced
# fake heading, and the barrier's "Merge Task 2" line are left alone ------------
fresh
"$SCRIPT" "$PLAN" 2 doing >/dev/null; ok "set Task 2 doing exits 0" $?
T2A=$(grep -nF -- '- [ ] **Step 1: Write the failing test**' "$FIXTURE" | sed -n 2p | cut -d: -f1)
T2B=$(grep -nF -- '- [ ] **Step 2: Implement**' "$FIXTURE" | sed -n 2p | cut -d: -f1)
[ "$(changed_lines)" = "$FM $T2A $T2B" ]; ok "Task 2 doing changes only its two steps and last_updated (got: $(changed_lines))" $?
grep -qxF "last_updated: $TODAY" "$PLAN"; ok "last_updated is bumped to today" $?
[ "$(sed -n "${T2A}p" "$PLAN")" = '- [~] **Step 1: Write the failing test**' ]; ok "Task 2 step 1 reads [~]" $?
[ "$("$SCRIPT" "$PLAN" T2)" = "doing" ]; ok "query T2 reports doing" $?

"$SCRIPT" "$PLAN" "Task 2" done >/dev/null; ok "set 'Task 2' done exits 0" $?
[ "$("$SCRIPT" "$PLAN" 2)" = "done" ]; ok "query reports done after [~] -> [x]" $?
[ "$(changed_lines)" = "$FM $T2A $T2B" ]; ok "Task 2 done still touches nothing else" $?

# --- Task 3: the last task before `## Barrier:` — barrier steps stay [ ] ------
fresh
"$SCRIPT" "$PLAN" 3 done >/dev/null
BAR=$(line_of '- [ ] Merge Task 3 worktree')
[ "$(sed -n "${BAR}p" "$PLAN")" = '- [ ] Merge Task 3 worktree' ]; ok "barrier sub-step is not flipped by Task 3" $?
[ "$(changed_lines | wc -w | tr -d ' ')" = "3" ]; ok "Task 3 changes exactly two steps plus last_updated" $?

# --- Task 1: prefix trap (Task 10) and fenced code ---------------------------
fresh
"$SCRIPT" "$PLAN" 1 doing >/dev/null
FAKE=$(line_of '- [ ] not a real step')
[ "$(sed -n "${FAKE}p" "$PLAN")" = '- [ ] not a real step' ]; ok "checkbox inside a fenced block is untouched" $?
T10=$(line_of '- [ ] **Step 1: Implement**')
[ "$(sed -n "${T10}p" "$PLAN")" = '- [ ] **Step 1: Implement**' ]; ok "Task 10 is not matched by Task 1" $?
[ "$(changed_lines | wc -w | tr -d ' ')" = "4" ]; ok "Task 1 changes exactly three steps plus last_updated" $?

# --- Task 10: the section after `### Milestone 2:` --------------------------
fresh
"$SCRIPT" "$PLAN" 10 done >/dev/null
MS=$(line_of '- [ ] Milestone 2 checkpoint')
[ "$(sed -n "${MS}p" "$PLAN")" = '- [ ] Milestone 2 checkpoint (not a task step)' ]; ok "milestone section checkbox is untouched" $?
[ "$(changed_lines)" = "$FM $T10" ]; ok "Task 10 changes only its own step" $?

# --- failures leave the file byte-identical ------------------------------------
fresh
"$SCRIPT" "$PLAN" 4 done >/dev/null 2>&1
[ $? -ne 0 ]; ok "missing task exits non-zero" $?
cmp -s "$FIXTURE" "$PLAN"; ok "missing task leaves the plan unchanged" $?

"$SCRIPT" "$PLAN" 11 done >/dev/null 2>&1
[ $? -ne 0 ]; ok "task without checkbox steps exits non-zero" $?
cmp -s "$FIXTURE" "$PLAN"; ok "task without steps leaves the plan unchanged" $?

"$SCRIPT" "$PLAN" 2 finished >/dev/null 2>&1
[ $? -ne 0 ]; ok "unknown state is refused" $?
"$SCRIPT" "$PLAN" "Milestone 2" done >/dev/null 2>&1
[ $? -ne 0 ]; ok "a milestone is not an addressable task" $?
cmp -s "$FIXTURE" "$PLAN"; ok "refusals leave the plan unchanged" $?

printf '### Task 2: Duplicate\n\n- [ ] step\n' >> "$PLAN"
cp "$PLAN" "$ROOT/dup.md"
"$SCRIPT" "$PLAN" 2 done >/dev/null 2>&1
[ $? -ne 0 ]; ok "duplicated task heading is refused" $?
cmp -s "$ROOT/dup.md" "$PLAN"; ok "duplicate refusal leaves the plan unchanged" $?

# --- a fence closes only on its own character and length -----------------------
printf '%s\n' '### Task 1: a' '```bash' 'echo x' '~~~' '```' '- [ ] s' '### Task 2: b' '- [ ] real' > "$ROOT/tilde.md"
"$SCRIPT" "$ROOT/tilde.md" 2 doing >/dev/null 2>&1; ok "~~~ inside a backtick fence does not close it" $?
grep -qxF -- '- [~] real' "$ROOT/tilde.md"; ok "the real Task 2 after a mixed fence is flipped" $?

printf '%s\n' '### Task 1: a' '````md' '```' '### Task 2: fake' '- [ ] fake' '```' '````' '- [ ] s' '### Task 2: b' '- [ ] real' > "$ROOT/nested.md"
"$SCRIPT" "$ROOT/nested.md" 2 doing >/dev/null 2>&1; ok "a shorter fence nested in a longer one is text" $?
grep -qxF -- '- [ ] fake' "$ROOT/nested.md" && grep -qxF -- '- [~] real' "$ROOT/nested.md"; ok "the nested fake heading is skipped, the real one flipped" $?

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
