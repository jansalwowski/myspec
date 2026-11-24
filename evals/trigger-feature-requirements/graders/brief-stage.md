---
type: regex
pattern: '^---\n(?=(?:(?!---\n)[^\n]*\n)*?stage: *"?brief"?[ \t]*\n)(?=(?:(?!---\n)[^\n]*\n)*?status: *"?draft"?[ \t]*\n)'
target:
  source: file
  path: .ai/features/reminder-settings/spec.md
---
