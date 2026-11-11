---
type: regex
pattern: 'Scenario(?: Outline)?(?: \d+)?:[ \t]*(?![\[{])\S[^\n]*\n[\s\S]*?\bGiven\b\**[ \t]+(?!preconditions?\b)\S[\s\S]*?\bWhen\b[\s\S]*?\bThen\b'
target:
  source: file
  path: .ai/features/invoice-due-dates/scenarios.md
---
