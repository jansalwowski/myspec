# `/myspec:feature-implement-review` — examples

Independent, retrospective audit of whether the **built code** fulfills the feature's spec and plan. A fresh subagent (the *conformance reviewer*) sees only the artifacts and the diff — never the implementation conversation — builds a bidirectional traceability matrix, runs four conformance checks, and returns a verdict. The skill persists `conformance-report.md` and routes each finding via `AskUserQuestion`. **Never edits implementation code unless the user explicitly picks "Fix now."**

> **Not the same as `/myspec:code-review`.** Code-review asks *is this code good* (quality, standards, bugs). This skill asks *is this the code we agreed to build* (every acceptance criterion traced to implementing code and a test, no undocumented scope). A file can pass code-review and still fail conformance — clean code that does the wrong thing.

**Contents**

- [Clean conformance pass — built matches spec and plan](#clean-conformance-pass--built-matches-spec-and-plan)
- [Scope drift detected — code does what the spec never asked for](#scope-drift-detected--code-does-what-the-spec-never-asked-for)
- [Missing acceptance criterion caught and routed](#missing-acceptance-criterion-caught-and-routed)

---

## Clean conformance pass — built matches spec and plan

The base case: implementation is done, every acceptance criterion traces to code and a passing test, nothing extra was added. The report is the green light into `feature-complete`.

### Setup

`saved-searches` was just implemented on branch `feat/saved-searches`. Spec has four acceptance criteria (AC-1 through AC-4), tech-spec lists a File Inventory of 4 created / 1 modified path, the plan's tasks are all checked off, and `scenarios.md` has three scenarios — all runnable against the test DB. The user finished `/myspec:feature-implement` and chose to run a conformance review before completing.

### Invocation

```
/myspec:feature-implement-review saved-searches
```

### Skill flow

The skill announces: *"Reviewing implementation conformance for `${aiDir}/features/saved-searches/` against its spec and plan."* Then:

1. **Load context** — reads `spec.md`, `tech-spec.md` (File Inventory + Implementation Steps), `implementation-plan.md`, `scenarios.md`, and `.claude/rules/`.
2. **Establish the diff** — resolves default branch `main`, `BASE_SHA = git merge-base HEAD main`, review range `BASE_SHA..HEAD`. Captures the changed-file set from `git diff BASE_SHA..HEAD --stat`.
3. **Build the input packet** — pastes the four ACs, the planned File Inventory paths and steps, the checked-off task list, and the three scenarios (all marked runnable) inline.
4. **Dispatch the conformance reviewer** — one fresh `premium`-tier subagent that never saw the implementation conversation. It locates code via planned paths → diff → semantic search within the changed files, builds the matrix, and runs the four checks (forward, reverse, test, behavioral).

The reviewer returns:

```
Traceability matrix

| Spec/plan item                    | Implementing code            | Test                          | Behavioral | Verdict       |
|-----------------------------------|------------------------------|-------------------------------|------------|---------------|
| AC-1: save a search by name       | src/searches/save.ts:24      | src/searches/save.test.ts:18  | ✅ pass     | ✓ conformant  |
| AC-2: list saved searches         | src/searches/list.ts:12      | src/searches/list.test.ts:9   | ✅ pass     | ✓ conformant  |
| AC-3: rename a saved search       | src/searches/rename.ts:30    | src/searches/rename.test.ts:22| ✅ pass     | ✓ conformant  |
| AC-4: 50-search cap per user      | src/searches/save.ts:41      | src/searches/save.test.ts:55  | ✅ pass     | ✓ conformant  |
| Plan task 1–6                     | (all mapped above)           | —                             | —          | ✓ conformant  |

Findings: none

Verdict: conformant — every criterion met, proven by a passing test, and exercised by a runnable scenario.
```

5. **Persist the report** — writes `${aiDir}/features/saved-searches/conformance-report.md`:

```yaml
---
feature: saved-searches
reviewed_range: a1b2c3d..f4e5d6c
base_sha: a1b2c3d
head_sha: f4e5d6c
reviewed: 2026-05-27
verdict: conformant
---
```

6. **Present and route** — no findings, so there is nothing to route. The skill shows the matrix and verdict.
7. **Next step** — recommends `/myspec:feature-complete saved-searches`.

### Result

`conformance-report.md` written with verdict `conformant`. No implementation code touched. The user proceeds to `feature-complete`.

### Why this example matters

- **A `conformant` verdict is a real, signed artifact — not a no-op.** The frontmatter pins the exact commit reviewed (`head_sha`), so "this was audited" is verifiable later. If code changes after this, the recorded SHA shows the audit is stale.
- **"Behavioral: ✅ pass" requires runnable proof.** The reviewer ran the scenarios; it did not read the code and conclude it works. Every behavioral cell here is backed by an actually-executed test. The clean column is earned, not assumed.
- **Independence is the whole point.** The reviewer never saw the implementation conversation, so it can't rationalize a shortcut the implementer talked itself into. A self-review of one's own code would have rubber-stamped it.

---

## Scope drift detected — code does what the spec never asked for

The reverse-trace case: the implementation added a capability nobody planned. The code may even be good — but it's undocumented scope, and the spec/plan no longer describe what was built.

### Setup

`saved-searches` again, but during implementation the developer noticed list queries were slow and added an in-memory result cache (`src/searches/cache.ts`, ~80 lines, plus wiring in `list.ts`). The cache isn't in any acceptance criterion, isn't in the tech-spec File Inventory, and isn't a plan task. Tests for the four ACs still pass.

### Invocation

```
/myspec:feature-implement-review saved-searches
```

### Skill flow

Same load → diff → packet → dispatch flow. During **reverse trace**, the reviewer walks each changed file looking for the plan item it serves and finds `src/searches/cache.ts` serves none. It returns:

```
Traceability matrix

| Spec/plan item              | Implementing code        | Test                          | Behavioral | Verdict          |
|-----------------------------|--------------------------|-------------------------------|------------|------------------|
| AC-1: save a search by name | src/searches/save.ts:24  | src/searches/save.test.ts:18  | ✅ pass     | ✓ conformant     |
| AC-2: list saved searches   | src/searches/list.ts:12  | src/searches/list.test.ts:9   | ✅ pass     | ✓ conformant     |
| AC-3: rename a saved search | src/searches/rename.ts:30| src/searches/rename.test.ts:22| ✅ pass     | ✓ conformant     |
| AC-4: 50-search cap         | src/searches/save.ts:41  | src/searches/save.test.ts:55  | ✅ pass     | ✓ conformant     |
| —                           | src/searches/cache.ts    | —                             | —          | ⚠ scope drift    |

Findings (most severe first)

| Severity | Check         | Issue       | File                  | Line(s) | Finding                                                                                                  |
|----------|---------------|-------------|-----------------------|---------|----------------------------------------------------------------------------------------------------------|
| High     | Reverse trace | Scope drift | src/searches/cache.ts | 1–80    | In-memory result cache serves no acceptance criterion, File Inventory path, or plan task. Undocumented scope; invalidation behavior is also untested. |

Verdict: divergent — code does something beyond the spec/plan in 1 place.
```

The skill writes `conformance-report.md` with `verdict: divergent`, then routes the one finding via `AskUserQuestion`:

```
Finding F1 (High): src/searches/cache.ts adds an unplanned result cache. How do you want to handle it?
  - Fix now
  - Route to feature-implement
  - Route to feature-spec-sync
  - Skip / accept
```

The cache is sound and the user wants to keep it, so they pick **Route to feature-spec-sync** — the code is fine, the *documentation* is what's out of date (the spec and tech-spec should describe the cache, and it needs a test). The skill records the disposition and recommends running `/myspec:feature-spec-sync saved-searches` to bring the docs up to the code, then re-running this review.

### Result

`conformance-report.md` written with verdict `divergent` and the routed finding recorded. **No code edited** — the skill never auto-touches implementation. The user runs `feature-spec-sync`, adds a cache test, then re-runs the review to land on `conformant`.

### Why this example matters

- **Scope drift is invisible to forward-only checks.** All four ACs trace cleanly to code and tests — a forward trace alone would call this done. Only the *reverse* trace (every changed file must serve a plan item) surfaces the cache. That bidirectional matrix is what separates this skill from "did we build the features."
- **"Good code" and "drift" are orthogonal.** The cache might pass code-review with flying colors. Conformance review still flags it, because the spec/plan no longer describe what shipped — a future reader trusting the docs would be wrong.
- **Routing respects the nature of the gap.** This wasn't a code defect, so it routed to `feature-spec-sync` (fix the docs), not `feature-implement` (change the code) or "Fix now" (rip the cache out). The four routing options exist precisely so the disposition matches the cause.

---

## Missing acceptance criterion caught and routed

The forward-trace + test-trace case: a plan task is checked off, but the behavior it claims doesn't exist in the code. The "done" checkbox was optimistic.

### Setup

`saved-searches` has a fifth criterion added late in planning — **AC-5: deleting a saved search soft-deletes it (sets `deleted_at`) rather than hard-deleting, so it can be restored within 30 days.** The implementation-plan task "5. Soft-delete with 30-day restore window" is checked `[x]`. But the developer ran out of time and wired a plain hard `DELETE` in `src/searches/delete.ts`; there's no `deleted_at` column write and no restore path. The task got checked off anyway.

### Invocation

```
/myspec:feature-implement-review saved-searches
```

### Skill flow

The reviewer runs **forward trace** for AC-5: it locates `src/searches/delete.ts`, reads what it actually does, and finds a hard delete — not the specified soft-delete. **Test trace** finds no test asserting `deleted_at` or restore. The matrix:

```
Traceability matrix

| Spec/plan item                          | Implementing code           | Test                            | Behavioral | Verdict                |
|-----------------------------------------|-----------------------------|---------------------------------|------------|------------------------|
| AC-1 .. AC-4                            | (mapped, all conformant)    | (mapped)                        | ✅ pass     | ✓ conformant           |
| AC-5: soft-delete + 30-day restore      | src/searches/delete.ts:14   | —                               | ✅ pass*    | ✗ gap / contradiction  |
| Plan task 5 (marked [x] done)           | src/searches/delete.ts:14   | —                               | —          | ✗ faked-done step      |

* the delete endpoint runs and returns 200 — but it hard-deletes; the *specified* behavior is absent.

Findings (most severe first)

| Severity | Check         | Issue              | File                    | Line(s) | Finding                                                                                                              |
|----------|---------------|--------------------|-------------------------|---------|---------------------------------------------------------------------------------------------------------------------|
| Critical | Forward trace | AC-5 unmet         | src/searches/delete.ts  | 14      | Issues a hard `DELETE`. AC-5 requires a soft-delete (set `deleted_at`) with a 30-day restore path. The criterion is contradicted, not merely missing — records are unrecoverable. |
| High     | Reverse trace | Faked-done step    | implementation-plan.md  | —       | Plan task 5 is checked `[x]` but no soft-delete or restore code exists. The checkbox does not reflect the code.      |
| Medium   | Test trace    | No proof           | src/searches/delete.ts  | 14      | No test covers deletion behavior at all; even the hard-delete is unproven.                                           |

Verdict: gaps — a criterion (AC-5) and a plan step have no conforming implementation.
```

The skill writes `conformance-report.md` with `verdict: gaps`, then routes each finding via `AskUserQuestion`. For the Critical AC-5 finding the user picks **Route to feature-implement** — this is missing/wrong code that needs real implementation work, not a doc fix and not a quick in-session patch. The High faked-done finding is part of the same work (the checkbox gets corrected when the task is actually done), so it's batched with the same disposition.

### Result

`conformance-report.md` written with verdict `gaps`. The Critical and High findings routed to `feature-implement`; the Medium test gap will be closed by the same re-implementation. **No code edited by this skill.** Because a Critical finding is unresolved, the skill does *not* recommend `feature-complete` — it recommends `/myspec:feature-implement saved-searches` to build AC-5 properly, then re-running this review to confirm the gap closed.

### Why this example matters

- **A checked box is a claim, not proof.** The plan said task 5 was done; the code said otherwise. The reverse trace treats "marked done with no code behind it" as a first-class finding — exactly the failure mode that slips through when the implementer also reports completion.
- **"Contradicted" is worse than "missing," and severity reflects it.** A hard delete isn't an absent feature — it's the *opposite* of the specified behavior, and it destroys data the spec promised was recoverable. That's why it's Critical, and Critical findings block `feature-complete` by definition.
- **Behavioral pass ≠ conformant.** The delete endpoint runs and returns 200, so a naive "does it work" check is green. The reviewer reads *what* it does against the criterion, not just *whether* it executes — the `not-verifiable`-vs-`pass` discipline cuts both ways.
- **Routing gates completion.** Unlike a clean pass, this run deliberately withholds the `feature-complete` recommendation while a Critical finding stands. The skill is a gate, not just a reporter.
