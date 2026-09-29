---
type: regex
flags: m
pattern: '^-{3}\n(?=[\s\S]*?^spec_version: *\d)(?=[\s\S]*?^status: *draft)(?=[\s\S]*?^priority: *P[0-3])'
target:
  source: file
  path: .ai/features/invoice-reminders/spec.md
---
