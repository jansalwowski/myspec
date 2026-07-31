---
name: code-review
description: "Use when reviewing implemented code for quality, standards conformance, and potential issues — after a feature is built, before feature-complete or a PR. Keywords: code review, review changes, review diff, pre-merge review, find bugs in changes. Universal dimensions plus per-repo rules. Do NOT use for spec.md (feature-spec-review), tech-spec.md (feature-tech-spec-review), or SKILL.md (skill-verify)."
tags: [code-review, quality, validation, critical-thinking, review]
---

# Code Review

Reviews implemented code against universal engineering dimensions plus project-specific rules. The dimensions are language-neutral; everything technology- or repo-specific comes from configuration, so the skill stays technology-agnostic. The product is a **findings report with a verdict** — fixes are offered, not forced.

Configure with `/myspec:setup code-review` (writes `.claude/rules/code-review.md` and seeds `.myspec.json`). The skill runs without configuration using universal dimensions only.

## Workflow

1. **Load Configuration**
   - Read `.myspec.json` `codeReview` block if present: `verbosity`, `scope`, `autoFix`. Apply defaults (`standard`, `feature`, `off`) for any missing key.
   - Read `.claude/rules/code-review.md` if it exists — its `## Standards` and `## Suppress` sections. Absent → note "no project rules configured; reviewing on universal dimensions only" and suggest `/myspec:setup code-review`.
   - Read `${aiDir}/conventions/` and other `.claude/rules/` convention files if present, for additional project standards.

2. **Resolve Scope** (what to review)
   - `feature` (default): the current feature branch's changes. Detect the default branch (`main`/`master`), then review `git diff <merge-base>...HEAD` plus uncommitted changes. If a feature name was passed, narrow to files under that feature's inventory.
   - `working`: uncommitted changes only (`git diff HEAD` + untracked).
   - `ask`: prompt the user — working diff / branch range / explicit paths.
   - An explicit path or range argument always overrides the configured default.
   - If the resolved diff is empty: report "nothing to review" and stop.

3. **Read the Changes in Context**
   - Read each changed file in full, not just the hunk — a hunk's correctness often depends on surrounding code.
   - For non-trivial changes, follow the data flow across files (where inputs come from, where outputs go). Review the ripple, not just the diff.

4. **Apply Review Dimensions** (all 8 below, phrased as universal questions)
   - Skip any concern the project's linter/formatter already enforces — defer formatting and style mechanics to tooling, spend the budget on judgment.
   - Apply every rule in `## Standards`; stay silent on anything named in `## Suppress`.

5. **False-Positive Filter** (before emitting anything)
   - For each candidate finding, re-check it against the actual code. Drop it unless you can point to a concrete `file:line` and state a specific consequence ("if X then Y"). No hand-waving, no "consider maybe".
   - Drop anything already handled elsewhere in the changeset, or guarded by a check you missed on first pass.

6. **Filter by Verbosity**
   - `chill`: emit Critical + High only.
   - `standard` (default): emit Critical + High + Medium.
   - `thorough`: emit all, including Low / nits.

7. **Present Findings**
   - Output the findings table (see Output Format), grouped Critical → High → Medium → Low.
   - Every finding carries `file:line` and a one-line *why*.
   - Lead with what the change does well (1–2 lines) before the issues — keeps the review collaborative, not punitive.

8. **Render Verdict**
   - `Approve` — no Critical/High findings.
   - `Approve with fixes` — Critical/High exist but are localized and clearly fixable.
   - `Needs rework` — Critical findings that imply a design or approach problem.

9. **Offer Fixes**
   - Default (`autoFix: off`): present proposed fixes as diffs and ask which to apply (All / Critical+High / Individually / None).
   - `autoFix: style-only`: apply mechanical fixes (rename, dead-code removal, obvious guard) without asking; still confirm anything that changes behavior.
   - Never auto-apply a fix that changes behavior without confirmation.

## Review Dimensions Reference

Universal — no language or framework assumptions. Specifics come from project rules.

