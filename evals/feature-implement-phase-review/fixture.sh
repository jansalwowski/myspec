#!/usr/bin/env bash
# Phase 1 of the invoice-due-dates plan implemented and committed, with both
# tasks flipped to [~] and that plan edit left uncommitted, as the
# controller leaves it before the phase review. The phase reviewer dispatch
# must say the checkboxes are controller-managed, or the reviewer reads the
# uncommitted [~] as a defect (#167).
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
mkdir -p app/invoices tests/invoices docs
cp "$P1/app/invoices/due_dates.py" app/invoices/
cp "$P1/tests/invoices/test_due_dates.py" tests/invoices/
git_commit_all "feat(invoice-due-dates): due-date rules"
cp "$P1/app/invoices/serializers.py" app/invoices/
cp "$P1/tests/invoices/test_serializers.py" tests/invoices/
cp "$P1/docs/invoices-api.md" docs/
git_commit_all "feat(invoice-due-dates): due date and overdue flag in the invoice API"
PLAN=.ai/features/invoice-due-dates/implementation-plan.md
"$PLUGIN_ROOT/lib/plan-checkbox.sh" "$PLAN" 1 doing >/dev/null
"$PLUGIN_ROOT/lib/plan-checkbox.sh" "$PLAN" 2 doing >/dev/null
# The barrier already ran: the eval sandbox denies the suite and the shell
# redirect that builds the package, so both are written here, where the
# prompt names them. .claude/state/ is gitignored.
STATE=.claude/state/phase-1
mkdir -p "$STATE"
BASE=$(git rev-parse HEAD~2)
{ git log --oneline "$BASE"..HEAD; echo; git diff --stat "$BASE"..HEAD; echo; git diff -U10 "$BASE"..HEAD; } > "$STATE/review.diff"
printf '## ruff check .\nexit: 0\nAll checks passed!\n\n## pytest -q\nexit: 0\n5 passed in 0.04s\n' > "$STATE/verify.log"
