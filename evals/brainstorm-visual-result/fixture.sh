#!/usr/bin/env bash
# A spike already rendered two comparison images; the brainstorm has to show them, not link them.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree spike-plate-compare
git_commit_all "chore: plate anonymisation spike output"
