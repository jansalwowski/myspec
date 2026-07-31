---
name: feature-implement-review
tags: [feature-workflow, implementation, validation, conformance, critical-thinking, review]
description: "Use when a feature's implementation is done or paused and needs an independent check that the built code fulfills the spec and plan. Keywords: implementation review, conformance check, traceability, scope drift, acceptance verification. Produces conformance-report.md; never edits code. Do NOT use for spec.md (feature-spec-review), tech-spec.md (feature-tech-spec-review), or doc drift (feature-spec-sync)."
---

# Feature Implement Review

Independently audit whether the built code fulfills the feature's spec and plan — catching silent divergence, scope drift, behavioral failure, and missing proof. Report and route findings; do not edit implementation code.

**Announce at start:** "Reviewing implementation conformance for `${aiDir}/features/{feature}/` against its spec and plan."

## Why this is independent

A reviewer that watched the code get written rationalizes its choices. The audit is therefore performed by a **fresh subagent** (the *conformance reviewer*) that receives only the artifacts and the diff — never the implementation conversation. The skill thread orchestrates inputs and routing; it does not pre-judge conformance itself.

This is distinct from the in-flight holistic review inside `/myspec:feature-implement`: that is a quick gate during execution. It is a deeper, retrospective, independent audit that persists a report and routes findings with the user.

## Prerequisites

- `spec.md` and `tech-spec.md` exist for the feature.
- An `implementation-plan.md` exists (or the tech-spec Implementation Steps stand in for it).
- Implementation work has happened on a branch — there is a diff to review.

## Workflow

### Step 1: Load Context

- Read `${aiDir}/features/{feature}/spec.md` — acceptance criteria, requirements, user stories.
- Read `${aiDir}/features/{feature}/tech-spec.md` — Implementation Steps and **File Inventory** (the planned paths — ground truth for where code should live).
- Read `${aiDir}/features/{feature}/implementation-plan.md` if present — task list and checkbox state.
- Read `${aiDir}/features/{feature}/scenarios.md` if present — behavioral expectations.
- Read `.claude/rules/` convention files and `.claude/verification.json` if present.
- If a sub-feature: also read the parent `spec.md` / `tech-spec.md`.

### Step 2: Establish the Diff

Resolve the diff range that represents "what was built" (REQUIRED reference: [`skills/_shared/git-helpers.md`](../_shared/git-helpers.md)):

1. Resolve the default branch (main vs master).
2. `BASE_SHA = git merge-base HEAD <default-branch>`.
3. Review range is `BASE_SHA..HEAD`. Capture `git diff BASE_SHA..HEAD --stat` for the changed-file set.

If `HEAD` is the default branch (work was committed straight to main), tell the user the diff range is ambiguous and ask for an explicit base ref before continuing.

### Step 3: Build the Reviewer Input Packet

Assemble, to paste inline into the reviewer prompt (the subagent must not parse files itself):

- All acceptance criteria and requirements from `spec.md`.
- The planned File Inventory paths and Implementation Steps from `tech-spec.md`.
- The plan task list with checkbox state.
- The scenarios (if any) and which are runnable.
- The diff range (`BASE_SHA..HEAD`) and changed-file list.

### Step 4: Dispatch the Conformance Reviewer

Dispatch one fresh subagent using [`./conformance-reviewer-prompt.md`](./conformance-reviewer-prompt.md) at the `premium` tier (controller maps tier → concrete model). It must:

- Locate code per requirement using **planned paths → diff → reconcile → semantic search within the changed files** (see Code Location below).
- Build the bidirectional traceability matrix and run the four conformance checks.
- Run the behavioral layer only where scenarios/tests are executable; where they are not, say so explicitly rather than infer "works" from reading code.
- Return a report: traceability matrix, findings table by severity, and a verdict.

### Step 5: Persist the Report

Write the reviewer's output to `${aiDir}/features/{feature}/conformance-report.md` with frontmatter:

```yaml
---
feature: {feature}
reviewed_range: {BASE_SHA}..{HEAD}
base_sha: {BASE_SHA}
head_sha: {HEAD}
reviewed: {YYYY-MM-DD}
verdict: conformant | divergent | gaps | not-verifiable
---
```

If a previous `conformance-report.md` exists, overwrite it (the frontmatter records which commit was reviewed).

### Step 6: Present Findings and Route

Show the traceability matrix and findings table. Then, **for each finding (or batched by target)**, use `AskUserQuestion` to let the user choose the disposition:

```
question: "Finding {id} ({severity}): {one-line}. How do you want to handle it?"
header:   "Route finding"
options:
  - "Fix now"                  → fix in this session (code or tests)
  - "Route to feature-implement" → re-open implementation to address it
  - "Route to feature-spec-sync" → it is documentation drift, not a code defect
  - "Skip / accept"            → record as an accepted deviation in the report
```

