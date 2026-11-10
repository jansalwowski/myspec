#!/usr/bin/env bash
# A stopped run, resumed in a new session: Phase 1's tasks are implemented,
# committed and still [~], the barrier ran, and the phase review had started
# when the previous session stopped (its stage stamps say so). Resume must go
# on to the phase review, not re-execute the [~] tasks on top of their own
# commits.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$HERE/../feature-implement-compacted-midrun/fixture.sh"
STATE=.claude/state/implement/invoice-due-dates
printf 'implement 1794340000\nbarrier 1794340900\nreview 1794341300\n' > "$STATE/phase-1.times"
