#!/usr/bin/env bash
# plan-checkbox.sh
# Reads or sets the checkbox state of one task in an implementation-plan.md,
# addressed by its `### Task N:` heading (issue #93: an ad-hoc index script
# matched `### Milestone 2` and the `| 2 | Task 2: ... |` rows of the
# Execution Order table instead of the task, and corrupted the plan).
#
# Usage:
#   .claude/lib/plan-checkbox.sh <plan-file> <task> [todo|doing|done]
#
# <task>   the task number: `3`, `T3`, or `Task 3`
# state    todo → `[ ]`, doing → `[~]`, done → `[x]`. Omitted: print the
#          task's current state (todo, doing, done, or mixed) and change nothing.
#
# Scope: only checkbox list items (`- [ ]`) inside the task's own section —
# from its `### Task N:` heading to the next heading of level 1-3 (the next
# task, a `### Milestone N:` heading, a `## Barrier:` section). Table rows,
# other sections, and anything inside fenced code blocks are never touched.
# Setting a state also bumps `last_updated:` in the plan frontmatter, which
# feature-verify compares against tech-spec.md.
#
# Exit 1 when the heading is missing or duplicated, or the section holds no
# checkbox — the plan is left unchanged in every failure case.

set -euo pipefail

usage() {
  echo "usage: plan-checkbox.sh <plan-file> <task> [todo|doing|done]" >&2
  exit 1
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage
PLAN="$1"
TASK="$2"
STATE="${3:-}"

[ -f "$PLAN" ] || { echo "plan-checkbox: no such file: $PLAN" >&2; exit 1; }

ID=$(printf '%s' "$TASK" | sed -E 's/^[Tt]ask[[:space:]]*//; s/^[Tt]//')
case "$ID" in
  ''|*[!0-9]*) echo "plan-checkbox: task must be a number, T<n> or 'Task <n>' (got '$TASK')" >&2; exit 1 ;;
esac

case "$STATE" in
  '') MARK="" ;;
  todo) MARK=" " ;;
  doing) MARK="~" ;;
  done) MARK="x" ;;
  *) usage ;;
esac

TMP=$(mktemp "${TMPDIR:-/tmp}/plan-checkbox.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# awk exit codes: 0 ok, 2 heading missing, 3 heading duplicated, 4 no checkbox.
set +e
awk -v id="$ID" -v mark="$MARK" -v set="${STATE:+1}" -v today="$(date +%F)" '
  function heading_level(s) { match(s, /^#+/); return RLENGTH }
  function emit(s) { if (set) print s }
  BEGIN {
    task_re = "^###[ \t]+(Task[ \t]+|T)" id "([^0-9A-Za-z]|$)"
    box_re = "^[ \t]*[-*+][ \t]+\\[[ ~xX]\\]"
  }
  {
    line = $0
    if (NR == 1 && line == "---") { in_fm = 1; emit(line); next }
    if (in_fm) {
      if (line == "---") in_fm = 0
      else if (set && line ~ /^last_updated:/) line = "last_updated: " today
      emit(line); next
    }
    # A fence closes only on the same character, at least as long, with
    # nothing after it (CommonMark): a ~~~ inside ``` or ``` inside ```` is text.
    t = line; sub(/^[ \t]*/, "", t)
    if (in_fence) {
      if (substr(t, 1, 1) == fch && match(t, fch == "`" ? "^`+[ \t]*$" : "^~+[ \t]*$")) {
        run = t; sub(/[ \t]*$/, "", run)
        if (length(run) >= flen) in_fence = 0
      }
      emit(line); next
    }
    if (match(t, "^(```+|~~~+)")) { in_fence = 1; fch = substr(t, 1, 1); flen = RLENGTH; emit(line); next }
    if (!in_fence && line ~ /^#+[ \t]/ && heading_level(line) <= 3) {
      in_task = (line ~ task_re)
      if (in_task) found++
    }
    if (in_task && !in_fence && line ~ box_re) {
      boxes++
      match(line, /\[[ ~xX]\]/)
      s = substr(line, RSTART + 1, 1)
      seen[s == "X" ? "x" : s] = 1
      if (set) line = substr(line, 1, RSTART) mark substr(line, RSTART + 2)
    }
    emit(line)
  }
  END {
    if (found == 0) exit 2
    if (found > 1) exit 3
    if (boxes == 0) exit 4
    if (!set) {
      n = 0; for (k in seen) { n++; only = k }
      if (n > 1) st = "mixed"
      else st = (only == "x" ? "done" : (only == "~" ? "doing" : "todo"))
      print st
    }
  }
' "$PLAN" > "$TMP"
RC=$?
set -e

case "$RC" in
  0) ;;
  2) echo "plan-checkbox: no '### Task $ID:' heading in $PLAN" >&2; exit 1 ;;
  3) echo "plan-checkbox: '### Task $ID:' appears more than once in $PLAN" >&2; exit 1 ;;
  4) echo "plan-checkbox: Task $ID has no checkbox steps in $PLAN" >&2; exit 1 ;;
  *) echo "plan-checkbox: awk failed ($RC)" >&2; exit 1 ;;
esac

if [ -z "$STATE" ]; then
  cat "$TMP"
  exit 0
fi

# cat into the file, not mv: keeps the plan's inode, mode and any hard link.
cat "$TMP" > "$PLAN"
echo "plan-checkbox: Task $ID → $STATE"
