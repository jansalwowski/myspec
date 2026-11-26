#!/usr/bin/env bash
# Billing app with a backbone.yml (named in .myspec.json) written before a
# refactor: it lists app/invoices only, while the repo now also has
# app/payments/ and a cli/ entry point it does not mention.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
perl -0pi -e 's/("aiDir": "[^"]*",)/$1\n  "topologyFile": "backbone.yml",/' .myspec.json
grep -q '"topologyFile": "backbone.yml"' .myspec.json
cat > backbone.yml <<'YAML'
# ── PROJECT ──
project:
  name: billing-app
  description: Invoicing web app for small businesses
  stack: Python 3.12, Flask, PostgreSQL

# ── STRUCTURE ──
packages:
  - name: invoices
    path: app/invoices
    purpose: invoice models, repository and CSV export view

# ── COMMANDS ──
commands:
  test: pytest
  run: flask --app app run

# ── BOUNDARIES ──
boundaries:
  never_modify: []
  generated_do_not_edit: []
YAML
mkdir -p app/payments cli
cat > app/payments/__init__.py <<'PY'
PY
cat > app/payments/gateway.py <<'PY'
def charge(invoice_id: int, amount_cents: int) -> str:
    """Charge an invoice through the payment provider and return its reference."""
    raise NotImplementedError
PY
cat > cli/nightly_export.py <<'PY'
"""Nightly export: writes yesterday's invoices to the bookkeeping share."""


def main() -> None:
    raise NotImplementedError


if __name__ == "__main__":
    main()
PY
git_commit_all "chore: billing app after the payments refactor"
