---
name: feature-implement-review
tags: [feature, implementation, validation, conformance, critical-thinking, review]
description: "Use when an implementation is done or paused and needs an independent check that the code fulfills the spec and plan. Keywords: conformance check, traceability, scope drift, acceptance verification. Produces conformance-report.md; never edits code. Do NOT use for code quality (code-review) or doc health (feature-verify)."
---

# Feature Implement Review

Independently audit whether the built code fulfills the feature's spec and plan — catching silent divergence, scope drift, behavioral failure, and missing proof. Report and route findings; do not edit implementation code.

**Announce at start:** "Reviewing implementation conformance for `${aiDir}/features/{feature}/` against its spec and plan."

## Why this is independent

A reviewer that watched the code get written rationalizes its choices. The audit is therefore performed by a **fresh subagent** (the *conformance reviewer*) that receives only the artifacts and the diff — never the implementation conversation. The skill thread orchestrates inputs and routing; it does not pre-judge conformance itself.

It complements the holistic review that closes `/myspec:feature-implement`: that pass owns cross-phase integration, architecture, and deferred-minor triage, and persists `holistic-review.md`. When that report covers the current code, this audit takes those verdicts as settled and spends its pass on REQ/AC traceability, test proof, and scope drift.

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
- Read `${aiDir}/features/{feature}/holistic-review.md` if present. It is **reusable** when `git diff --stat <its head_sha> HEAD -- . ':(exclude)${aiDir}'` exits 0 with empty output — no code changed since it was written. A non-zero exit (the sha is gone after a rebase or squash) makes it stale, even though the output is empty. Otherwise say it is stale and audit in full.
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
- The reusable holistic report, verbatim, if Step 1 found one.

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
holistic_reused: true | false
verdict_history: complete | partial
---
```

The previous report is the working-tree `conformance-report.md`. If the working tree has none, look in git, because a report that was stashed, deleted or `git rm`ed before this run still has a past:

- `git log -1 --diff-filter=AMR --format=%H -- <report path>` names the newest commit that wrote the report. The filter skips a commit that deleted it, since the report does not exist in that commit.
- It exits 0 with empty output: there is no previous report.
- It exits 0 with a sha: `git show <sha>:<report path>` is the previous report, and it must exit 0 too.
- Either command exits non-zero: the lookup failed. That does not mean there is no past, so stop and tell the user instead of marking the history `complete`.

Overwrite the previous report (the frontmatter records which commit was reviewed), except for its `## Verdict history`. That section is the report's last and records every run:

```markdown
## Verdict history

| Reviewed | Head | Verdict | Critical | High | Medium | Low |
|----------|------|---------|----------|------|--------|-----|
| 2026-05-20 | 9c8b7a6 | gaps | 1 | 1 | 1 | 0 |
| 2026-05-27 | f4e5d6c | conformant | 0 | 0 | 0 | 0 |
```

`delivery-metrics` reads the first decisive row as the feature's first-time conformance result. The rows are the only record of earlier runs: every run overwrites the report, and a squash merge keeps only its last version.

1. Append one row per run, at the bottom, including each Step 6 re-run: `reviewed`, `head_sha`, the verdict, and the number of findings at each severity before routing.
2. Write the Verdict cell as the plain verdict word from the frontmatter (`conformant`, `divergent`, `gaps`, `not-verifiable`), with no emphasis, symbols, or backticks. Keep the heading and header exactly as shown. Do not copy the matrix's `✓ conformant` or `✗ gap`.
3. Copy every existing row across unchanged, in order. Never drop, reorder, or rewrite one.
4. No previous report, in the working tree or in git: create the section with this run's row and set `verdict_history: complete`.
5. A previous report without the section (it predates the section): seed one row from it, using its frontmatter and its findings table. Then add this run's row and set `verdict_history: partial`, because runs before the seeded one are lost.
6. Otherwise keep the previous report's `verdict_history` value.
7. Merge conflict in the section (both branches appended rows): keep every row from both sides in one table, ordered by the Reviewed date, and remove the conflict markers.

Commit the report on its own, as `feature-implement` does with `holistic-review.md`: `git add <report path> && git commit -m "docs({feature}): conformance report ({verdict})" -- <report path>`. An uncommitted report can miss the branch entirely, because `feature-complete` pushes and merges only commits. The exception is HEAD on the default branch (develop mode). There, leave the report uncommitted, because commits are the user's call (`.claude/rules/work-isolation.md`), and say so in Step 7.

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

**Hard constraint — this skill never auto-edits implementation code.** Editing code based on a spec reading is how you introduce *new* divergence. Only after the user picks "Fix now" do you make the change, and you re-run the reviewer on the touched scope to confirm it closed the finding. The re-run is a run: update the frontmatter, append its history row, and commit as in Step 5. "Skip / accept" appends the finding to an "Accepted deviations" section, placed above `## Verdict history`, so the decision is traceable.

### Step 7: Summary and Next Step

- Show what was routed where, and the final verdict.
- On the default branch, say that `conformance-report.md` is uncommitted and must be committed with the work. `delivery-metrics` reads only committed reports.
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
- [ ] `holistic-review.md` passed to the reviewer only when no code changed since its `head_sha`
- [ ] Bidirectional traceability matrix produced (forward + reverse)
- [ ] Behavioral layer run where executable; `not-verifiable` reported where not — never inferred
- [ ] `conformance-report.md` written with frontmatter recording the reviewed commit and verdict
- [ ] `## Verdict history` has this run's row appended (plain verdict word), and every earlier row carried over unchanged
- [ ] `verdict_history: complete` only when no earlier report exists in the working tree or in git
- [ ] Report committed, unless HEAD is the default branch
- [ ] Each finding routed via `AskUserQuestion`; no implementation code edited without "Fix now"
- [ ] Accepted deviations recorded in the report
- [ ] Next step recommended (feature-complete, or fix-and-re-review)

## Integration

**Called by** [OPTIONAL]: `/myspec:feature-implement` (offered as a choice after Final Verification) or run standalone after implementation.
**Next** [REQUIRED]: `/myspec:feature-complete` once conformant; or `/myspec:feature-implement` / `/myspec:feature-spec-sync` to address routed findings, then re-run this review.
