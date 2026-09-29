#!/usr/bin/env bash
# Billing app plus one active live session log in .claude/state/sessions/.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
copy_tree session-invoice-export
git_commit_all "chore: billing app with three features"
