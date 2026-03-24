---
title: Memory System — Global Index
purpose: Layer 1 always-loaded memory. Critical entries across all types.
updated: 2026-03-24
---

# Memory Index (Layer 1 — Always Loaded)

> **Budget**: ~200 tokens. Only the most critical entries belong here.
> **Agent**: This file is always in context. For full indexes, run `/myspec:memory-preflight`.

<!-- myspec:framework-start -->

## Critical Procedural (What NOT to Do)
- **P001**: Never reveal procedures in indexes — keywords/capabilities only
- **P002**: Lead with steps, not explanations — procedure before "why"
- **P007**: Always include "Not For" exclusions in procedural memories
- **P008**: Verification must have executable commands, not "make sure it works"

## Universal Anti-Patterns

### Description Leakage
Skill descriptions must be trigger mechanisms, not documentation. Include keywords users type, specific examples, and negative triggers. Never summarize the workflow in the description.

### Conceptual Over Procedural
Memories and instructions must lead with actionable steps. "Understand X" is not a step — "Read X in path/to/file" is. Replace documentary language with procedural commands.

### Ambiguous Decisions
Every architectural decision must state: what was decided, what alternatives were rejected, and why. "We chose X" without "over Y because Z" is incomplete.

### Missing Negative Triggers
Procedural memories and skills without "Not For" / "Do NOT use for" exclusions cause false matches. Always define boundaries.

### Verification Gap
"Make sure it works" is not verification. Every checklist item must have an executable command or observable outcome. Replace vague checks with specific commands.

### Stale Anchors
Memory anchors (file paths, grep patterns) that no longer match indicate potentially outdated knowledge. Flag during pre-flight, verify before relying on.

<!-- myspec:framework-end -->

## Must-Know Facts
<!-- Critical semantic facts promoted here when they exist -->

## Recent Significant Events
<!-- Critical episodic events promoted here when they exist -->

<!-- myspec:project-start -->

<!-- Project-specific anti-patterns go here. -->
<!-- Add entries as your team discovers patterns specific to your codebase. -->

<!-- myspec:project-end -->

---

*Full indexes: `procedural/index.md` | `semantic/index.md` | `episodic/index.md`*
*Loaded via `/myspec:memory-preflight` at task start.*
