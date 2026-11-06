---
id: P{NNN}
type: procedural
# hook: keywords or a topic summary, never the solution
hook: ""
# polarity: positive, or negative for an anti-pattern
polarity: positive
# feature: feature name or empty for global
feature: ""
created: YYYY-MM-DD
validated: YYYY-MM-DD
validation_count: 0
# triggers: keywords agents search for
triggers: []
# not_for: explicit exclusions
not_for: []
# anchors: [{file: "path", pattern: "grep -E regex, one line"}]: add the key only for a code-specific memory
# related: IDs of related memories (e.g., ["S001", "E003"])
related: []
---

# [Title]

## Procedure (Do This)
1. [Step with file:line reference]
2. [Step with verification checkpoint]
3. **Verify**: [Expected outcome]

## Why This Works
[Root cause / conceptual explanation — keep brief]

## What Fails (Reference Only)
- [Failed approach] → [symptom it produces]

## Verification
- [ ] [Specific check with command]
- [ ] [Expected observable outcome]
