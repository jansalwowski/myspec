#!/usr/bin/env bash
# Billing app with three procedural memories: one anchored to a file that no
# longer exists, and two that say the same thing about the CSV export.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
copy_tree project-billing
m=.ai/memory/procedural
write_memory() { # id hook file pattern
  cat > "$m/$1.md" <<MD
---
id: $1
type: procedural
hook: "$2"
polarity: positive
feature: ""
created: 2026-03-02
validated: 2026-03-02
validation_count: 1
triggers: [csv, export]
not_for: []
anchors: [{file: "$3", pattern: "$4"}]
related: []
---

# $2

## Procedure (Do This)
1. Stream rows with a generator instead of building the whole file in memory.
2. **Verify**: export of 10,000 invoices stays under 50 MB of RAM.
MD
}
write_memory P001 "Large CSV export runs out of memory" app/invoices/export_view.py "def export"
write_memory P002 "CSV export memory blow-up on big date ranges" app/invoices/export_view.py "def export"
write_memory P003 "Legacy PDF renderer needs fonts preloaded" app/legacy/pdf_render.py "def render"
cat >> "$m/index.md" <<'MD'
| P001 | large CSV export runs out of memory | app/invoices/export_view.py |
| P002 | CSV export memory blow-up on big date ranges | app/invoices/export_view.py |
| P003 | legacy PDF renderer needs fonts preloaded | app/legacy/pdf_render.py |
MD
git_commit_all "chore: billing app with a year of memories"