| Dimension | What to Check |
|-----------|---------------|
| **Correctness** | Does it do what the change intends? Boundary/off-by-one, null/empty/absent cases, wrong operator, inverted condition, incorrect default |
| **Error Handling** | Failures surfaced or swallowed? External calls / I/O guarded? No empty catch, no ignored return that signals failure |
| **Input & Trust** | External input validated before use? Injection-class risks (query, command, path, template)? Secrets not hardcoded or logged |
| **Resource & Lifecycle** | Acquired resources released (handles, connections, locks, listeners)? No leak on the error path? Concurrency/ordering hazards |
| **Maintainability** | Reasonable complexity, no needless duplication, names reveal intent, no dead code. Linter-owned style is out of scope |
| **Test Adequacy** | New/changed logic covered? Tests assert behavior (not just "it ran")? Edge and failure cases exercised |
| **Consistency** | Matches patterns in `## Standards`, `${aiDir}/conventions/`, and `.claude/rules/`. Doesn't reinvent an existing project utility |
| **YAGNI / Scope** | No speculative abstraction, premature optimization, or scope beyond the change's intent |

## Configuration

`.myspec.json` `codeReview` block (all optional):

```json
{
  "codeReview": {
    "verbosity": "standard",
    "scope": "feature",
    "autoFix": "off"
  }
}
```

`.claude/rules/code-review.md` (prose, path-scoped — authored by `/myspec:setup code-review`):

```markdown
## Standards
Positive rules the reviewer enforces. Scope to paths in prose.
- Repository methods must handle the not-found case explicitly.
- In src/api/**: every handler validates its request body before use.

## Suppress
What the reviewer must stay silent about (owned by tooling or intentional).
- Don't comment on formatting or import order — the linter owns it.
- Don't flag console logging in scripts/**.
```

## Output Format

**REQUIRED:** Follow [../\_shared/review-output.md](../_shared/review-output.md) for the findings table, fix-proposal shape, and tagging rules. Example row for this skill:

```markdown
| Critical | Input & Trust | Unvalidated path | src/files/read.ts | 42 | User-supplied `name` concatenated into FS path — directory traversal |
```

### Verdict

```markdown
**Verdict: Approve with fixes** — 1 Critical, 1 High, both localized.
Resolve the Critical (path traversal) before merge.
```

## Severity Classification

| Severity | Definition | Must Fix Before |
|----------|------------|-----------------|
| **Critical** | Security hole, data loss, crash, or incorrect result on a normal path | merge — blocks the verdict |
| **High** | Likely bug, swallowed failure, or untested critical logic | merge |
| **Medium** | Maintainability, missing non-critical test, minor edge case | follow-up acceptable |
| **Low** | Polish, minor duplication, naming | advisory only |

Never downgrade a severity to make a verdict look cleaner.

## Constraints

- Never auto-apply a fix that changes behavior without confirmation — a wrong "fix" to working code is worse than a flagged finding the author can judge.
- Never downgrade a severity to produce a cleaner verdict — the verdict exists to be honest about risk, not to reassure.
- Never emit a finding without a concrete `file:line` and a stated consequence — ungrounded review trains the author to ignore it.
- Defer formatting and style mechanics to the project's linter — duplicating tooling spends review budget on noise instead of judgment.
- The review is the product. Do not block on producing fixes; a clear findings report with a verdict is a complete result on its own.

## Verification Checklist

- [ ] Loaded `codeReview` config and applied defaults for missing keys
- [ ] Loaded `.claude/rules/code-review.md` (or noted its absence) and project conventions
- [ ] Resolved scope; reported "nothing to review" if the diff was empty
- [ ] Read changed files in full, not just hunks
- [ ] Checked all 8 universal dimensions plus every `## Standards` rule
- [ ] Stayed silent on `## Suppress` items and linter-owned style
- [ ] Ran the false-positive filter — every finding has `file:line` + a concrete why
- [ ] Filtered output by configured verbosity
- [ ] Led with strengths, then findings grouped by severity
- [ ] Rendered an explicit verdict
- [ ] Offered fixes per `autoFix` policy; no behavior-changing fix applied without confirmation

## Integration

**Called after:** `/myspec:feature-implement` — review the built code before completing.
**Configured by:** `/myspec:setup code-review` — writes `.claude/rules/code-review.md` and seeds the `.myspec.json` `codeReview` block.
**Next:** `/myspec:feature-complete` — once Critical/High findings are resolved.
