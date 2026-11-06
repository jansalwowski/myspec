---
id: P{NNN}
type: procedural
# hook: keywords or a topic summary, never the solution
hook: ""
polarity: positive  # or negative for anti-patterns
feature: ""         # feature name or empty for global
created: YYYY-MM-DD
validated: YYYY-MM-DD
validation_count: 0
triggers: []        # keywords agents search for
not_for: []         # explicit exclusions
# anchors: [{file: "path", pattern: "grep -E regex, one line"}], or delete the line
# Comments go on their own line: hook and anchors read the rest of theirs as the value
anchors: []
related: []         # IDs of related memories (e.g., ["S001", "E003"])
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
