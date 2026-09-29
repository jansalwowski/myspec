#!/usr/bin/env bash
# Python billing app on branch feat/invoice-due-dates, clean tree, with an
# approved spec, tech-spec and a 2-task sequential implementation plan. The
# controller must hand Task 1 to an implementer subagent instead of writing
# app/ or tests/ files itself (the 9ed2ed9 failure).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
register_feature invoice-due-dates draft
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
git checkout -q -b feat/invoice-due-dates
cp -R "$(dirname "${BASH_SOURCE[0]}")/workspace/." .
git_commit_all "feat(invoice-due-dates): add implementation plan"
