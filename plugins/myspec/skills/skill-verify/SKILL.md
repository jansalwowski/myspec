---
name: skill-verify
description: "Use when an existing SKILL.md needs auditing for quality, compliance, and token efficiency — frontmatter validation, anti-pattern detection, structural completeness. Keywords: verify skill, check skill, skill lint. Do NOT use to create skills."
---

# Skill Verify

## Workflow

1. **Resolve Skill Path**
   - If argument is a skill name: resolve to `.claude/skills/{name}/SKILL.md`
   - If argument is a file path: use directly
   - If no argument: ask user which skill to verify
   - Confirm file exists before proceeding

2. **Run the native validators** — cheap, deterministic, and a useful floor. They are **not** a substitute for steps 5-7. If a command is unavailable, note it and continue.
   - `claude plugin validate <path> --strict` — YAML parse, manifest schema, component path escaping, `shell` enum, `metadata` shape.
   - **A clean `validate` proves almost nothing this skill checks.** Probed against 2.1.273, `--strict` passes `name: -pdf`, `name: pdf--x`, a reserved-word name, a `name` that does not match its directory, an unknown frontmatter key, a list-form `allowed-tools`, and `disable-model-invocation: true` with `user-invocable: false`. Never report a clean validate as "frontmatter is fine" — every frontmatter rule in step 5 still has to run by hand.
   - `claude plugin details <plugin>` (when the skill ships in an **installed** plugin) — measured always-on and on-invoke token cost. Use these in step 9; a word-count estimate misses bundled files and runs ~2x low.

3. **Read Skill Content**
   - Read the full SKILL.md; parse YAML frontmatter; capture body separately

4. **Detect Invocation Mode** (determines which description rules apply)
   - `disable-model-invocation: true`: manual-only. The description never enters context, so it is a human-readable label, not a trigger. Skip the "Use when" check and Anti-Pattern #1. Trigger phrasing here is dead tokens — flag it (Anti-Pattern #17).
   - `user-invocable: false`: model-only. The slash-command picker rule does not apply.
   - Both `disable-model-invocation: true` and `user-invocable: false`: **Critical — nobody can invoke this skill.**
   - Otherwise: model-invocable; all description trigger rules apply.
   - Flag a portability target mismatch when Claude Code-only fields (`disable-model-invocation`, `hooks`, `agent`, `context`) sit alongside body claims of cross-platform portability.

5. **Validate Frontmatter** — read [references/detection-patterns.md](references/detection-patterns.md) for the regexes and caps before starting; do not re-derive them. Several rules apply only to some portability targets, so settle the target from step 4 first.
   - `name`: present, 1-64 chars, `[a-z0-9-]`, no leading/trailing hyphen, no consecutive hyphens. A single character is legal.
   - `name` matches the parent directory: **spec/upload tier only.** Claude Code treats `name` as a display label and loads the skill under its directory name regardless — flag a mismatch as Low there, Critical only where the skill must satisfy the spec validator or upload to claude.ai.
   - `description`: present, 1-1024 chars (spec cap). If model-invocable: starts with "Use when", third person, no XML tags.
   - If targeting Claude Code and `when_to_use` is present: it is not free space — it shares the listing cap with `description`, and the tail is what gets cut. Front-load triggers.
   - Confirm every field against the portability tier. A non-spec field is a hard upload failure on claude.ai and the Skills API, not a silent ignore — but only where upload is a target.
   - If a `dependencies:` block exists (myspec convention), verify it by running the checks, not by reading:
     ```
     git ls-files '**/package.json' package.json | xargs grep -l "\"<pkg>\":"   # each packages entry
     [ -e "<path>" ]                                                            # each paths entry
     ```
     A missing package or path is **Critical**, never auto-fixed — the fix is human judgment. Skip the step entirely when the block is absent. See `.claude/rules/skill-self-test.md`; note the hazard in `AGENTS.md` about declaring plugin-internal paths, which false-fail in every consumer repo.

