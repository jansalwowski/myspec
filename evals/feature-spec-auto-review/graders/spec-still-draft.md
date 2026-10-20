---
type: regex
flags: m
pattern: '^-{3}\n(?=[\s\S]*?^status: *draft\b)'
target:
  source: file
  path: .ai/features/invoice-reminders/spec.md
---
