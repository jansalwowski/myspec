#!/usr/bin/env bash
# The project-due-dates fixture (as in feature-plan-coverage) with spec.md and tech-spec.md both left at
# status: draft. feature-plan's gates require an approved spec and an approved
# (or user-confirmed) tech-spec, so it must stop before writing a plan.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
for doc in spec tech-spec; do
  f=".ai/features/invoice-due-dates/$doc.md"
  sed 's/^status: approved$/status: draft/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
grep -q '^status: draft$' .ai/features/invoice-due-dates/spec.md
grep -q '^status: draft$' .ai/features/invoice-due-dates/tech-spec.md
register_feature invoice-due-dates draft
git_commit_all "chore: invoice-due-dates spec and tech-spec drafts"
