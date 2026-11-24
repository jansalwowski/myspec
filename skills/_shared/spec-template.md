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

### Brief stage

A spec.md can start as a brief: a few rough requirements, written before mockups or the full spec. `feature-requirements` writes it (so does `feature-mockup --explore` when no spec.md exists), and `feature-spec` completes it in place, so the feature keeps one spec.md from the first line on.

- Frontmatter: the block above plus `stage: brief`. `status` stays `draft`. A brief is never `approved`, so `feature-tech-spec` and `feature-plan` refuse it. `feature-spec` removes `stage` when it completes the spec.
- Body: one-line bullets of a few words each, no prose paragraphs, about 25 lines in all. Only the sections below, with their names and order from the table above. User Stories and Acceptance Criteria are absent, and dependencies.md is not written yet.

```markdown
## Overview
- Problem: {the pain, with no solution words}
- Who: {actor or actors}
- Today: {evidence or current workaround, with its source}

## Goals
- Success: {observable signal: "we will know when ..."}
- Appetite: {time budget, or "not set"}

## Requirements
1. REQ-001: {capability, a few words}
2. REQ-002: {capability}

## Out of Scope
- {no-go}

## Open Questions
- [open] {question} (ticket) -> resolve by: mockup | spec | tech-spec | post-launch; default: {value}
- [assumption] {belief} (inferred)
- [decision] {what was decided} (user)
- [fact] {fact} (ticket)
```

- Requirements: 3 to 7 items. IDs follow the rule in the table above and are never reused, also after completion.
- Every Open Questions line starts with a status tag (`open`, `assumption`, `decision`, `fact`) and ends with a source tag: `user` (the user said it), `ticket` (any linked source: ticket, issue, document, idea file) or `inferred` (the agent filled a gap). Inferred content is never tagged `user`.
- An `open` line names the stage that resolves it and a default, so work continues on the default. It is a warning, never a block.
- A choice made while iterating on mockups is appended as a `[decision] ... (user)` line.

## dependencies.md

```markdown
---
title: "{Feature Title} Dependencies"
created: {TODAY}
---

# Dependencies: {feature}

## Feature Dependencies
- `{feature}`: {why this feature needs it}

## Dependent Features
- `{feature}`: {what it uses from this feature}

## External Dependencies
- {library, service or API}: {why}
```

Write "None." under a heading with no entries. Every feature under Feature Dependencies is also in this feature's `depends-on` list in `${aiDir}/features/index.yaml`, and lists this feature under its own Dependent Features.
