---
type: regex
pattern: '^-{3}\n(?:(?!-{3}(?:\n|$))[^\n]*\n)*?status: *["'']?draft["'']? *(?:\n|$)'
target:
  source: file
  path: .ai/features/invoice-reminders/spec.md
---
