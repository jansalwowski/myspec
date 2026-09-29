#!/usr/bin/env bash
# Approved spec + a tech-spec with two planted flaws:
#   1. REQ-004 (drafts never exported) has no implementation step, and the
#      repository the tech-spec reuses returns invoices of every status.
#   2. The reuse audit skips a shared CSV writer that .ai/conventions/backend.md
#      says every tabular download must use (app/reporting/tabular_export.py).
#      The tech-spec never names that module, so only a reviewer who read the
#      conventions or the code can mention it.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
cp -R "$(dirname "${BASH_SOURCE[0]}")/workspace/." .
register_feature invoice-export draft
git_commit_all "chore: invoice-export tech-spec draft"
