#!/usr/bin/env bash
# Freshly initialised project.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
git_commit_all "chore: initialise myspec"
