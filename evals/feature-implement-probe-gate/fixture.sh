#!/usr/bin/env bash
# Python billing app on branch feat/invoice-due-dates with both tasks of an
# approved single-milestone plan done and committed, and its Checkpoint probes
# not yet run. Resume lands on the Step 4b probe gate, which must dispatch the
# plugin agent myspec:probe-executor, not a general-purpose subagent (#171).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init billing-app "Invoicing web app for small businesses" "Python 3.12, Flask, PostgreSQL"
copy_tree project-due-dates
register_feature invoice-due-dates in-progress
git_commit_all "chore: invoice-due-dates spec and tech-spec approved"
git checkout -q -b feat/invoice-due-dates
cp -R "$(dirname "${BASH_SOURCE[0]}")/workspace/." .
git_commit_all "feat(invoice-due-dates): due-date rules and API fields"
# The sandbox grants only read-only git, so the controller cannot run Step 4b's
# mkdir; the run's artifact directory exists already (gitignored run state).
mkdir -p .claude/state/implement/invoice-due-dates/probes/milestone-1/run-1
