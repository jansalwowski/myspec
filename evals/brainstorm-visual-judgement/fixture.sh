#!/usr/bin/env bash
# A spike already rendered two comparison images; asked which looks less fake, the brainstorm has to offer to show them, not describe them.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree spike-plate-compare
git_commit_all "chore: plate anonymisation spike output"
