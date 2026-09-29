#!/usr/bin/env bash
# invoice-export spec.md (draft) with three planted defects.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
add_feature feature-invoice-export-flawed invoice-export draft
git_commit_all "chore: invoice-export spec draft"
