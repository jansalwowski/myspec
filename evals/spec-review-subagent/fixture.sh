#!/usr/bin/env bash
# invoice-export spec.md (draft) with three planted defects, as in
# spec-review-planted-flaws. Here the Agent tool is granted, so the review's
# analysis must run in a reviewer subagent.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
add_feature feature-invoice-export-flawed invoice-export draft
git_commit_all "chore: invoice-export spec draft"
