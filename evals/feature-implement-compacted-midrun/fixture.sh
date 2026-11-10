#!/usr/bin/env bash
# The feature-implement-phase-review workspace (Phase 1 implemented and
# committed, both tasks [~], barrier log and review package prebuilt), plus
# the Execution Log entries a real run has logged by then. The prompt is a
# compaction summary: the run is mid-phase, so the [~] tasks are this run's
# own and must not be treated as a resume (re-executed, worktrees discarded).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$HERE/../feature-implement-phase-review/fixture.sh"
PLAN=.ai/features/invoice-due-dates/implementation-plan.md
BASE=$(git rev-parse HEAD~2)
printf '\n## Execution Log\n\n- Base (feature): %s\n- Base (Phase 1): %s\n' "$BASE" "$BASE" >> "$PLAN"
