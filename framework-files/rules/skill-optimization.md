---
title: "Skill Optimization Reference"
purpose: "Quick reference for creating effective agent skills"
load_when:
  - path_matches: ".claude/skills/**"
  - skill_invoked: "skill-verify"
updated: 2026-03-29
---

# Skill Optimization Reference

## Quick Reference

| Principle | Wrong | Right |
|-----------|-------|-------|
| **Description** | Workflow summary | Keywords users type + specific examples + negative triggers |
| **Workflow steps** | "You should understand..." | "Check..." |
| **Code examples** | Full 200-line templates | 5-20 line non-obvious patterns only |
| **Verification** | "Make sure it works" | "Run the project's typecheck command — no errors" |
| **Checklist title** | "Quick Checklist" | "Verification Checklist" |
| **Skill naming** | `component`, `store` | `vue-component`, `vue-store`, `rails-controller` |
| **Structure** | Critical warnings at line 180 | Frontmatter → Workflow → Patterns → Verification |

## Transform Patterns

Replace documentary language with procedural commands:

- "You should..." → "Check..."
- "It's important to..." → "Verify..."
- "Make sure you..." → "Add..."
- "Understand X" → "Read X in path/to/file"
- Explanations → Commands

## Frontmatter Rules

- Only two fields: `name` and `description` (max 1024 chars total)
- `name`: letters, numbers, hyphens only
- `description`: 3rd person, starts with "Use when..."

## Description Pattern

**Critical**: Description is injected into system prompt. It's a **trigger mechanism**, not documentation.

Wrong: `"Generates composables with proper structure"` | Right: `"Use when creating composables: useEntity, useEntities. Handles data queries, mutations. Do NOT use for state stores or REST."`

**NEVER summarize workflow in the description.** Tested finding: when a description summarizes the skill's workflow, Claude follows the description instead of reading the full skill body. A description saying "code review between tasks" caused Claude to do ONE review, even though the skill's flowchart showed TWO. When changed to just trigger conditions, Claude read and followed the full skill correctly.

**Requirements**:
- List specific examples users might type
- Include tech stack keywords relevant to the skill
- End with "Do NOT use for [specific exclusions]"
- Prefix skill names with technology: `vue-component`, not `component`
- **Never** describe the process or workflow — only triggering conditions

## Verification Must Be Explicit

Agents don't verify unless commanded. Always include "Verification Checklist" section with exact commands, file checks, and pass/fail criteria. Checklist answers "How do I know I did it right?" not "What do I do?" Focus on verification, not workflow duplication.

## Code Example Guidelines

**Include code only for**:
1. Non-obvious patterns (edge cases, gotchas)
2. Critical 5-20 line snippets
3. One example per concept

**Skip code for**:
1. Standard framework boilerplate
2. Inferrable structure (use bullet points)
3. Complete implementations

## Skill Structure Template

1. **Frontmatter** (optimized description)
2. **Workflow** (procedural steps with critical constraints at top)
3. **Patterns** (concise descriptions, minimal code)
4. **Reference tables** (if needed for quick lookup)
5. **Verification checklist** (explicit commands)

## Token Efficiency

Skills load into conversation context. Every token counts.

| Skill type | Target word count |
|------------|------------------|
| Frequently-loaded (rules, getting-started) | < 200 words |
| Standard skills | < 500 words |

**Techniques:** Reference `--help` instead of documenting flags. Cross-reference other skills instead of repeating. One example per concept. Compress verbose examples.

## Cross-Referencing Skills

Use skill name with explicit requirement markers:
- `**REQUIRED:** Use /myspec:memory-lookup` — clear dependency
- `**See also:** /myspec:feature-plan` — optional reference

Do NOT use `@` file links to skill files — they force-load the full content immediately, burning context before it's needed.

## Flowchart Usage

Use `dot` flowcharts ONLY for non-obvious decision points and process loops where an agent might stop too early. Use markdown tables/lists for reference material, code examples, and linear instructions.

## Self-Check Questions

Before finalizing a skill:

- [ ] Would a user type these keywords in the description?
- [ ] Does the description avoid summarizing the workflow?
- [ ] Is every workflow step actionable (verb + deliverable)?
- [ ] Do code examples show non-obvious patterns only?
- [ ] Are negative triggers specific enough?
- [ ] Is verification explicit with commands?
- [ ] Is the skill under the target word count?