6. **Detect Anti-Patterns** — scan for every row in the Anti-Patterns Reference table. Read [references/detection-patterns.md](references/detection-patterns.md) for the regexes first; do not re-derive them.
   - Apply the mechanical regex scans in one pass, then the judgment-based rows (#4, #14, #15, #16) one at a time
   - Classify each normative guidance block by the failure it evidently targets, then check its form against the Guidance Form Rules table

7. **Check Structural Completeness** — the highest-prevalence real defects are omissions, not smells. Read [references/structural-completeness.md](references/structural-completeness.md) for what counts as satisfying each row, then check the Structural Completeness table.

8. **Validate Structure** (check against Structure Rules)

9. **Assess Token Efficiency and Progressive Disclosure**
   - Use the measured cost from step 2 where available; otherwise count lines and words and estimate at ~0.75 words/token, stating that the estimate runs low
   - Flag a body over 5,000 tokens or 500 lines. The consequence is concrete: past 5,000 tokens the skill is truncated when re-injected after `/compact`, so its tail silently stops applying mid-session.
   - **Under-split**: body >300 lines with reference material consulted in only one step → propose moving it to `references/`
   - **Over-split**: a `references/` file that every run loads anyway is indirection with no payoff → propose inlining it
   - Reference files must sit one level deep from SKILL.md; flag deeper chains. Reference files over 100 lines need a table of contents.
   - Repeated deterministic logic described in prose belongs in `scripts/` — a script beats a paragraph of instructions
   - Guard prose (paragraphs pre-arguing against anticipated excuses) compresses into an Excuse | Reality table, not into deletion. Tag any such cut `[requires confirmation]` and recommend re-testing: cutting one discipline skill's recap regressed compliance from 8/10 to 5/10 runs, and the fix was table rows, not restored prose.

10. **Evaluate Description Quality** (skip for manual-only skills)
    - Starts with "Use when"; third person; ends with a specific negative trigger
    - Concrete keywords users would actually type — "pytest" not "Python testing", ".docx files" not "Word documents" — plus synonyms and variant phrasings
    - States what the skill does and when to use it, never the step sequence (Anti-Pattern #1)
    - Lean pushy: agents under-trigger skills far more often than they over-trigger them
    - 2-4 sentences. Flag over 4 sentences or 500 chars as verbose, well before the 1,024 cap.
    - If a `triggers` field is populated, warn: no agent reads it — only `description` is matched. Move the phrases into `description`.

11. **Check Fleet-Level Discoverability** (when the skill ships alongside others)
    - Skill listings are budget-capped and evict least-invoked descriptions first, so past a threshold each added skill silently deletes another's discoverability. Report the skill count and always-on total from step 2, and state the diagnostic: a skill that used to activate reliably and has gone quiet is listing pressure before it is a bad description.
    - Scan sibling descriptions for trigger collisions — two skills matching one phrase is a defect no single-file audit can see

12. **Present Findings** — findings table, grouped Critical → High → Medium → Low

13. **Propose Fixes**
    - Concrete rewrite per finding, diff format: `- old` / `+ new`
    - Tag `[auto-fix]` for mechanical, `[requires confirmation]` for structural
    - When an evaluation fails, prefer simplifying the skill over adding rules to it

14. **Wait for Confirmation**
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

15. **Execute Changes** — apply approved fixes, then re-run `claude plugin validate` and recount lines and words. Do **not** re-run `claude plugin details`: it reads the installed marketplace copy, not the working tree, so it would report the pre-fix number as the result. Either reinstall the plugin first or report the recount and label it an estimate that runs low.

16. **Recommend Testing** — the audit is static; activation is not. Read [references/testing-skills.md](references/testing-skills.md) and recommend the applicable tests by name and size.
    - Always: the trigger test (~20 queries, near-miss negatives, 3 runs, pick the best validation iteration). No native tooling covers activation.
    - When the skill ships in a plugin: a `claude plugin eval` suite for behavior, CI-gated on `--threshold`
    - When a fix rewrote behavior-shaping guidance: the wording micro-test, starting from a no-guidance control

## Frontmatter Rules

| Field | Constraint | Applies to |
|-------|-----------|-----------|
| `name` | 1-64 chars, `[a-z0-9-]`, no leading/trailing hyphen, no `--`; 1 char is legal | All targets |
| `name` | Matches parent directory name | Spec/upload only — Low elsewhere |
| `name` | No reserved words `anthropic` / `claude`, no XML tags | Anthropic targets |
| `description` | 1-1024 chars, non-empty, no XML tags | All targets |
| `description` + `when_to_use` | Under 1,536 combined | Claude Code listing cap |
| `description` | Starts with "Use when", third person, no workflow summary, has a negative trigger | Model-invocable only |
| `allowed-tools` | Space-separated string | Spec/upload only — Claude Code also accepts comma-separated and YAML list |
| File paths | Forward slashes, even on Windows | All targets |

Regexes and the exact caps are in `references/detection-patterns.md`; the portability tier table is in `.claude/rules/skill-optimization.md`. That rule is path-gated — if it did not co-load, read it directly before judging any field against a tier, and say in the report which tier was assumed. Infer the target from field usage when unstated, and flag conflicts.

## Anti-Patterns Reference

| # | Anti-Pattern | Detection | Severity |
|---|-------------|-----------|----------|
| 1 | **Workflow summary in description** | Sequential verbs: "analyzes X, then generates Y". Short-circuits progressive disclosure — the agent concludes it already knows the procedure and skips the body | Critical |
| 2 | **Generic/vague description** | "helps with", "manages", "handles things"; no concrete keywords | High |
| 3 | **README-style documentation** | "This skill helps...", "Understanding X is important", explanation without commands | High |
| 4 | **Monolithic skill** | 3+ capabilities that share no workflow and would be invoked independently, **or** body over 800 lines. The test is the skill's stated purpose, not its step count — a multi-step procedure serving one purpose is not monolithic | High |
| 5 | **Wrong voice for audience** | Description: any first/second person. Body: documentary ("you should") instead of imperative ("Run", "Check") | Medium |
| 6 | **Buried critical steps** | Key constraints after line 50 with no early reference. The middle of a long body is where instructions go unread | Medium |
| 7 | **External dependencies** | Requires `git clone`, `npm install`, network fetch, or live URLs at runtime | Medium |
| 8 | **Command lists without context** | Flat commands, no conditionals, no error handling, no verification | Medium |
| 9 | **Force-loading references** | `@skill-name` or `@path` syntax burns tokens before they are needed. Cross-references missing REQUIRED/OPTIONAL markers | High |
| 10 | **No progressive disclosure** | Body >300 lines with inlined reference material that only one step consults | High |
| 11 | **`allowed-tools` misused as a sandbox** | Body or comments treat it as a restriction. It is a **pre-approval grant** — it removes confirmation friction and cannot stop a skill writing files, so a careless value removes safety rather than adding it. `disallowed-tools` is the real restriction but is cleared on the next user message, so neither is a safety boundary. Judge the *claim*, not the field's presence | High |
| 12 | **Decoration and post-invocation persuasion** | `> Note:` blockquotes, hard-wrapped prose, 3-deep bullet ladders, horizontal rules in body, emoji headers, ASCII boxes. Also "Bottom Line"/"Remember" recaps and social proof — the reader already invoked the skill. Charged on every load | High |
| 13 | **Unexplained all-caps imperatives** | MUST/ALWAYS/NEVER with no rationale nearby. Flag only caps with no stated *why* — escalating to MUST for a rule that is actually being missed is legitimate | Low |
| 14 | **Explanations the model already knows** | Tutorials for mainstream libraries, definitions of common terms. Test: "Does the model need this? Does this paragraph justify its token cost?" | Medium |
| 15 | **Guidance form mismatched to failure** | Form does not match the targeted failure (see Guidance Form Rules) | High |
| 16 | **Nuance and exemption clauses** | "unless it matters", "except when necessary" appended to a rule; "this limit doesn't apply to..." carve-outs | High |
| 17 | **Trigger-style description on a manual-only skill** | `disable-model-invocation: true` with a "Use when..." description. The description never enters context — trigger phrasing is dead tokens. Write a human-readable label | Low |
| 18 | **`context: fork` with no task** | `context: fork` on a skill that states conventions rather than a task. The subagent receives guidelines and no actionable prompt, and returns nothing useful | Medium |

## Structural Completeness

Absences, not smells. These are the defects that actually dominate real skills, and none are regex-detectable — read [references/structural-completeness.md](references/structural-completeness.md) for what satisfies each row before judging.

| Check | Flag when | Severity |
|---|---|---|
| **Rationalization coverage** | A rule expected to hold under pressure ships with no Excuse \| Reality table and no red-flag list naming the excuses that defeat it | High |
| **Gotchas present and surfaced** | Environment-specific facts that defy reasonable assumptions are absent, or buried in `references/` where the agent will not know to look | High |
| **Validation step** | The workflow produces an artifact but never verifies it | High |
| **Guardrails on destructive steps** | A mutating or irreversible step has no stated precondition or confirmation | High |
| **Human checkpoint** | An irreversible or genuinely ambiguous branch with no point where the user is asked | Medium |
| **Plan before execute** | A multi-step mutating workflow that starts changing things before stating a plan | Medium |
| **Decision tree explicit** | Branches described in prose where a predicate table belongs | Medium |
| **Progress tracking** | A long workflow with no checklist or state the agent updates as it goes | Medium |
| **Caveats and failure path** | No statement of what to do when a step fails. Undefined failure paths get improvised | Medium |
| **Utility script** | The same deterministic logic re-derived in prose every run instead of shipped as a script | Low |

## Guidance Form Rules

Normative guidance has a form, and each form fixes exactly one failure type; the form that bulletproofs one measurably backfires on another. Classify the failure the guidance targets, then check the form (mismatch = Anti-Pattern #15):

| Baseline failure the guidance targets | Right form | Wrong form — flag it |
|---|---|---|
| Skips/violates a rule under pressure (knows better, does it anyway) | Prohibition + rationalization table + red flags | Soft guidance ("prefer...", "consider...") |
| Complies, but output has the wrong shape (bloated, buried verdict, restated spec) | Positive recipe or contract: state what the output IS — its parts, in order | Prohibition list ("don't restate", "never narrate") |
| Omits a required element from something they already produce | Structural: REQUIRED field or slot in the template they fill in | Prose reminders near the template |
| Behavior should depend on a condition | Conditional keyed to an observable predicate | Unconditional rule + exemption clauses |

Prohibitions backfire on shaping problems because agents negotiate with "don't X" under a competing incentive: in head-to-head tests the prohibition arm produced more of the unwanted content than the recipe arm, and trended worse than the no-guidance control. A recipe leaves nothing to negotiate. Rewrite a shape-targeting prohibition list as a recipe, tagged `[requires confirmation]`.

Two wording rules apply to whichever form is used (violation = Anti-Pattern #16):

- **No nuance clauses.** "Don't X unless it matters" reopens the negotiation — one nuance clause degraded a winning recipe from consistent to noisy. Express the real exception as its own conditional on an observable predicate.
- **Exemption clauses don't scope.** "This limit doesn't apply to code blocks" still suppresses code blocks. Restructure so the rule cannot reach the exempt part.

A workflow branch keyed to an observable predicate ("if the frontmatter has a `dependencies:` block") is the right form, not a hedge. Flag only hedges whose predicate is a judgment call ("matters", "necessary", "makes sense").

## Structure Rules

| Element | Required | Check |
|---------|----------|-------|
| Procedural body | Yes | Numbered steps or an explicit decision table — not prose exposition |
| Rules/Constraints section | Yes | H2 with "Rules", "Constraints", "Common Mistakes", or "Edge Cases" |
| Verification Checklist | Yes | H2 "Verification" with `- [ ]` items |
| Imperative language | Yes | Steps start with: Check, Run, Read, Verify, Create, Add, Remove |
| No documentary language | Yes | Absent: "You should", "It's important to", "Make sure you", "Understanding" |
| Code examples | Recommended | Each block under 20 lines; non-obvious patterns only |

**Match prescriptiveness to the task, do not impose it.** A numbered workflow is right for a narrow task with a known-good path and real hazards. For open-ended tasks it is a defect in its own right — an over-prescribed sequence stops the agent adapting, and rigid step lists are among the most common smells in real skills. Judge the body against the task: flag missing structure only where the task has one correct order. Where it does not, require an explicit decision table instead of a step list.

## Token Targets

Per-type body targets live in the Token Efficiency table of `.claude/rules/skill-optimization.md` (co-loaded). Detection hints: "getting-started" in the name → getting-started tier; referenced by 3+ skills or loaded by rules → frequently-loaded tier; otherwise standard (<500 lines / <5,000 tokens), splitting to `references/` beyond that. Prefer measured numbers from `claude plugin details` over estimates.

## Severity Classification

| Severity | Definition | Impact |
|----------|-----------|--------|
| **Critical** | Skill broken: workflow in description, missing frontmatter, invocable by nobody, declared dependency absent, name mismatch *where the spec validator or upload applies* | Broken or misleading |
| **High** | Significantly degraded: poor discoverability, false safety, force-loading, missing guardrails | Underperforms |
| **Medium** | Suboptimal: wrong voice, buried constraints, missing verification, verbose | Reduced effectiveness |
| **Low** | Polish: wording, extra keywords, compressed examples | Minor improvement |

## Output Format

**REQUIRED:** Follow [../\_shared/review-output.md](../_shared/review-output.md) for the findings table, fix-proposal shape, and tagging rules (this skill reviews a single file: use `Category` for `Dimension`, drop the `File` column). Example row:

```markdown
| Critical | Anti-Pattern #1 | Workflow in description | 3 | Description contains "analyzes X, generates Y" — agent will skip body |
```

## Verification Checklist

Outcome checks (not a workflow echo — per `.claude/rules/skill-optimization.md`):

- [ ] `claude plugin validate --strict` was run and reported, and a clean result was **not** treated as frontmatter clearance — every step 5 rule was still checked by hand
- [ ] Token cost came from `claude plugin details` only where the plugin is installed and unmodified since; any post-fix number is a recount labelled as running low
- [ ] The portability target was stated in the report, and every tier-scoped rule (`name` directory match, `allowed-tools` type, non-spec fields) was judged against that target rather than unconditionally
- [ ] If a `dependencies:` block exists: every package located in a package.json and every path confirmed on disk by running the checks, or a Critical finding raised
- [ ] Every frontmatter finding cites the violated constraint (field, tier, or format rule) and the portability target it applies to
- [ ] Every row of the Anti-Patterns Reference and the Structural Completeness table was checked — none skipped silently; regexes taken from `references/detection-patterns.md`
- [ ] Every normative guidance block was classified against the Guidance Form Rules table; each form-mismatch finding names the failure type and the right form
- [ ] Prescriptiveness was judged against the task, not assumed — a missing numbered workflow is a finding only where the task has one correct order
- [ ] No cut of discipline-critical guard content proposed without a `[requires confirmation]` tag and a re-test recommendation
- [ ] Findings table is grouped by severity and every row has a line number (or `—` for absent-section findings)
- [ ] Every proposed fix is a concrete diff tagged `[auto-fix]` or `[requires confirmation]`; no `[requires confirmation]` fix applied without explicit approval
- [ ] Trigger testing recommended with sizes and the near-miss requirement, not as a vague suggestion

## Integration

**Called by** [OPTIONAL]: external skill-authoring workflows as a quality gate.
**Standalone:** Invoke directly to audit any existing skill.
**Next:** Re-verify after fixes, then run the trigger test from step 16.
