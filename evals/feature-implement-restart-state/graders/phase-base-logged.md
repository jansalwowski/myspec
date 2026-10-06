---
type: regex
flags: m
pattern: '^#{2,3} +Execution Log[\s\S]*^[-*] +`?Base \(Phase 1\): `?[0-9a-f]{7,40}\b'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
