---
type: regex
pattern: 'Scenario(?: Outline)?:[\s\S]*?\bGiven\b[\s\S]*?\bWhen\b[\s\S]*?\bThen\b'
target:
  source: file
  path: .ai/features/invoice-due-dates/scenarios.md
---
