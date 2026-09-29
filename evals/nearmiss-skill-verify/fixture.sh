#!/usr/bin/env bash
# Billing app with a project-local SKILL.md under tools/agent-skills/release-notes/.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
git_commit_all "chore: billing app with three features"
