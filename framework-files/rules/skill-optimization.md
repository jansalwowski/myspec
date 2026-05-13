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

**Required:** `name`, `description`.

**Constraints:**
- `name`: 1-64 chars, lowercase letters, digits, hyphens only. Must match parent directory name.
- `description`: 1-1024 chars. For model-invocable skills, third person and starts with "Use when…".

**Allowed optional fields by portability tier:**

| Tier | Fields |
|------|--------|
| Spec (cross-platform) | `license`, `compatibility`, `allowed-tools` (experimental) |
| Claude Code + VS Code Copilot | `disable-model-invocation`, `user-invocable` |
| Claude Code only | `model`, `effort`, `context`, `agent`, `hooks`, `paths`, `shell`, `argument-hint`, `arguments`, `when_to_use` |
| Convention (ignored by agents) | `tags`, `triggers`, `metadata` |

`triggers` is **not** used for activation — agents only match on `description`. Put trigger phrases in the description.

## Description Pattern

**Critical** (model-invocable skills): the description is injected into the system prompt and is a **trigger mechanism**, not documentation.

Wrong: `"Generates composables with proper structure"`
Right: `"Use when creating composables: useEntity, useEntities. Handles data queries, mutations. Do NOT use for state stores or REST."`

**Never summarize the workflow in the description.** Tested finding: when a description summarizes the skill's workflow, agents follow the description instead of reading the full skill body. A description saying "code review between tasks" caused one review pass instead of the two the skill's flowchart specified. When changed to just trigger conditions, agents read and followed the full skill correctly.

**Requirements:**
- List specific examples users might type
- Include tech-stack keywords relevant to the skill
- End with "Do NOT use for [specific exclusions]"
- Prefix skill names with technology: `vue-component`, not `component`
- Describe trigger conditions only — never the procedure

**Exception — manual-only skills (`disable-model-invocation: true`):** the description never enters context as a trigger. It becomes a human-readable label for slash-command pickers and skill catalogs. The "Use when…" rule and the no-workflow-summary rule no longer apply; write a clear human-readable summary instead.

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

When a skill activates, the full body lands in context — the cost is paid on every load. The Anthropic spec recommends body bodies under **5,000 tokens** (~3,750 words / ~500 lines).

| Skill type | Body target |
|------------|-------------|
| Frequently-loaded (rules, getting-started) | < 200 words |
| Standard | < 500 lines / < 5,000 tokens |
| Complex (>500 lines) | Move reference material to `references/` for Phase 3 on-demand load |

**Techniques:** Reference `--help` instead of documenting flags. Cross-reference other skills instead of repeating. One example per concept. Compress verbose examples. Move tables, templates, and long examples that are consulted only in specific steps to `references/`.

## Cross-Referencing Skills

Use skill name with explicit requirement markers:
- `**REQUIRED:** Use /myspec:memory-lookup` — clear dependency
- `**See also:** /myspec:feature-plan` — optional reference

Do NOT use `@` file links to skill files — they force-load the full content immediately, burning context before it's needed.

## Format for the Model, Not for Humans

When a skill activates, the body lands in the model's context window — not on a human's screen. Decoration costs tokens on every load and dilutes attention.

**Drop:**
- `dot` / mermaid / ASCII diagrams — agents read them as text noise; encode the flow as numbered steps or a small table instead
- `> Note:` blockquote boxes — promote to a top-level instruction or delete
- Hard-wrapped prose (let lines run as long as the sentence)
- 3-deep bullet ladders — flatten or use a table
- Horizontal rules `---` inside the body (the only `---` should be the YAML frontmatter delimiters)
- Decorative dividers, emoji-prefixed headers, ASCII boxes
- All-caps walls of MUST/ALWAYS/NEVER without rationale (`skill-creator`'s yellow flag)
- Explanations for things the model already knows (mainstream libraries, common terms)

**Keep:**
- Imperative form (`Run X`, `Check Y`) over documentary (`You should run X`)
- Numbered steps with concrete commands
- Tables for parallel structured data (decision matrices, status mappings, error lookups)
- Code fences for mechanical content; inline backticks for paths and identifiers
- One concrete input/output pair beats a paragraph describing the format

## Self-Check Questions

Before finalizing a skill:

- [ ] Would a user type these keywords in the description?
- [ ] Does the description avoid summarizing the workflow?
- [ ] Is every workflow step actionable (verb + deliverable)?
- [ ] Do code examples show non-obvious patterns only?
- [ ] Are negative triggers specific enough?
- [ ] Is verification explicit with commands?
- [ ] Is the skill under the target word count?
