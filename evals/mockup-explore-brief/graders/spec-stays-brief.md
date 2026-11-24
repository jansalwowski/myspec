---
type: regex
pattern: '^-{3}\n(?:(?!-{3}(?:\n|$))[^\n]*\n)*?stage: *["'']?brief["'']? *(?:\n|$)'
target:
  source: file
  path: .ai/features/invoice-reminders/spec.md
---
