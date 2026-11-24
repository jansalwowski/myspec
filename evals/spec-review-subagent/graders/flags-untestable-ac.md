---
type: regex
flags: i
pattern: 'fast[\s\S]{0,300}(?<!REQ-00[1-4]\b(?:(?!fast|AC-2)[^\n])*)(measur|testab|vague|subjective|quantif|threshold|seconds|no number|pass/fail|pass or fail|can(?:not|.t) be (?:tested|checked|verified))|(?<!REQ-00[1-4]\b(?:(?!fast|AC-2)[^\n])*)(measur|testab|vague|subjective|quantif|threshold)[\s\S]{0,300}fast'
---
