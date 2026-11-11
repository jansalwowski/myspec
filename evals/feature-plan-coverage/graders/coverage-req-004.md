---
type: regex
flags: m
pattern: '^#{2,3} +Spec Coverage\b(?:\n(?!#)[^\n]*)*?\n\|[^|\n]*\bREQ-004\b[^|\n]*\|(?![^\n]*[Dd][Ee][Ff][Ee][Rr])[^|\n]*\|[^|\n]*(?:\bT\d|\bTask +\d)'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
