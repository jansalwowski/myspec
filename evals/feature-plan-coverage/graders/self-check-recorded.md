---
type: regex
flags: im
pattern: '^#{2,3} +Plan Self-Check\b[\s\S]*\bsnippets?\b[\s\S]*\bsteps?\b[\s\S]*\bstrings?\b[\s\S]*\bprobe'
target:
  source: file
  path: .ai/features/invoice-due-dates/implementation-plan.md
---
