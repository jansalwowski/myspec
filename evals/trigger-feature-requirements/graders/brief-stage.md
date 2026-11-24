---
type: regex
flags: m
pattern: '^-{3}\n(?=[\s\S]*?^stage: *"?brief"?[ \t]*$)(?=[\s\S]*?^status: *"?draft"?[ \t]*$)'
target:
  source: file
  path: .ai/features/reminder-settings/spec.md
---
