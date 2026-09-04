---
name: skill-verify
description: "Use to audit an existing SKILL.md for quality, compliance, and token efficiency — frontmatter validation, anti-pattern detection. Keywords: verify skill, check skill, skill lint. Do NOT use to create skills."
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

4.5. **Validate `dependencies:` block** (only if the frontmatter has one — optional Convention-tier field)
   - For each entry under `dependencies.packages`: confirm the package name appears in some `package.json` under the project root.
     `git ls-files '**/package.json' package.json | xargs grep -l "\"<pkg>\":"` — no match → Critical finding "declared dependency package `<pkg>` not found in any package.json".
   - For each entry under `dependencies.paths`: confirm the path exists in the working tree (`[ -e "<path>" ]`). Missing → Critical finding "declared dependency path `<path>` does not exist".
   - A skill that declares a dependency it does not actually have is broken (it will emit non-compiling or non-functional output). These are always Critical, never auto-fixed — the fix is either to add the dependency or delete/repair the skill, which requires human judgment.
   - Skills without a `dependencies:` block skip this step entirely.

5. **Detect Anti-Patterns** (check all 16 from Anti-Patterns Reference; read [references/detection-patterns.md](references/detection-patterns.md) for the scan regexes before starting)
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
   - Scan body for decorative formatting (Anti-Pattern #12): `> Note:` blockquotes, hard-wrapped paragraphs, 3-deep bullet ladders, horizontal rules `---` inside body, emoji-prefixed headers, ASCII boxes. Also post-invocation persuasion: "Bottom Line"/"Remember"/"Key Principles" recap sections, benefits recaps, social proof — the reader already invoked the skill
   - Scan for all-caps imperative walls (Anti-Pattern #13): high density of MUST/ALWAYS/NEVER without accompanying rationale
   - Scan for explanations the model already knows (Anti-Pattern #14): inline tutorials for well-known libraries, language primers, definitions of common terms — apply the test "does the model need this?"
   - Classify each normative guidance block by the failure it evidently targets and check its form against the Guidance Form Rules table (Anti-Pattern #15): prohibition lists aimed at output shape, soft "prefer/consider" wording on rules meant to hold under pressure, prose reminders where a template slot belongs, unconditional rules patched with exemptions
   - Scan rule statements for nuance clauses ("unless it matters", "except when necessary") and exemption clauses ("this limit doesn't apply to...") (Anti-Pattern #16) — workflow branching on observable predicates is fine; hedges appended to rules are not

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
   - For each post-invocation persuasion section flagged in step 5 (Anti-Pattern #12): propose deleting it or folding its points into their points of use — sections that persuade a reader who already invoked the skill are dead weight
   - Guard prose (paragraphs pre-arguing against anticipated excuses) compresses into an Excuse | Reality rationalization table, not into deletion — propose the table conversion
   - Tag any cut of discipline-critical guard content `[requires confirmation]` and recommend re-testing after the cut: in tested cases, cutting a discipline skill's recap regressed test-first compliance from 8/10 to 5/10 runs, and the working replacement was rationalization-table rows, not the restored prose
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
    - If any applied fix rewrote behavior-shaping guidance (form change, guard-content cut), recommend a wording micro-test before the skill ships: run a no-guidance control first — if the control does not exhibit the failure, the guidance is dead weight; recommend deleting it instead of rewording. 5+ fresh-context reps per variant (single samples lie); read every flagged match manually (template echoes masquerade as hits); treat variance as a metric — when guidance lands, reps converge on the same shape
    - Recommend next step: re-verify after fixes, or deploy

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

The tier table lives in `.claude/rules/skill-optimization.md` (co-loaded with this skill via its `load_when`) — do not duplicate it here. Flag fields outside the chosen portability tier. If the portability target is unstated, infer from field usage and flag conflicts (e.g. mixing `disable-model-invocation` with cross-platform claims). `dependencies` is validated by step 4.5 (packages must be in a package.json, paths must exist) — see `.claude/rules/skill-self-test.md`.

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
| 12 | **Decoration and post-invocation persuasion (humans-not-models)** | `> Note:` blockquotes, hard-wrapped prose, 3-deep bullet ladders, horizontal rules inside body, emoji-prefixed headers, ASCII boxes. Also "Bottom Line"/"Remember"/"Key Principles" recaps, benefits recaps, social proof — sections that persuade a reader who already invoked the skill. Body lands in the model's context, not on a screen — decoration and persuasion are paid for in tokens on every load | High |
| 13 | **All-caps imperative walls** | High density of MUST/ALWAYS/NEVER without explaining *why*. Anthropic's `skill-creator` flags this as a yellow flag: explain rationale instead of stacking imperatives | Medium |
| 14 | **Explanations the model already knows** | Inline tutorials for well-known libraries/languages, definitions of common terms. Apply the test: "Does the model need this? Can I assume it knows? Does this paragraph justify its token cost?" | Medium |
| 15 | **Guidance form mismatched to failure** | Form doesn't match the failure the guidance targets (see Guidance Form Rules): prohibition list aimed at output shape, soft "prefer/consider" on a rule meant to hold under pressure, prose reminders instead of a REQUIRED template slot, unconditional rule patched with exemptions | High |
| 16 | **Nuance and exemption clauses** | "Don't X unless it matters" / "except when necessary" appended to a rule; "this limit doesn't apply to..." carve-outs. See Guidance Form Rules for why neither works | High |

## Guidance Form Rules

Normative guidance has a form — prohibition, recipe, template slot, conditional — and each form fixes exactly one failure type; the form that bulletproofs one failure type measurably backfires on another. Classify what failure each guidance block evidently targets, then check the form against this table (mismatch = Anti-Pattern #15):

| Baseline failure the guidance targets | Right form | Wrong form — flag it |
|---|---|---|
| Skips/violates a rule under pressure (knows better, does it anyway) | Prohibition + rationalization table + red flags | Soft guidance ("prefer...", "consider...") |
| Complies, but output has the wrong shape (bloated prompt, buried verdict, restated spec) | Positive recipe or contract: state what the output IS — its parts, in order | Prohibition list ("don't restate", "never narrate") |
| Omits a required element from something they already produce | Structural: REQUIRED field or slot in the template they fill in | Prose reminders near the template |
| Behavior should depend on a condition | Conditional keyed to an observable predicate ("if the brief exists, reference it") | Unconditional rule + exemption clauses |

Prohibitions backfire on shaping problems because under a competing incentive agents negotiate with "don't X": in head-to-head wording tests, the prohibition arm produced clearly more of the unwanted content than the recipe arm, and trended worse than even the no-guidance control. A recipe leaves nothing to negotiate — the output matches the stated shape or it doesn't. Proposed fix for a shape-targeting prohibition list: rewrite as a recipe stating the output's parts, in order, tagged `[requires confirmation]`.

Two wording rules apply to whichever form the skill uses (violation = Anti-Pattern #16):

- **No nuance clauses.** "Don't X unless it matters" reopens the negotiation — appending a single nuance clause to a winning recipe degraded it from consistent to noisy. Fix: express the real exception as its own conditional on an observable predicate.
- **Exemption clauses don't scope.** "This limit doesn't apply to code blocks" still suppresses code blocks. Fix: restructure so the rule can't reach the exempt part.

Distinguish from legitimate conditionals: a workflow branch keyed to an observable predicate ("if the frontmatter has a `dependencies:` block...") is the right form, not a nuance clause. The flag is for hedges whose predicate is a judgment call ("matters", "necessary", "makes sense") appended to a rule or limit.

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

Per-type body targets are in the Token Efficiency table of `.claude/rules/skill-optimization.md` (co-loaded with this skill). Detection hints: "getting-started" in the name → getting-started tier; referenced by 3+ skills or loaded by rules → frequently-loaded tier; otherwise standard (<500 lines / <5,000 tokens), splitting to `references/` beyond that.

## Severity Classification

| Severity | Definition | Impact |
|----------|-----------|--------|
| **Critical** | Skill broken: agent skips body (workflow in description), won't load (name mismatch), missing frontmatter | Skill broken or misleading |
| **High** | Significantly degraded: poor discoverability, agent won't follow procedurally, force-loading burns context | Skill underperforms |
| **Medium** | Suboptimal: wrong voice, buried constraints, missing verification, verbose | Reduced effectiveness |
| **Low** | Polish: wording, additional keywords, compressed examples | Minor improvement |

## Output Format

**REQUIRED:** Follow [../\_shared/review-output.md](../_shared/review-output.md) for the findings table, fix-proposal shape, and tagging rules (this skill reviews a single file: use `Category` for `Dimension`, drop the `File` column). Example row:

```markdown
| Critical | Anti-Pattern #1 | Workflow in description | 3 | Description contains "analyzes X, generates Y" — agent will skip body |
```

## Verification Checklist

Outcome checks (not a workflow echo — per `.claude/rules/skill-optimization.md`):

- [ ] Every frontmatter finding cites the violated constraint (field, tier, or format rule)
- [ ] All 16 anti-patterns and the three structure rules were scanned — none skipped silently; regexes taken from `references/detection-patterns.md`
- [ ] Every normative guidance block was classified against the Guidance Form Rules table; each form-mismatch finding names the failure type and the right form
- [ ] No cut of discipline-critical guard content proposed without a `[requires confirmation]` tag and a re-test recommendation
- [ ] If a `dependencies:` block exists: every package located in a package.json and every path confirmed on disk, or a Critical finding raised
- [ ] Findings table is grouped by severity and every row has a line number (or `—` for absent-section findings)
- [ ] Every proposed fix is a concrete diff tagged `[auto-fix]` or `[requires confirmation]`; no `[requires confirmation]` fix applied without explicit approval
- [ ] Post-fix word/line/token counts reported and compared against the token target for the skill's type
- [ ] Trigger testing recommended (should-trigger, paraphrased, should-NOT-trigger queries)

## Integration

**Called by** [OPTIONAL]: external skill-authoring workflows (e.g. superpowers' `writing-skills`, if installed) as a quality gate
**Standalone:** Invoke directly to audit any existing skill
**Next:** Re-verify if issues found and fixed.
