---
title: "Pre-flight: {feature-name}"
purpose: "Feature-specific preventive checks"
feature: "{feature-name}"
updated: YYYY-MM-DD
---

# Pre-flight: {feature-name}

Feature-specific checks to run before working on {feature-name}.

## Always
- [ ] Read global `${aiDir}/pre-flight.md` first
  → **Verify**: Layer 1 index reviewed
- [ ] Check `${aiDir}/memory/procedural/index.md` for relevant patterns
  → **Verify**: Scanned "Use When" column for keyword matches
- [ ] Verify `${aiDir}/memory/sessions/active.md` state (resume or archive)
  → **Verify**: No conflicting active sessions

## Conditional Checks

**IF** [condition] → [action]

Examples:
- IF modifying external API integration → Read related procedural memories first
- IF adding reactive state → Use appropriate reactivity primitives for your framework
- IF changing async flow → Check component lifecycle

## Known Gotchas

1. **[Gotcha title]**
   - Problem: [brief description]
   - Solution: [what to do]
   - Memory: [link to memory if exists]

## Dependencies

Before changes, check these related features:
- [Related feature 1] - [why it matters]
- [Related feature 2] - [why it matters]

See `dependencies.md` for full dependency graph.
