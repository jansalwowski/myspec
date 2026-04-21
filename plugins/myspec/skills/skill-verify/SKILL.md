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

3. **Validate Frontmatter** (check against Frontmatter Rules table)
   - `name`: present, 1-64 chars, `[a-z0-9-]` only, matches parent directory name
   - `description`: present, 1-1024 chars, starts with "Use when", third person voice
   - No unsupported fields beyond `name`, `description`, `tags`, `triggers`, `metadata`
   - Confirm description does NOT summarize workflow (Anti-Pattern #1)

4. **Detect Anti-Patterns** (check all 11 from Anti-Patterns Reference)
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

5. **Validate Structure** (check against Structure Rules table)
   - Has Workflow section with numbered procedural steps
   - Has Rules/Constraints section (or "Common Mistakes", "Edge Cases")
   - Has Verification Checklist section with `- [ ]` items
   - Steps use procedural language: "Check...", "Run...", "Read..."
   - No documentary language: "You should...", "It's important to..."
   - Code examples under 20 lines each, only for non-obvious patterns

6. **Assess Token Efficiency and Progressive Disclosure**
   - Count total lines and words
   - Flag if skill exceeds 500 lines
   - Check for redundant content that could use cross-references instead
   - Check for verbose examples that could be compressed
   - **Progressive disclosure check**: If body >300 lines, check whether reference material (tables, examples, templates) could move to `references/` subdirectory for on-demand loading
   - Flag inlined content that is consulted only in specific steps — candidate for `references/` extraction
   - If skill is analysis/review-only (no write operations), suggest `allowed-tools` restriction (e.g., `[Read, Grep, Glob]`)

7. **Evaluate Description Quality**
   - Starts with "Use when" trigger condition
   - Contains specific keywords users would type
   - Contains synonym/variant phrasings for primary trigger (e.g., if skill handles PDF, check for "PDF", ".pdf files", "document generation")
   - Contains negative triggers ("Do NOT use for...")
   - No workflow description
   - Third person declarative voice
   - 2-4 sentences, under 500 characters recommended
   - Flag descriptions >500 chars or >4 sentences as verbose

8. **Present Findings**
   - Output findings table: Severity | Category | Issue | Line(s) | Finding
   - Group by severity: Critical → High → Medium → Low

9. **Propose Fixes**
   - Concrete rewrite or addition for each finding
   - Diff format: `- old text` / `+ new text`
   - Tag each: `[auto-fix]` for minor, `[requires confirmation]` for structural

10. **Wait for Confirmation**
    - Ask user which fixes to apply (all, by severity, individually)
    - Do NOT apply `[requires confirmation]` fixes without explicit approval

11. **Execute Changes**
    - Apply approved fixes to SKILL.md
    - Re-run word/line count after changes

12. **Summary**
    - Changes made (sections affected)
    - Remaining issues (if any rejected)
    - Final word and line count
    - Recommend testing: "Test the description with 5-10 trigger queries to verify activation accuracy. Include 3 should-trigger, 3 paraphrased, and 3 should-NOT-trigger queries."
    - Recommend next step: re-verify, test with writing-skills, or deploy

## Frontmatter Rules

| Field | Constraint | Detection |
|-------|-----------|-----------|
| `name` | 1-64 chars, `[a-z0-9-]` only | Regex: `/^[a-z0-9-]{1,64}$/` |
| `name` | Must match directory name | Compare with parent directory basename |
| `description` | 1-1024 characters | Character count |
| `description` | Starts with "Use when" | First words check |
| `description` | Third person — no `I`, `you`, `your`, `we`, `my` | Pronoun scan |
| `description` | No workflow summary | No sequential action verbs |
| `description` | Contains negative triggers | Look for "Do NOT use" |
| Extra fields | Only `tags`, `triggers`, `metadata` allowed beyond required | Flag unknowns |

## Anti-Patterns Reference

| # | Anti-Pattern | Detection | Severity |
|---|-------------|-----------|----------|
| 1 | **Workflow summary in description** | Sequential verbs in description: "analyzes X, generates Y, validates Z" | Critical |
| 2 | **Generic/vague description** | Missing specific keywords; uses "helps with", "manages", "handles things" | High |
| 3 | **README-style documentation** | Body contains "This skill helps...", "Understanding X is important", explanatory paragraphs without commands | High |
| 4 | **Monolithic skill** | 3+ unrelated capabilities, body exceeds 800 lines | High |
| 5 | **First/second person voice** | `I can`, `you should`, `your project`, `we recommend` in body or description | Medium |
| 6 | **Buried critical steps** | Key constraints appear after line 50 with no early reference | Medium |
| 7 | **External dependencies** | Requires `git clone`, `npm install`, network fetch, or live URLs at runtime | Medium |
| 8 | **Command lists without context** | Flat commands with no conditional logic, error handling, or verification. Also: workflow has zero conditional branching (`if`, `when`, `unless`) | Medium |
| 9 | **Force-loading references** | Uses `@skill-name` or `@path/to/file` syntax. Cross-references to other skills missing REQUIRED/OPTIONAL markers | High |
| 10 | **No progressive disclosure** | Body >300 lines with inlined reference material that could move to `references/` for on-demand loading | High |
| 11 | **Missing `allowed-tools` for read-only skills** | Skill performs analysis/review only but does not restrict tool access | Low |

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

| Skill Type | Limit | How to Detect |
|------------|-------|--------------|
| Getting-started | <150 words | Name contains "getting-started" |
| Frequently-loaded | <200 words | Referenced by 3+ skills or loaded by rules |
| Standard | <500 lines | Default |
| Complex | Split to `references/` if >500 lines | Move excess content to subdirectory |

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

# Oversized code blocks (flag if > 20 lines between ``` markers)
```

## Verification Checklist

After running the skill:

- [ ] Skill path was resolved and SKILL.md was read
- [ ] YAML frontmatter was parsed; `name` and `description` both present
- [ ] `name` matches parent directory name
- [ ] `description` starts with "Use when" and uses third person
- [ ] All 11 anti-patterns were checked against description and body
- [ ] Structure validated: Workflow, Rules/Constraints, Verification Checklist sections present
- [ ] Procedural language verified (no documentary patterns)
- [ ] Token efficiency assessed: word count, line count, progressive disclosure compliance
- [ ] Description quality checked: keywords, synonyms, negative triggers, no workflow summary
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
2. Validate frontmatter: `name`, `description` fields
3. Confirm `name: vue-component` matches directory `vue-component/`
4. Check description for workflow summary, voice, keywords, negative triggers
5. Scan body for all 9 anti-patterns
6. Validate structure: Workflow, Rules, Verification sections
7. Count words and lines, compare to targets
8. Present findings table grouped by severity
9. Propose fixes in diff format
10. Wait for user confirmation on structural changes
11. Apply approved fixes and report final metrics

## Integration

**Called by:** `writing-skills` (as quality gate before TDD testing phase)
**Standalone:** Invoke directly to audit any existing skill
**Next:** Re-verify if issues found and fixed. If clean, proceed to TDD testing per `writing-skills`.