**Hard constraint — this skill never auto-edits implementation code.** Editing code based on a spec reading is how you introduce *new* divergence. Only after the user picks "Fix now" do you make the change, and you re-run the reviewer on the touched scope to confirm it closed the finding. "Skip / accept" appends the finding to a "Accepted deviations" section in the report so the decision is traceable.

### Step 7: Summary and Next Step

- Show what was routed where, and the final verdict.
- If verdict is `conformant` (or all blocking findings resolved/accepted): recommend `/myspec:feature-complete`.
- If findings were routed to `feature-implement` or `feature-spec-sync`: recommend running those, then re-running this review.

## The Four Conformance Checks

| Check | Failure mode caught | How the reviewer detects it |
|-------|---------------------|-----------------------------|
| **Forward trace** | Silent divergence | For each acceptance criterion / plan task, find the implementing code and read whether it does what was specified — not just that something exists |
| **Reverse trace** | Scope drift | For each changed file/symbol, find the plan item it serves; code with no plan item = undocumented scope, planned-but-absent = skipped/faked step |
| **Test trace** | No proof / traceability | Each criterion must map to a test that proves it; empty test column is a finding |
| **Behavioral** | Doesn't actually work | Run `scenarios.md` / the test suite where executable; pass/fail per criterion. Where not runnable, report `not-verifiable` for that criterion — never infer "works" from code reading |

The behavioral check is categorically more expensive and is not always runnable. It is a *layer* on top of the static traceability engine, not an equal — a green static trace with `not-verifiable` behavior is reported as exactly that.

## Constraints

- **Review from fresh context.** The conformance reviewer is a dispatched subagent that sees only the artifacts and the diff, because a reviewer that watched the code get written rationalizes its choices. The skill thread orchestrates; it does not pre-judge conformance.
- **Never auto-edit implementation code.** Editing code from a spec reading introduces new divergence. Code changes only after the user picks "Fix now" in Step 6, and the reviewer re-runs on the touched scope to confirm the finding closed.
- **Never infer behavior from reading code.** Run scenarios/tests where executable; where they cannot run, report the criterion as `not-verifiable` rather than concluding it works.

## Code Location

Locate the code implementing each requirement in this order:

1. **Planned paths** — the tech-spec File Inventory says where it should be. Ground truth.
2. **Diff** — what actually changed in `BASE_SHA..HEAD`. Reconciling planned paths against the diff *is* the scope-drift detector: planned-but-not-in-diff = skipped; in-diff-but-not-planned = creep.
3. **Semantic search within the changed files** — pin each requirement to a specific symbol/line. Search only inside the diff's file set, not the whole repo, to keep the mapping grounded in what this work changed.

## Output Format

### Traceability Matrix

```markdown
| Spec/plan item | Implementing code | Test | Behavioral | Verdict |
|----------------|-------------------|------|------------|---------|
| AC-1: reject expired tokens | src/auth.ts:88 | src/auth.test.ts:40 | ✅ pass | ✓ conformant |
| Plan task 3.2 | — | — | — | ✗ gap (claimed done, no code) |
| AC-4: rate-limit login | src/auth.ts:120 | — | not-verifiable | ⚠ no proof |
| — | src/cache.ts (new) | — | — | ⚠ scope drift (no plan item) |
```

### Findings Table

**REQUIRED:** Follow [../\_shared/review-output.md](../_shared/review-output.md) for the table format and tagging rules (this skill uses `Check` for the `Dimension` column). Example row:

```markdown
| Critical | Forward trace | AC unmet | src/auth.ts | 88 | Accepts tokens whose exp is in the past; AC-1 requires rejection |
```

## Severity Classification

| Severity | Definition | Must resolve before |
|----------|------------|---------------------|
| **Critical** | An acceptance criterion is unmet or contradicted by the code | `/myspec:feature-complete` |
| **High** | Scope drift, a skipped/faked plan step, or a core path with no test | `/myspec:feature-complete` |
| **Medium** | A criterion met but unproven (missing test), minor divergence | merge / before next feature |
| **Low** | Not-verifiable behavioral checks, polish, doc nits | nice to have |

## Verification Checklist

- [ ] Diff range resolved against the default branch (or explicit base confirmed with user)
- [ ] Conformance reviewer dispatched as a fresh subagent with inputs pasted inline
- [ ] Bidirectional traceability matrix produced (forward + reverse)
- [ ] Behavioral layer run where executable; `not-verifiable` reported where not — never inferred
- [ ] `conformance-report.md` written with frontmatter recording the reviewed commit and verdict
- [ ] Each finding routed via `AskUserQuestion`; no implementation code edited without "Fix now"
- [ ] Accepted deviations recorded in the report
- [ ] Next step recommended (feature-complete, or fix-and-re-review)

## Integration

**Called by:** `/myspec:feature-implement` (offered as a choice after Final Verification) or run standalone after implementation.
**Next:** `/myspec:feature-complete` once conformant; or `/myspec:feature-implement` / `/myspec:feature-spec-sync` to address routed findings, then re-run this review.
