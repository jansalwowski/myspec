#!/usr/bin/env bash
# The feature-implement-dispatch workspace (approved 2-task plan on a clean
# feature branch), plus a CLAUDE.md commit rule naming a trailer. Implementers
# never see CLAUDE.md, so the controller must pass the trailer in the dispatch
# or every task commit drops it (#191).
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
. "$HERE/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
cat >> CLAUDE.md <<'MD'

## Commits

End every commit message with this trailer line, exactly:

    Refs: BILL-142
MD
copy_tree project-due-dates
register_feature invoice-due-dates draft
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
git checkout -q -b feat/invoice-due-dates
cp -R "$HERE/../feature-implement-dispatch/workspace/." .
git_commit_all "feat(invoice-due-dates): add implementation plan"
