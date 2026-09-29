#!/usr/bin/env bash
# Billing app initialised with myspec (rules, aiDir tree, three features).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
git_commit_all "chore: billing app with three features"
