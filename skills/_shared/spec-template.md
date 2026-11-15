# Spec and Dependencies Template

The shape of `spec.md` and `dependencies.md`. `feature-spec` writes it and `feature-spec-review` checks against it, so a heading or ID format changes here and nowhere else.

## spec.md

Frontmatter:

```yaml
---
title: "{Feature Title}"
status: draft
phase: 1
priority: P{0|1|2|3}
spec_version: 1
created: {TODAY}
last_updated: {TODAY}
---
```

Required sections, as `##` headings in this order:

| Section | Content |
|---------|---------|
| Overview | 2-3 sentences: what the feature does and why |
| Goals | Bullet list of what this achieves |
| Requirements | Numbered list, one testable requirement per item, each with an ID: `1. REQ-001: The user must ...`. IDs run `REQ-001`, `REQ-002` and are never reused. Use "must" for required behavior and "may" for optional behavior |
| User Stories | `As a {actor}, I want {action} so that {benefit}` |
| Acceptance Criteria | One checkbox line per pass/fail condition, each with an ID: `- [ ] AC-1: ...` |
| Out of Scope | What this does not cover, with a reason or the feature that owns it |
| Open Questions | Unresolved decisions, or "None." |

No implementation detail: no file paths, class names, SQL or code.

## dependencies.md

```markdown
# Dependencies: {feature}

## Feature Dependencies
- `{feature}`: {why this feature needs it}

## Dependent Features
- `{feature}`: {what it uses from this feature}

## External Dependencies
- {library, service or API}: {why}
```

Write "None." under a heading with no entries. Every feature under Feature Dependencies is also in this feature's `depends-on` list in `${aiDir}/features/index.yaml`, and lists this feature under its own Dependent Features.
