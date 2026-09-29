---
type: regex
flags: im
pattern: '^\|\s*Phase\s*\|[^\n]*\bTasks?\b[^\n]*\|[^\n]*\bDepends On\b[^\n]*\|\s*$'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
