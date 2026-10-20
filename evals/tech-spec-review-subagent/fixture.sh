#!/usr/bin/env bash
# The tech-spec-review-planted-flaws project (approved spec, tech-spec with
# REQ-004 uncovered and an ignored shared CSV writer), with the Agent tool
# granted: the review's analysis must run in a reviewer subagent.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
cp -R "$(dirname "${BASH_SOURCE[0]}")/../tech-spec-review-planted-flaws/workspace/." .
register_feature invoice-export draft
git_commit_all "chore: invoice-export tech-spec draft"
