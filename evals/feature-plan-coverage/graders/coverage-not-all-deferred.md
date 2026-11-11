---
type: regex
flags: m
pattern: '^#{2,3} +Spec Coverage[\s\S]*^\|[^\n]*\bREQ-\d+\b[^\n]*\|(?!\s*DEFERRED)[^|\n]*(?:\bT\d|\bTask +\d)'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
