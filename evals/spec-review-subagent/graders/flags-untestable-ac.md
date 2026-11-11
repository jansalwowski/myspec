---
type: regex
flags: i
pattern: 'fast[\s\S]{0,300}(?<!REQ-00[1-4]\b(?:(?!fast|AC-2)[^\n])*)(measur|testab|vague|subjective|quantif|threshold|seconds)|(?<!REQ-00[1-4]\b(?:(?!fast|AC-2)[^\n])*)(measur|testab|vague|subjective|quantif|threshold)[\s\S]{0,300}fast'
---
