#!/usr/bin/env bash
# Python billing app with an approved spec and tech-spec for invoice-due-dates.
# REQ-004 (due_date as ISO 8601 in the API) and REQ-005 (a paid invoice is never
# overdue) are restated by no acceptance criterion, and no tech-spec step cites a
# REQ ID, so they reach the plan's Spec Coverage table only if the skill walks
# spec.md's requirements themselves (the 837f68d failure: an AC-only walk dropped them).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
register_feature invoice-due-dates draft
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
