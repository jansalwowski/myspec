#!/usr/bin/env bash
# Billing app whose invoice-export feature has an approved spec and one
# finished mockup in .ai/features/invoice-export/mockups/.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
mkdir -p .ai/features/invoice-export/mockups
cat > .ai/features/invoice-export/mockups/export-dialog.html <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Export invoices</title></head>
<body>
  <h1>Export invoices</h1>
  <form>
    <label>From <input type="date" name="start"></label>
    <label>To <input type="date" name="end"></label>
    <label>Format
      <select name="format"><option>CSV</option><option>PDF</option><option>Excel</option></select>
    </label>
    <button type="button">Schedule weekly export</button>
    <button type="submit">Download</button>
    <a href="#">Cancel</a>
  </form>
</body>
</html>
HTML
git_commit_all "chore: invoice-export mockups"
