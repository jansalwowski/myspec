#!/usr/bin/env bash
# The feature-implement-dispatch workspace with Phase 1 already implemented:
# both tasks committed and marked [~], awaiting the fix loop. The phase
# reviewer's finding (given in the prompt) is about a rule, the overdue
# boundary, which the phase states in four places: the code, its docstring,
# a test and docs/invoices-api.md. The fix dispatch must ask for every place,
# not only the cited line (#168).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
register_feature invoice-due-dates draft
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
git checkout -q -b feat/invoice-due-dates
cp -R "$HERE/../feature-implement-dispatch/workspace/." .
git_commit_all "feat(invoice-due-dates): add implementation plan"
PLAN=.ai/features/invoice-due-dates/implementation-plan.md
"$PLUGIN_ROOT/lib/plan-checkbox.sh" "$PLAN" 1 doing >/dev/null
"$PLUGIN_ROOT/lib/plan-checkbox.sh" "$PLAN" 2 doing >/dev/null
git_commit_all "chore(invoice-due-dates): Tasks 1-2 started"
mkdir -p app/invoices tests/invoices docs
cp "$HERE/phase1/app/invoices/due_dates.py" app/invoices/
cp "$HERE/phase1/tests/invoices/test_due_dates.py" tests/invoices/
git_commit_all "feat(invoice-due-dates): due-date rules"
cp "$HERE/phase1/app/invoices/serializers.py" app/invoices/
cp "$HERE/phase1/tests/invoices/test_serializers.py" tests/invoices/
cp "$HERE/phase1/docs/invoices-api.md" docs/
git_commit_all "feat(invoice-due-dates): due date and overdue flag in the invoice API"
