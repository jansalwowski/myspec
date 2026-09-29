#!/usr/bin/env bash
# Billing app: manifest lists a feature with no folder, and a folder is missing from the manifest.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
git_commit_all "chore: billing app with three features"
