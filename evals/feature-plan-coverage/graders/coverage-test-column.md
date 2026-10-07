---
type: regex
flags: m
pattern: '^#{2,3} +Spec Coverage[\s\S]*^\|[^\n]*\bTasks\b[^\n]*\|\s*Tests?\s*\|[\s\S]*^\|[^\n]*\bREQ-001\b[^\n]*\|[^|\n]*(?:\bT\d|\bTask +\d)[^|\n]*\|\s*[^|\s—-][^|\n]*\|'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
