---
type: regex
flags: m
pattern: '^#{2,3} +Spec Coverage[\s\S]*^\|[^\n]*\bREQ-001\b[^\n]*\|[^|\n]*(?:\bT\d|\bTask +\d|DEFERRED)'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
