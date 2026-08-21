# `/myspec:code-review` — examples

Reviews implemented code against eight universal engineering dimensions plus project-specific rules loaded from `.claude/rules/code-review.md`. Technology-agnostic: the dimensions make no language assumptions; everything repo-specific comes from configuration. The product is a **findings report with a verdict** — fixes are *offered*, not forced, and no behavior-changing fix is applied without confirmation.

> **Related**: Configured by [setup.md](setup.md) (`/myspec:setup code-review`), which writes the project rules these scenarios consume. Runs after [feature-implement.md](feature-implement.md) and before [feature-complete.md](feature-complete.md). The scenarios here focus on the review skill itself.

**Contents**

- [Clean pass — Approve, no significant findings](#clean-pass--approve-no-significant-findings)
- [Mixed findings ranked across severities](#mixed-findings-ranked-across-severities)
- [Project-specific rule violation caught](#project-specific-rule-violation-caught)

---

The three scenarios use a running feature: `export-jobs`, a background export pipeline that lets users request a CSV of their data and download it when ready. The repo has been configured with `/myspec:setup code-review`, producing this `.claude/rules/code-review.md`:

```markdown
# Code Review Rules

## Focus
Correctness and data-trust first. src/api/** and src/jobs/** get extra scrutiny.

## Standards
- Repository methods must handle the not-found case explicitly (return/throw, never silent null).
- In src/api/**: every handler validates its request body before use.
- Background jobs in src/jobs/** must be idempotent — safe to re-run on retry.

## Suppress
- Formatting and import order — the linter owns it.
- console logging in scripts/**.
```

`.myspec.json` carries `{ "codeReview": { "verbosity": "standard", "scope": "feature", "autoFix": "off" } }` — so reviews emit Critical + High + Medium, review the feature branch's diff, and only propose fixes.

---

## Clean pass — Approve, no significant findings

The base case: a small, well-formed change. Useful as a pre-merge sanity check after a tightly-scoped task.

### Setup

A one-task follow-up to `export-jobs` adds a `Content-Disposition` header so the download arrives with a sensible filename instead of the job UUID. The diff touches a single handler in `src/api/export-download.ts` (~8 lines) and adds one test. The author runs the review before completing.

### Invocation

```
/myspec:code-review
```

### Skill flow

The skill loads the `codeReview` config (defaults already explicit), reads `.claude/rules/code-review.md`, and resolves scope to `feature` — `git diff main...HEAD` plus uncommitted changes, which is just the two files. It reads both files in full, walks all 8 dimensions, applies the three project `## Standards` rules, and runs the false-positive filter. Nothing survives it.

```
Code Review: export-jobs (feature scope, 2 files, +14/−2)
──────────────────────────────────────────────────────────

Strengths
  • Filename is sanitized before it reaches the header — no header-injection
    surface from the user-controlled job name.
  • Added test asserts the actual Content-Disposition value, not just a 200.

| Severity | Dimension | Issue | File | Line(s) | Finding |
|----------|-----------|-------|------|---------|---------|
| (none)   |           |       |      |         | No Critical/High/Medium findings |

Project rules checked: not-found handling (n/a — no repo method touched),
api body validation (n/a — GET handler, no body), job idempotency
(n/a — no src/jobs/** change). Suppress: linter-owned style not reviewed.

**Verdict: Approve** — no Critical, High, or Medium findings.
Safe to proceed to /myspec:feature-complete.
```

No fixes offered — there's nothing to fix.

### Result

No files modified. Report printed to the conversation. The author proceeds to `feature-complete`.

### Why this example matters

- **A clean verdict is a real outcome, not a placeholder.** `Approve` with an explicit "safe to proceed" is the signal `feature-complete` is waiting for.
- **Project rules that don't apply are still accounted for.** The report names each `## Standards` rule and marks it `n/a` with a reason — the author can see the rule was considered, not skipped by accident.
- **Strengths lead.** Even on a trivial diff the skill opens with what the change does well, keeping the review collaborative rather than a pass/fail gate.
- **`standard` verbosity means Low findings stay quiet.** A nitpick on this diff (e.g. a slightly long line) is below the threshold and correctly never surfaces — the review spends its budget on judgment, not noise.

---

## Mixed findings ranked across severities

The interesting case: a substantial change with issues at several severities. The findings table ranks them, the verdict reflects the worst of them, and fixes are offered per the `autoFix: off` policy.

### Setup

The main `export-jobs` implementation just landed on the branch: a request handler (`src/api/export-request.ts`), a background worker (`src/jobs/export-worker.ts`), a repository (`src/repos/export-job-repo.ts`), and a CSV serializer (`src/lib/csv.ts`). The author runs the review before completing the feature.

### Invocation

```
/myspec:code-review
```

### Skill flow

Scope resolves to the feature diff (4 source files + 2 tests). The skill reads each file in full and follows the data flow: request → repo insert → worker pickup → CSV write → download. It walks the 8 dimensions, applies the three project rules, runs the false-positive filter (dropping two candidates that were already guarded upstream), and filters to `standard` verbosity.

```
Code Review: export-jobs (feature scope, 6 files, +312/−4)
──────────────────────────────────────────────────────────

Strengths
  • Clean separation: handler validates, repo persists, worker processes.
  • Worker streams rows instead of buffering the whole result set.

| Severity | Dimension | Issue | File | Line(s) | Finding |
|----------|-----------|-------|------|---------|---------|
| Critical | Input & Trust | Formula injection | src/lib/csv.ts | 31 | User cell values starting `=`/`+`/`-`/`@` written raw — opens as a formula in Excel (CSV injection) |
| High | Resource & Lifecycle | Job not idempotent | src/jobs/export-worker.ts | 58-74 | Retry re-appends to an existing file instead of truncating — a retried job produces a doubled CSV |
| High | Error Handling | Swallowed failure | src/jobs/export-worker.ts | 81 | `catch {}` around the upload marks the job `complete` even when upload throws — user downloads an empty file |
| Medium | Test Adequacy | Retry path untested | src/jobs/export-worker.ts | 58 | No test exercises a re-run; the idempotency bug above would have been caught |
| Medium | Test Adequacy | Change-detector test | src/api/export-request.test.ts | 27 | Asserts `repo.insert` received exactly the object the handler builds — the expectation restates the implementation, so it fails on every refactor and never on a wrong field; assert hand-derived literals |

Project rules checked: api body validation ✓ (export-request.ts:19 validates),
not-found handling ✓ (repo throws NotFoundError), job idempotency ✗ → High above.

**Verdict: Approve with fixes** — 1 Critical, 2 High, all localized to csv.ts
and export-worker.ts. Resolve the Critical (CSV injection) and both High
items before merge. Then re-run /myspec:code-review.

Proposed fixes ready (autoFix: off — nothing applied):
  Apply which? [All / Critical+High / Individually / None]
```

The author picks **Critical+High**; the skill presents three diffs (prefix-escape risky cells in `csv.ts`, truncate-on-start in the worker, surface the upload error and leave the job `failed`), applies them on confirmation, and leaves the Medium test findings for the author to address.

### Result

Three fixes applied after confirmation. The Medium findings are left as noted follow-ups. A second `code-review` run comes back `Approve`.

### Why this example matters

- **Severity drives the verdict, not the other way around.** One Critical forces `Approve with fixes` and names what blocks merge. The skill never downgrades a finding to make the verdict read cleaner.
- **The data-flow read is what catches the cross-file bugs.** The doubled-CSV and the empty-file-marked-complete bugs only surface once you trace request → worker → upload across files — reviewing the worker hunk in isolation misses both.
- **`autoFix: off` keeps the author in control.** Behavior-changing fixes (truncate-on-retry, fail-on-upload-error) are *proposed* as diffs and applied only on an explicit choice — a wrong "fix" to working code is worse than a flagged finding.
- **The Mediums survive the cut, the Lows don't.** At `standard` verbosity the missing retry test (it directly relates to a High bug) and the change-detector test are reported, while pure polish stays silent.
- **Test Adequacy asks "would this fail if the behavior broke?"** The change-detector finding flags a test that *exists* but can't fail on a real bug — apparent coverage the mutation probe exposes as decoration.

---

## Project-specific rule violation caught

The configuration case: a finding that exists *only* because of a `## Standards` rule in `.claude/rules/code-review.md`. On the universal dimensions alone the code is fine — the project rule is what makes it a finding.

### Setup

A follow-up task adds a `findByDownloadToken` lookup to `src/repos/export-job-repo.ts` so the download endpoint can resolve a job from its share token. The query returns `null` when no row matches, and the new code path quietly passes that `null` along. On universal correctness this is arguably defensible — but the project's first `## Standards` rule is explicit: *repository methods must handle the not-found case explicitly (return/throw, never silent null).*

### Invocation

```
/myspec:code-review src/repos/export-job-repo.ts
```

(An explicit path overrides the configured `feature` scope — the author wants just this file.)

### Skill flow

The skill reads the file in full, walks the dimensions (which raise nothing on their own), then applies the `## Standards` rules. Rule 1 fires. The false-positive filter confirms it with a concrete `file:line` and a stated consequence.

```
Code Review: src/repos/export-job-repo.ts (explicit path, +11/−0)
──────────────────────────────────────────────────────────────────

Strengths
  • Token comparison is constant-time — no timing side-channel on the share token.

| Severity | Dimension | Issue | File | Line(s) | Finding |
|----------|-----------|-------|------|---------|---------|
| High | Consistency | Silent not-found | src/repos/export-job-repo.ts | 47 | `findByDownloadToken` returns `null` on no match — violates project Standard "repository methods must handle the not-found case explicitly." Sibling `findById` (line 22) throws `NotFoundError`; callers expect that contract |

Project rule cited: .claude/rules/code-review.md → Standards →
"Repository methods must handle the not-found case explicitly."

**Verdict: Approve with fixes** — 1 High, localized. The silent null will
surface downstream as a confusing nullable in the download handler; align
with the repo's established throw-or-explicit-return contract before merge.

## Fix 1: Make not-found explicit (High)

**File**: src/repos/export-job-repo.ts:47
**Issue**: Returns null on no match — violates the not-found Standard and
diverges from findById's throw contract.

- const row = await db.query(...);
- return row ? toJob(row) : null;
+ const row = await db.query(...);
+ if (!row) throw new NotFoundError("export job", { token });
+ return toJob(row);

**Rationale**: Matches findById, satisfies the project Standard, removes a
nullable from every caller.

Apply this fix? [Yes / No]
```

### Result

No files modified until the author answers. The finding is grounded in a named project rule and points at the sibling method that establishes the expected contract.

### Why this example matters

- **This finding does not exist without configuration.** Returning `null` breaks no universal dimension — it's the repo's own `## Standards` rule that elevates it. This is the whole point of the configurable layer: the skill enforces *this project's* contracts, not a generic checklist.
- **The finding cites the rule by name.** "Project rule cited: … not-found case explicitly" tells the author exactly which configured standard fired, so the rule (not the reviewer's taste) is what's accountable.
- **It anchors to a sibling for the contract, not just the rule.** Pointing at `findById` line 22 shows the established pattern the new method should match — grounding the fix in existing code, not abstract principle.
- **Explicit path overrides scope.** Passing a file argument narrows the review past the configured `feature` default — useful for a focused second look at one file without re-reviewing the whole branch.
