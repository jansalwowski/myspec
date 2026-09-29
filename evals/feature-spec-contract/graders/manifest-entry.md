---
type: regex
flags: m
pattern: '^\s*-\s*name:\s*["]?invoice-reminders["]?\s*$'
target:
  source: file
  path: .ai/features/index.yaml
---
