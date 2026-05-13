---
name: skill-verify
description: >
  Use when auditing or reviewing an existing skill's SKILL.md for quality,
  compliance, and effectiveness. Covers frontmatter validation, anti-pattern
  detection, and token efficiency assessment. Trigger phrases: verify skill,
  audit skill, check skill, validate skill, skill lint, skill review, skill
  compliance. Do NOT use for creating new skills (use writing-skills), for
  feature spec review (use feature-spec-review), or for general code review.
---

# Skill Verify

## Workflow

1. **Resolve Skill Path**
   - If argument is a skill name: resolve to `.claude/skills/{name}/SKILL.md`
   - If argument is a file path: use directly
   - If no argument: ask user which skill to verify
   - Confirm file exists before proceeding

2. **Read Skill Content**
   - Read the full SKILL.md
   - Parse YAML frontmatter (between `---` delimiters)
   - Extract `name` and `description` fields
   - Capture body content (everything after frontmatter)

3. **Detect Invocation Mode** (determines which description rules apply)
   - If `disable-model-invocation: true`: skill is manual-only. The description never enters the system prompt, so it is a human-readable label — not a trigger. Skip the "Use when" check and Anti-Pattern #1 (workflow-in-description) for this skill.
   - If `user-invocable: false`: skill is model-only. The slash-command picker rule does not apply.
   - Otherwise (default): skill is model-invocable. All description trigger rules apply in full.
   - If frontmatter mixes Claude Code-only fields (e.g. `disable-model-invocation`, `hooks`, `agent`) with claims of cross-platform portability in the body, flag the inconsistency (portability target mismatch).

