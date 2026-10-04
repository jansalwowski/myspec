#!/usr/bin/env bash
# Python billing app with an approved spec and tech-spec for invoice-due-dates
# and no scenarios.md: the revisit route of feature-spec (`{feature} scenarios`)
# is the only skill that writes one since feature-scenario was folded in (#264).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
register_feature invoice-due-dates draft
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
