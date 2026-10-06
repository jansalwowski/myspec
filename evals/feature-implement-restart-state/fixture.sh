#!/usr/bin/env bash
# The feature-implement-dispatch workspace: an approved 2-task plan on a clean
# feature branch. Before Phase 1's first dispatch the controller must log the
# phase base in the plan's Execution Log, so a restarted session can recover
# it instead of losing it with the session (#166).
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
. "$HERE/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
register_feature invoice-due-dates draft
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
git checkout -q -b feat/invoice-due-dates
cp -R "$HERE/../feature-implement-dispatch/workspace/." .
git_commit_all "feat(invoice-due-dates): add implementation plan"