4. **Validate Frontmatter** (check against Frontmatter Rules table)
   - `name`: present, 1-64 chars, `[a-z0-9-]` only, matches parent directory name
   - `description`: present, 1-1024 chars. If model-invocable: starts with "Use when", third person. If manual-only: any human-readable label is fine.
   - Allowed fields by tier (see Frontmatter Rules table). Flag fields outside the chosen portability target.
   - For model-invocable skills only: confirm description does NOT summarize workflow (Anti-Pattern #1)

5. **Detect Anti-Patterns** (check all 14 from Anti-Patterns Reference)
   - Scan description for workflow verbs in sequence
   - Scan description for vague/generic language without specific keywords
   - Scan body for README-style documentary language
   - Assess scope: count distinct capabilities, check for monolithic coverage
   - Scan body for first/second person pronouns
   - Check if critical constraints appear after line 50 without early reference
   - Check for external dependency requirements (clone, install, network URLs)
   - Check for flat command lists without conditions or error handling
     - Also check: does the workflow contain any conditional branching (`if`, `when`, `unless`)? Flag if all steps are unconditional sequences
   - Scan for `@` force-loading references
     - If skill references other skills by name, suggest REQUIRED/OPTIONAL markers per cross-reference pattern
   - Scan body for decorative formatting (Anti-Pattern #12): `> Note:` blockquotes, hard-wrapped paragraphs, 3-deep bullet ladders, horizontal rules `---` inside body, emoji-prefixed headers, ASCII boxes
   - Scan for all-caps imperative walls (Anti-Pattern #13): high density of MUST/ALWAYS/NEVER without accompanying rationale
   - Scan for explanations the model already knows (Anti-Pattern #14): inline tutorials for well-known libraries, language primers, definitions of common terms — apply the test "does the model need this?"

6. **Validate Structure** (check against Structure Rules table)
   - Has Workflow section with numbered procedural steps
   - Has Rules/Constraints section (or "Common Mistakes", "Edge Cases")
   - Has Verification Checklist section with `- [ ]` items
   - Steps use procedural language: "Check...", "Run...", "Read..."
   - No documentary language: "You should...", "It's important to..."
   - Code examples under 20 lines each, only for non-obvious patterns

7. **Assess Token Efficiency and Progressive Disclosure**
   - Count total lines and words; estimate tokens (~0.75 words/token)
   - Flag if body exceeds 5,000 tokens or 500 lines (Anthropic spec recommendation for Phase 2 loading)
   - Check for redundant content that could use cross-references instead
   - Check for verbose examples that could be compressed
   - **Progressive disclosure check**: If body >300 lines, check whether reference material (tables, examples, templates) could move to `references/` subdirectory for on-demand loading
   - Flag inlined content that is consulted only in specific steps — candidate for `references/` extraction
   - If skill is analysis/review-only (no write operations), suggest `allowed-tools` restriction (e.g., `[Read, Grep, Glob]`)

8. **Evaluate Description Quality** (skip for manual-only skills)
   - Starts with "Use when" trigger condition
   - Contains specific keywords users would type (concrete terms, not abstractions: "pytest" not "Python testing"; ".docx files" not "Word documents")
   - Contains synonym/variant phrasings for primary trigger (e.g., if skill handles PDF, check for "PDF", ".pdf files", "document generation")
   - Contains negative triggers ("Do NOT use for...")
   - No workflow description
   - Third person declarative voice (description is injected into the system prompt — first/second person breaks that context)
   - 2-4 sentences, under 500 characters recommended
   - Flag descriptions >500 chars or >4 sentences as verbose
   - If `triggers` field is populated with phrases the author expects to drive activation, warn: agents ignore `triggers` — only `description` is matched. Move trigger phrases into `description`.

9. **Present Findings**
   - Output findings table: Severity | Category | Issue | Line(s) | Finding
   - Group by severity: Critical → High → Medium → Low

10. **Propose Fixes**
    - Concrete rewrite or addition for each finding
    - Diff format: `- old text` / `+ new text`
    - Tag each: `[auto-fix]` for minor, `[requires confirmation]` for structural

11. **Wait for Confirmation**
    - Call `AskUserQuestion` so options are selectable:
      ```
      question: "Which fixes should I apply?"
      header:   "Apply fixes"
      options:
        - "All [auto-fix] only"       → apply small fixes; leave structural for review
        - "All including structural"  → apply every proposed fix
        - "Individually"              → pick fixes one at a time
        - "None"                      → leave SKILL.md unchanged
      ```
    - Do NOT apply `[requires confirmation]` fixes without explicit approval.

12. **Execute Changes**
    - Apply approved fixes to SKILL.md
    - Re-run word/line count after changes

13. **Summary**
    - Changes made (sections affected)
    - Remaining issues (if any rejected)
    - Final word and line count
    - Recommend testing: "Test the description with 5-10 trigger queries to verify activation accuracy. Include 3 should-trigger, 3 paraphrased, and 3 should-NOT-trigger queries."
    - Recommend next step: re-verify, test with writing-skills, or deploy

## Frontmatter Rules

### Field constraints

| Field | Constraint | Detection |
|-------|-----------|-----------|
| `name` | 1-64 chars, `[a-z0-9-]` only | Regex: `/^[a-z0-9-]{1,64}$/` |
| `name` | Must match directory name | Compare with parent directory basename |
| `description` | 1-1024 characters | Character count |
| `description` | Starts with "Use when" (model-invocable only) | First words check; skip if `disable-model-invocation: true` |
| `description` | Third person — no `I`, `you`, `your`, `we`, `my` | Pronoun scan; injected into system prompt |
| `description` | No workflow summary (model-invocable only) | No sequential action verbs; skip if `disable-model-invocation: true` |
| `description` | Contains negative triggers (model-invocable only) | Look for "Do NOT use" |

### Allowed fields by portability tier

| Tier | Fields | Notes |
|------|--------|-------|
| **Spec** (any agentskills.io platform) | `name`, `description`, `license`, `compatibility`, `allowed-tools` | `allowed-tools` is marked Experimental in the spec; support varies |
| **Claude Code + VS Code Copilot** | adds `disable-model-invocation`, `user-invocable` | Not in open spec; ignored on other platforms |
| **Claude Code only** | adds `model`, `effort`, `context`, `agent`, `hooks`, `paths`, `shell`, `argument-hint`, `arguments`, `when_to_use` | Single-vendor only |
| **Convention** (ignored by agents, used by tooling) | `tags`, `triggers`, `metadata` | `triggers` is NOT used for activation — agents only match on `description` |

Flag fields outside the chosen portability tier. If portability target is unstated, infer from field usage and flag conflicts (e.g. mixing `disable-model-invocation` with cross-platform claims).

## Anti-Patterns Reference

| # | Anti-Pattern | Detection | Severity |
|---|-------------|-----------|----------|
| 1 | **Workflow summary in description** | Sequential verbs in description: "analyzes X, generates Y, validates Z" | Critical |
| 2 | **Generic/vague description** | Missing specific keywords; uses "helps with", "manages", "handles things" | High |
| 3 | **README-style documentation** | Body contains "This skill helps...", "Understanding X is important", explanatory paragraphs without commands | High |
| 4 | **Monolithic skill** | 3+ unrelated capabilities, body exceeds 800 lines | High |
| 5 | **Wrong voice for audience** | Description: any first/second person (`I can`, `you should`, `your`, `we`) — it's injected into the system prompt. Body: documentary second-person (`you should`, `you can`, `make sure you`) instead of imperative (`Run`, `Check`, `Verify`) | Medium |
| 6 | **Buried critical steps** | Key constraints appear after line 50 with no early reference | Medium |
| 7 | **External dependencies** | Requires `git clone`, `npm install`, network fetch, or live URLs at runtime | Medium |
| 8 | **Command lists without context** | Flat commands with no conditional logic, error handling, or verification. Also: workflow has zero conditional branching (`if`, `when`, `unless`) | Medium |
| 9 | **Force-loading references** | Uses `@skill-name` or `@path/to/file` syntax. Cross-references to other skills missing REQUIRED/OPTIONAL markers | High |
| 10 | **No progressive disclosure** | Body >300 lines with inlined reference material that could move to `references/` for on-demand loading | High |
| 11 | **Missing `allowed-tools` for read-only skills** | Skill performs analysis/review only but does not restrict tool access | Low |
| 12 | **Decorative formatting (humans-not-models)** | `> Note:` blockquotes, hard-wrapped prose, 3-deep bullet ladders, horizontal rules inside body, emoji-prefixed headers, ASCII boxes. Body lands in the model's context, not on a screen — decoration is paid for in tokens on every load | High |
| 13 | **All-caps imperative walls** | High density of MUST/ALWAYS/NEVER without explaining *why*. Anthropic's `skill-creator` flags this as a yellow flag: explain rationale instead of stacking imperatives | Medium |
| 14 | **Explanations the model already knows** | Inline tutorials for well-known libraries/languages, definitions of common terms. Apply the test: "Does the model need this? Can I assume it knows? Does this paragraph justify its token cost?" | Medium |

## Structure Rules

| Element | Required | Check |
|---------|----------|-------|
| Workflow section | Yes | H2 "Workflow" with numbered steps |
| Rules/Constraints section | Yes | H2 with "Rules", "Constraints", "Common Mistakes", or "Edge Cases" |
| Verification Checklist | Yes | H2 "Verification" with `- [ ]` items |
| Procedural language | Yes | Steps start with: Check, Run, Read, Verify, Create, Add, Remove |
| No documentary language | Yes | Absent: "You should", "It's important to", "Make sure you", "Understanding" |
| Code examples | Recommended | Each block under 20 lines; non-obvious patterns only |

## Token Targets

The Anthropic spec recommends keeping the body under **5,000 tokens** (≈500 lines, ≈3,750 words). Phase 2 loads the entire body on activation, so every token competes with conversation history.

| Skill Type | Limit | How to Detect |
|------------|-------|--------------|
| Getting-started | <150 words (~200 tokens) | Name contains "getting-started" |
| Frequently-loaded | <200 words (~270 tokens) | Referenced by 3+ skills or loaded by rules |
| Standard | <500 lines / <5,000 tokens | Default — Anthropic spec recommendation |
| Complex | Split to `references/` if >500 lines | Move on-demand reference content to subdirectory (Phase 3 loading) |

## Severity Classification

| Severity | Definition | Impact |
|----------|-----------|--------|
| **Critical** | Skill broken: agent skips body (workflow in description), won't load (name mismatch), missing frontmatter | Skill broken or misleading |
| **High** | Significantly degraded: poor discoverability, agent won't follow procedurally, force-loading burns context | Skill underperforms |
| **Medium** | Suboptimal: wrong voice, buried constraints, missing verification, verbose | Reduced effectiveness |
| **Low** | Polish: wording, additional keywords, compressed examples | Minor improvement |

## Output Format

### Findings Table

```markdown
| Severity | Category | Issue | Line(s) | Finding |
|----------|----------|-------|---------|---------|
| Critical | Anti-Pattern #1 | Workflow in description | 3 | Description contains "analyzes X, generates Y" — agent will skip body |
| High | Anti-Pattern #9 | Force-loading reference | 45 | Uses `@testing-skills.md` — burns tokens on load |
| Medium | Structure | Missing verification checklist | — | No "Verification Checklist" section with `- [ ]` items |
| Low | Token Efficiency | Verbose example | 78-95 | Code block is 17 lines; could compress to 8 |
```

### Fix Proposals

```markdown
## Fix 1: Remove workflow from description (Critical) [requires confirmation]

**Line**: 3

**Current**:
- description: Analyzes code, generates migration files, validates schema changes

**Proposed**:
+ description: >
+   Use when making database schema changes. Handles Prisma migrations and
+   destructive operation detection. Do NOT use for query-only changes.

**Rationale**: Description must be trigger mechanism, not workflow summary.
```

## Detection Patterns

```
# name format (frontmatter)
/^[a-z0-9-]{1,64}$/

# description starts with "Use when"
/^Use when/

# Anti-Pattern #1 — workflow in description (sequential action verbs)
/\b(analyzes?|generates?|creates?|validates?|checks?)\b.*(then|next|after|finally)/i

# Anti-Pattern #3 — README-style language
/This skill (helps|is|provides|enables)|Understanding .* is important/i

# Anti-Pattern #5 — first/second person
/\b(I can|I will|you should|you can|your |we |our |my )\b/i

# Anti-Pattern #9 — force-loading
/@[a-zA-Z][\w\/.-]+/

# Documentary language in steps
/\b(You should|It's important to|Make sure you|Remember to)\b/

# Anti-Pattern #10 — no progressive disclosure (>300 lines with inlined refs)
# Count body lines; if >300, scan for tables/examples that are only used in one step

# Anti-Pattern #8 extended — no conditional branching
# Check workflow section for absence of: if, when, unless, otherwise
/\b(if |when |unless |otherwise)\b/i

# Anti-Pattern #12 — decorative formatting
/^>\s*(\*\*)?Note[:\*]/m              # blockquote "Note:" boxes
/^---\s*$/m                            # horizontal rules inside body (not frontmatter)
/^#{1,6}\s+[\u{1F300}-\u{1FAFF}]/mu    # emoji-prefixed headers
/^\s{6,}[-*]\s/m                       # 3-deep (or deeper) bullet ladders

# Anti-Pattern #13 — all-caps imperative density
# Count occurrences of \b(MUST|ALWAYS|NEVER|SHOULD NOT|DO NOT)\b
# Flag if >5 occurrences without nearby rationale ("because", "since", "to avoid")

# Anti-Pattern #14 — model-known explanations
# Heuristic: paragraphs that define common terms or explain mainstream libraries
/\b(is a popular|is a JavaScript library|allows you to|is used to)\b/i

# Manual-only invocation (skip Anti-Pattern #1 and "Use when" check)
/^disable-model-invocation:\s*true/m

# Oversized code blocks (flag if > 20 lines between ``` markers)
```

## Verification Checklist

After running the skill:

- [ ] Skill path was resolved and SKILL.md was read
- [ ] YAML frontmatter was parsed; `name` and `description` both present
- [ ] `name` matches parent directory name
- [ ] Invocation mode detected (`disable-model-invocation`, `user-invocable`); description rules adjusted accordingly
- [ ] Frontmatter fields validated against the chosen portability tier (spec / Claude Code+Copilot / Claude Code only / convention)
- [ ] If model-invocable: `description` starts with "Use when" and uses third person
- [ ] All 14 anti-patterns were checked against description and body
- [ ] Structure validated: Workflow, Rules/Constraints, Verification Checklist sections present
- [ ] Procedural language verified (no documentary patterns); decorative formatting checked (Anti-Pattern #12)
- [ ] All-caps imperative density checked (Anti-Pattern #13); model-known explanations checked (Anti-Pattern #14)
- [ ] Token efficiency assessed: word count, line count, progressive disclosure compliance, 5,000-token body limit
- [ ] Description quality checked: concrete keywords, synonyms, negative triggers, no workflow summary
- [ ] `triggers` field misuse checked (warn if author put activation phrases there)
- [ ] Findings table output grouped by severity with line numbers
- [ ] Fixes proposed in diff format with `[auto-fix]` or `[requires confirmation]` tags
- [ ] User confirmation requested before `[requires confirmation]` changes
- [ ] Final word and line count reported after changes
- [ ] Summary shows sections changed and remaining issues
- [ ] Trigger testing recommended: 5-10 queries (should-trigger, paraphrased, should-NOT-trigger)

## Example Usage

```
User: /skill-verify vue-component
```

**Expected behavior**:
1. Resolve to `.claude/skills/vue-component/SKILL.md`
2. Detect invocation mode (model-invocable vs. manual-only)
3. Validate frontmatter: `name`, `description`, fields-by-portability-tier
4. Confirm `name: vue-component` matches directory `vue-component/`
5. Check description for workflow summary, voice, keywords, negative triggers (skip trigger checks if manual-only)
6. Scan body for all 14 anti-patterns
7. Validate structure: Workflow, Rules, Verification sections
8. Count words/lines/tokens, compare to 5,000-token body target
9. Present findings table grouped by severity
10. Propose fixes in diff format
11. Wait for user confirmation on structural changes
12. Apply approved fixes and report final metrics

## Integration

**Called by:** `writing-skills` (as quality gate before TDD testing phase)
**Standalone:** Invoke directly to audit any existing skill
**Next:** Re-verify if issues found and fixed. If clean, proceed to TDD testing per `writing-skills`.
