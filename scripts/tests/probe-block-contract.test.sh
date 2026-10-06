#!/usr/bin/env bash
# The Checkpoint probes block is a contract between two files: feature-plan's
# template (skills/feature-plan/references/plan-templates.md) writes its
# lines, and the probe executor (agents/probe-executor.md) receives the
# block verbatim and acts on them by label. A label the template
# adds and the executor never names is a line nobody runs ("Scratch setup",
# #194); a label the executor names that the template dropped is a rule that
# never fires. Probe lines (P<n>, D<n>) are excluded: the executor runs every
# one of them by rule.
#
# Usage: probe-block-contract.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
TEMPLATE="$REPO_ROOT/skills/feature-plan/references/plan-templates.md"
EXECUTOR="$REPO_ROOT/agents/probe-executor.md"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# The block's setup labels: "- Label: ..." lines after **Checkpoint probes:**
# in the Milestone Section, up to the closing fence.
TEMPLATE_LABELS=$(awk '
  /^## Milestone Section/ { section = 1 }
  section && /^\*\*Checkpoint probes:\*\*/ { block = 1; next }
  block && /^```/ { exit }
  block && /^- [A-Z][A-Za-z ]*:/ {
    label = $0; sub(/^- /, "", label); sub(/:.*/, "", label)
    if (label !~ /^[PD][0-9]+/) print label
  }
' "$TEMPLATE")

[ "$(printf '%s\n' "$TEMPLATE_LABELS" | grep -c .)" -ge 2 ] && ok \
  || fail "template: found the Target and Scratch env lines (got: $TEMPLATE_LABELS)"

# The executor names a line as "<Label> line" ("One line per probe" is the
# report format, not a label).
EXECUTOR_LABELS=$(grep -oE '\b[A-Z][a-z]+( [a-z]+)? line( per)?\b' "$EXECUTOR" | grep -v ' per$' | sed 's/ line$//' | sort -u)

while IFS= read -r label; do
  [ -n "$label" ] || continue
  printf '%s\n' "$EXECUTOR_LABELS" | grep -qxF "$label" && ok \
    || fail "template line '$label:' is never named by the probe executor (as '$label line')"
done <<< "$TEMPLATE_LABELS"

while IFS= read -r label; do
  [ -n "$label" ] || continue
  printf '%s\n' "$TEMPLATE_LABELS" | grep -qxF "$label" && ok \
    || fail "the probe executor acts on a '$label line' the plan template does not write"
done <<< "$EXECUTOR_LABELS"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
