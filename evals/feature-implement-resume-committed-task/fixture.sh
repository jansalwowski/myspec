#!/usr/bin/env bash
# A serial phase stopped mid-implementation (#440): Task 1 is committed on
# the feature branch with its Plan-Task line, Task 2 never committed, both are
# [~], the bases are logged, and Phase 1 has only an `implement` stamp.
# Resume must not re-implement Task 1 on top of its own commit; Task 2 is
# the next dispatch.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P1="$HERE/../feature-implement-fix-round/phase1"
. "$HERE/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
register_feature invoice-due-dates in-progress
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
git checkout -q -b feat/invoice-due-dates
cp -R "$HERE/../feature-implement-dispatch/workspace/." .
git_commit_all "feat(invoice-due-dates): add implementation plan"
BASE=$(git rev-parse HEAD)
mkdir -p app/invoices tests/invoices
cp "$P1/app/invoices/due_dates.py" app/invoices/
cp "$P1/tests/invoices/test_due_dates.py" tests/invoices/
git add -A
git commit -qm "feat(invoice-due-dates): due-date rules" -m "Plan-Task: 1"
PLAN=.ai/features/invoice-due-dates/implementation-plan.md
"$PLUGIN_ROOT/lib/plan-checkbox.sh" "$PLAN" 1 doing >/dev/null
"$PLUGIN_ROOT/lib/plan-checkbox.sh" "$PLAN" 2 doing >/dev/null
printf '\n## Execution Log\n\n- Base (feature): %s\n- Base (Phase 1): %s\n' "$BASE" "$BASE" >> "$PLAN"
STATE=.claude/state/implement/invoice-due-dates
mkdir -p "$STATE"
printf 'implement 1794340000\n' > "$STATE/phase-1.times"
