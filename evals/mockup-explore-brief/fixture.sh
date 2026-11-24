#!/usr/bin/env bash
# Python billing app whose invoice-reminders spec.md is still in the brief
# stage (`stage: brief`: one-line REQs, no User Stories or ACs). The prompt
# runs feature-mockup in --explore mode, which writes rough wireframes to
# exploration/ only and must leave the brief a brief.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
cp -R "$(dirname "${BASH_SOURCE[0]}")/workspace/." .
register_feature invoice-reminders draft
git_commit_all "chore: invoice-reminders brief"
