#!/usr/bin/env bash
# The feature-implement-fix-round workspace (Phase 1 implemented and
# committed, both tasks [~]), plus the Execution Log a run has after three
# fix rounds that the re-review rejected. The prompt is a compaction summary
# that stops before round 4, so the round-4 rules (a fresh implementer, one
# tier up) have to come from the skill as it reads after a compaction.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$HERE/../feature-implement-fix-round/fixture.sh"
PLAN=.ai/features/invoice-due-dates/implementation-plan.md
BASE=$(git rev-parse HEAD~2)
HEAD_SHA=$(git rev-parse HEAD)
{
  printf '\n## Execution Log\n\n- Base (feature): %s\n- Base (Phase 1): %s\n' "$BASE" "$BASE"
  for r in 1 2 3; do printf -- '- Fix base (Phase 1, round %s): %s\n' "$r" "$HEAD_SHA"; done
} >> "$PLAN"
