---
type: regex
pattern: '^-{3}\n(?=(?:(?!-{3}\n)[^\n]*\n)*?stage: *"?brief"?[ \t]*\n)(?=(?:(?!-{3}\n)[^\n]*\n)*?status: *"?draft"?[ \t]*\n)'
target:
  source: file
  path: .ai/features/reminder-settings/spec.md
---
