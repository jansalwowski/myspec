---
type: regex
flags: im
match: not_contains
pattern: '^#{1,4} [^\n]*Acceptance Criteria'
target:
  source: file
  path: .ai/features/reminder-settings/spec.md
---
