---
type: regex
flags: m
pattern: '^#{2,3} +Spec Coverage[\s\S]*^\|[^\n]*\bREQ-005\b[^\n]*\|(?![^|\n]*[Dd][Ee][Ff][Ee][Rr])[^|\n]*(?:\bT\d|\bTask +\d)'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
