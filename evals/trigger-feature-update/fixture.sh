#!/usr/bin/env bash
# Billing app whose invoice-export feature is shipped: approved spec and
# tech-spec, every plan task checked, code in app/invoices/, and the manifest
# entry moved to complete. A change to it is feature-update's job.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
perl -0pi -e 's/(name: invoice-export\n(?:    .*\n)*?    status: )in-progress/${1}complete/' .ai/features/index.yaml
grep -A2 'name: invoice-export' .ai/features/index.yaml | grep -q 'status: complete'
git_commit_all "chore: billing app with invoice-export shipped"
