# `/myspec:feature-plan` — examples

Converts an approved `tech-spec.md` into an execution-ready `implementation-plan.md` with milestones, phases, parallel groups, and per-task TDD steps. The plan is what `/feature-implement` later dispatches to subagents.

Every run opens with **Step 0: Choose Plan Mode** (BLOCKING) — an `AskUserQuestion` picking `normal` (single-executor implementer per task) or `orchestrator` (per-milestone Worker / SpecReviewer / QualityReviewer chain). The choice drives template selection and front-matter shape, so the three scenarios below differ from the first prompt onward.

**Contents**

- [Single-milestone plan (normal mode)](#single-milestone-plan-normal-mode) — small feature, no parallelism
- [Multi-milestone with parallel groups (orchestrator mode)](#multi-milestone-with-parallel-groups-orchestrator-mode) — role chain, step ownership, worker context budget pass
- [Plan refuses, recommends decompose](#plan-refuses-recommends-decompose) — tech-spec is too big

---

## Single-milestone plan (normal mode)

Most features land here: 4–8 tasks, one milestone, mostly sequential because each step depends on the previous. The plan is mechanically derived from the tech-spec, and `normal` mode keeps the task blocks lean — one implementer agent owns each task end to end.

### Setup

`favorite-reports` (from earlier examples) has an approved tech-spec with 6 implementation steps. Each step depends on the previous (migration → service → API → hook → UI → sort logic).

### Invocation

```
/myspec:feature-plan favorite-reports
```

### Skill flow

#### Step 0: Choose plan mode (BLOCKING)

The skill opens with an `AskUserQuestion`:

```
Plan mode?
  - normal        single-executor implementer per task (Recommended)
  - orchestrator  per-milestone Worker / SpecReview / QualityReview chain
```

It recommends `normal`: six small sequential tasks, no large milestones, no model-tier mix worth optimizing. The orchestrator option carries its disclaimer ("chained autonomy = more surface for cascading errors. Review milestone checkpoints carefully."), but there's no reason to take it here.

**User**: `normal`

The skill reads `references/plan-templates.md` before drafting.

#### 1. Read context

The skill loads `tech-spec.md` (6 steps, file inventory, interfaces) and `spec.md` (5 acceptance criteria).

#### 2. Build dependency graph

Each step depends on the previous one's output:

- Step 2 (service) imports the table type from Step 1's migration.
- Step 3 (API) imports the service from Step 2.
- Step 4 (hook) calls Step 3's API.
- Step 5 (UI) uses Step 4's hook.
- Step 6 (sort logic) needs the favorites data shape from Step 2.

Zero parallelism opportunities — every step is on the critical path. One milestone.

#### 3. Expand to execution tasks

```markdown
---
title: "Favorite Reports — Implementation Plan"
status: draft
based_on_tech_spec_version: 1
spec: ai/features/favorite-reports/spec.md
tech_spec: ai/features/favorite-reports/tech-spec.md
created: 2026-04-30
---

## Global Constraints

> Every task's requirements implicitly include this section.

- `tech-spec.md` §Constraints: "No new runtime dependencies; favorites persist in Postgres, not localStorage"
- `spec.md` NFR-1: "Toggling a favorite reflects in the UI within 200 ms (optimistic update)"

## Execution Order

| Phase | Mode | Tasks | Depends On |
|-------|------|-------|------------|
| 1 | sequential | T1: migration | — |
| 2 | sequential | T2: ReportFavoritesService + tests | Phase 1 |
| 3 | sequential | T3: API handlers + tests | Phase 2 |
| 4 | sequential | T4: useReportFavorites hook + tests | Phase 3 |
| 5 | sequential | T5: StarButton component + tests | Phase 4 |
| 6 | sequential | T6: pin-to-top sort + integration test | Phase 5 |
```

(Single-milestone, so the `### Milestone N:` heading is omitted and the Execution Order table stands alone.)

Each task carries a **Spec contract** block — verbatim quotes, not paraphrase — an **Interfaces** block (Consumes/Produces, exact signatures), plus a **Touch only** line whenever the Files block has a `Modify:` entry:

```markdown
### Task 2: ReportFavoritesService

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` AC-2: "A user can mark a report as a favorite, and the star reflects the favorited state immediately."
- `tech-spec.md` step 2: "ReportFavoritesService exposes add / remove / list / isFavorite, backed by ReportFavoriteRepository."

**Files:**
- Create: `src/features/reports/favorites/service.ts`
- Test: `src/features/reports/favorites/__tests__/service.test.ts`

**Interfaces:**
- Consumes: `report_favorites (user_id, report_id, created_at)` table — from Task 1
- Produces: `ReportFavoritesService.add(userId: string, reportId: string): Promise<void>`, `.remove(...)` same shape, `.list(userId: string): Promise<ReportFavorite[]>`, `.isFavorite(userId: string, reportId: string): Promise<boolean>` — Tasks 3 and 6 rely on these

**Depends on:** Task 1

- [ ] **Step 1: Write the failing test**
  `should add a favorite for a user+report pair`
  [test code]

- [ ] **Step 2: Run test — expect FAIL**
  `pnpm test reports/favorites` → expect 1 fail

- [ ] **Step 3: Implement**
  `ReportFavoritesService.add()` using `ReportFavoriteRepository`
  [implementation code]

- [ ] **Step 4: Run test — expect PASS**
  `pnpm test reports/favorites` → expect 1 pass
  (repeat the cycle for remove, list, isFavorite; then `pnpm typecheck`)

- [ ] **Step 5: Commit**
  `git commit -m "feat(favorite-reports): add ReportFavoritesService"`
```

Task 6 (modifies the existing list query) gets a **Touch only** line because its Files block contains a `Modify:`:

```markdown
**Touch only:** the ORDER BY clause and the favorites join in `listReports()`.
Do not refactor the surrounding query builder — pre-existing tech debt is out of scope.
```

Because the plan is one milestone and under 10 tasks, the Step 4 review loop is skipped.

### User confirms

```
yes
```

### Step 7: Commit decision (BLOCKING)

`HEAD` is the default branch (`main`) and the working tree is clean, so the skill recommends a new branch and asks:

```
Plan is ready. Commit before /feature-implement to avoid dangling files.
  - New branch feat/favorite-reports  (Recommended)
  - Commit to main
```

**User** picks the new branch. The skill creates `feat/favorite-reports`, stages only the feature's files, and commits with `feat(favorite-reports): add implementation plan`.

### Result

`implementation-plan.md` written, all tasks `[ ]`, status `draft`, committed on `feat/favorite-reports`. The skill ends:

> **Next**: `/myspec:feature-implement favorite-reports` to execute the plan.

### Why this example matters

- **Normal mode is the default, and it's the right call here.** Six small sequential tasks gain nothing from a role chain — orchestrator's autonomy would only add surface for cascading errors. The Step 0 disclaimer exists so the user picks deliberately.
- **The Spec contract block is non-negotiable even in normal mode.** Every task quotes the spec/tech-spec sentence that constrains it. If a task has no such passage, that's the signal the task shouldn't exist.
- **Global Constraints and Interfaces are the anti-drift rails.** Project-wide exacts live once in the header section (every task implicitly includes them); exact signatures live in each task's Interfaces block. Task 4's hook calls `list(userId)` because Task 2's Produces line says so — an implementer who sees only their task text never guesses a name.
- **Touch only lands wherever a task modifies an existing file.** Without it, a reviewer flags adjacent pre-existing code as a regression. Task 6 touches the list query, so it scopes the diff explicitly.
- **Single-milestone, all-sequential is fine.** Don't split into milestones to look "complex." The milestone checkpoint at the end gives the user an exit point.
- **The commit decision is part of the skill.** Leaving the plan uncommitted is the failure mode Step 7 exists to prevent — there's no "leave uncommitted" option offered.

---

## Multi-milestone with parallel groups (orchestrator mode)

The interesting case: a tech-spec with 11–14 implementation steps, natural seams for parallelism, two clean milestones, and a couple of tasks heavy enough that mixing model tiers pays off. This is where orchestrator mode earns its keep — each task runs through a Worker / SpecReviewer / QualityReviewer chain so spec-fail and quality-fail loops recover without the user.

### Setup

`scheduled-reports` has an approved tech-spec with 11 steps. The user already ran `/feature-tech-spec` (see [feature-tech-spec.md ADR-heavy example](feature-tech-spec.md#adr-heavy-design-with-architectural-alternatives)) and confirmed two milestones. One step — the bullmq `ScheduleRunner` with retry/backoff and an AST-ish cadence resolver — is meaningfully heavier than the rest.

### Invocation

```
/myspec:feature-plan scheduled-reports
```

### Skill flow

#### Step 0: Choose plan mode (BLOCKING)

```
Plan mode?
  - orchestrator  per-milestone Worker / SpecReview / QualityReview chain (Recommended)
  - normal        single-executor implementer per task
```

The skill recommends `orchestrator`: large multi-task milestones, parallel groups, and a tier mix (most tasks are mechanical and cheap-tier; one is heavy enough to warrant `mid`). It shows the disclaimer:

```
Orchestrator mode gives agents more autonomy across roles. Recovers from
spec-fail and quality-fail loops without you, but chained autonomy = more
surface for cascading errors. Review milestone checkpoints carefully.
```

**User**: `orchestrator`

The skill reads `references/plan-templates-orchestrator.md`. Front-matter now carries `orchestration: agent-chain` and a `roles:` block; tier values are `cheap` / `mid` / `premium` only — never a concrete model name anywhere in the plan.

```yaml
---
feature: scheduled-reports
spec_version: 2
spec: ai/features/scheduled-reports/spec.md
tech_spec: ai/features/scheduled-reports/tech-spec.md
orchestration: agent-chain
roles:
  worker: cheap
  spec_reviewer: mid
  quality_reviewer: mid
---
```

#### 1–2. Read context + dependency graph

The skill reads the tech-spec and finds three parallel-safe seams:

- **Repos seam** — `ScheduleRepository` and `ExportRunRepository` touch different files and don't import each other.
- **Services seam** — the `ScheduleRunner` job and the API handlers can be built in parallel once shared types exist (the types file becomes the barrier).
- **UI components seam** — three list/form/history components are file-disjoint.

#### 3. Expand to execution tasks (with role chain + step ownership)

Each milestone section spells out the chain:

```markdown
### Milestone 1: Core CRUD + cron infrastructure

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: migration (schedules + export_runs) | sequential | — |
| 2 | Task 2: ScheduleRepository, Task 3: ExportRunRepository | parallel:repos | Phase 1 |
| 3 | Task 4: shared types (src/schedules/types.ts) | sequential (barrier) | Phase 2 |
| 4 | Task 5: ScheduleRunner job, Task 6: API handlers | parallel:services | Phase 3 |
| 5 | Task 7: integration test (end-to-end run) | sequential (barrier) | Phase 4 |

**Chain:**
- Workers — tier `cheap` — one per task, parallel where Mode allows. Writes only — no shell, no git.
- SpecReviewer — tier `mid` — gates QualityReviewer. Verdicts: `PASS`, `FAIL-SPEC`, `ESCALATE`.
- QualityReviewer — tier `mid` — runs verification (test, lint, type-check), gates Commit. Verdicts: `PASS`, `FAIL-QUALITY`.
- Commit — controller stages Worker's reported file list and commits with the task's message. One commit per task.
- Checkpoint — controller runs milestone-level verification.

### Milestone 2: Settings UI + notifications

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 6 | Task 8: SchedulesList, Task 9: ScheduleForm, Task 10: RunHistoryTable | parallel:ui | Milestone 1 |
| 7 | Task 11: SchedulesPage wires components | sequential (barrier) | Phase 6 |
```

Every step inside a task block is annotated with its owning chain role — the Worker has no shell, so anything that runs tests, lint, or git is a Reviewer or Controller step. The dispatcher strips non-Worker steps from the Worker envelope:

```markdown
### Task 2: ScheduleRepository [parallel:repos]

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` AC-1: "A user can create a schedule choosing one of the three cadence presets."
- `tech-spec.md` step 2: "ScheduleRepository persists schedules with create / get / listForUser / delete."

**Files:**
- Create: `src/features/schedules/repository.ts`
- Test: `src/features/schedules/__tests__/repository.test.ts`

<!-- budget: est 14k tokens, 2 files, 0 LoC modify, 320 LoC create -->

**Interfaces:**
- Consumes: `schedules` table — from Task 1 migration
- Produces: `ScheduleRepository.create(input: ScheduleInput): Promise<Schedule>`, `.get(id: string)`, `.listForUser(userId: string)`, `.delete(id: string)` — Tasks 5 and 6 rely on these

**Depends on:** Task 1 (barrier)
**Parallel with:** Task 3

> **Isolation:** runs in its own worktree. Do not reference files created by Task 3.

- [ ] **Step 1 (Worker): Write the failing test**
  Crafted to fail on the current codebase (asserts behavior Step 2 adds).
  [test code]

- [ ] **Step 2 (Worker): Implement**
  [implementation code]

- [ ] **Step 3 (Reviewer): Verification**
  Single pass — runs test, lint, type-check from `.claude/verification.json`.
  Non-zero exits become FAIL-QUALITY bullets.

- [ ] **Step 4 (Controller): Commit**
  `git commit -m "feat(scheduled-reports): add ScheduleRepository"`
```

#### 3.5. Worker context budget pass

This pass runs only in orchestrator mode. For each task the skill computes a pure-arithmetic estimate (no LLM call):

```
est_tokens = 3000 + (loc(task_text) + loc(Modify files) + loc(Create inline code)) * 10
```

and checks it against the target tier's caps:

| Tier | Files | LoC modify | LoC create | est_tokens |
|------|-------|------------|------------|------------|
| cheap | 7 | 2200 | 1200 | 35k |
| mid | 12 | 6000 | 3000 | 80k |

The result is surfaced as a one-line `<!-- budget: ... -->` comment after each task's Files block (visible above on Task 2), so the user can audit the math. The Worker dispatch envelope strips it before substitution.

Most tasks come in well under the cheap cap. Two don't:

- **Task 5 (`ScheduleRunner` job)** estimates **~46k tokens** — bullmq registration, retry/backoff state machine, and a cadence resolver, all in one block. That's over the 35k cheap cap but under 80k, and the logic is genuinely cohesive (splitting the retry machine from the cadence resolver would leave two half-tasks that can't be tested independently). So it gets a tier override rather than a split:

  ```markdown
  ### Task 5: ScheduleRunner job [parallel:services]

  **Tier override:** worker=mid
  (reason: bullmq + retry/backoff + cadence resolver, est 46k tokens > cheap cap)

  <!-- budget: est 46k tokens, 6 files, 1100 LoC modify, 540 LoC create -->
  ```

- **Task 8 (`SchedulesList`)** initially bundled the list table *and* the inline filter/sort controls *and* an optimistic-update hook — estimated **~52k tokens / 9 files**, blowing the cheap file cap *and* token cap. It has a natural seam (the data hook is independent of the presentational table), so the **preferred resolution applies: split.** Task 8 becomes `useSchedulesList` (the hook) and Task 8b becomes `SchedulesList` (the table consuming it). Both re-estimate under cap; the skill renumbers downstream tasks and updates the Execution Order table.

After the pass, the override count is 1 of 12 tasks (~8%) — comfortably under the ~30% ceiling, so `roles.worker: cheap` stays the right global default.

#### Step 4: Review loop (large plans only)

12 tasks across 7 phases / 2 milestones (≥10 tasks → review loop applies). The skill self-reviews each milestone:

- Every tech-spec step → corresponding task ✓
- Parallel groups → zero file overlap ✓
- Every task has a Spec contract block; every `Modify:` task has Touch only ✓
- Every step is owner-annotated; each task ends with exactly one Controller commit ✓
- Step 3.5 ran: every task has a budget comment and respects caps; oversized tasks split or overridden ✓

Passes.

### User confirms

```
yes
```

### Step 7: Commit decision (BLOCKING)

The user is already on `feat/scheduled-reports` (not the default branch), so the skill recommends committing to `HEAD` and commits `feat(scheduled-reports): add implementation plan`.

### Result

`implementation-plan.md` with 12 tasks (after the Task 8 split), 2 milestones, 3 parallel groups, orchestrator front-matter, full Worker/SpecReviewer/QualityReviewer chain annotations, and one tier override. Status `draft`.

### Why this example matters

- **Orchestrator mode is a three-role chain, not a single executor.** Worker writes (no shell, no git), SpecReviewer gates on spec conformance (`PASS` / `FAIL-SPEC` / `ESCALATE`), QualityReviewer runs verification (`PASS` / `FAIL-QUALITY`), Controller commits and checkpoints. The per-step `(Worker|Reviewer|Controller)` annotation is what lets the dispatcher strip non-Worker steps from the Worker envelope.
- **The Step 3.5 budget pass is plan-time enforcement, so the implement session does no size estimation.** Two tasks exceeded the cheap cap and resolved differently: Task 5 was indivisible → `Tier override: worker=mid`; Task 8 had a clean seam → split. Splitting is always preferred; the override is the fallback.
- **Tier vocabulary stays abstract.** `cheap` / `mid` / `premium` only — the controller maps tiers to concrete models at dispatch. No model names leak into the plan.
- **The `<!-- budget: ... -->` comment makes the arithmetic auditable** and then disappears before the Worker ever sees the task.
- **Vertical-slice milestones still hold.** Milestone 1 is a complete vertical (migration → repos → types → services → integration test) — testable end-to-end before any UI exists.

---

## Plan refuses, recommends decompose

When a tech-spec has too many steps to fit in one plan, the skill stops and routes to `feature-decompose` — even though the tech-spec was already approved. This happens at Step 0 / Step 1, before any mode-specific work.

### Setup

A feature `analytics-dashboard` somehow ended up with an approved tech-spec containing **24 implementation steps**. The reviewer didn't catch that this should have been decomposed earlier; now it's at the planning stage.

### Invocation

```
/myspec:feature-plan analytics-dashboard
```

### Skill flow

The skill runs Step 0 (the user picks `normal`), then reads the tech-spec in Step 1 and counts steps. 24 is well past the ~20-task ceiling in the skill's Red Flags. Before expanding any tasks, it stops:

> The tech-spec for `analytics-dashboard` has 24 implementation steps. The recommended ceiling for a single plan is ~20 tasks — beyond that, milestone checkpoints get unwieldy and parallel groups become hard to keep file-disjoint.
>
> Looking at the steps, I see four distinct subsystems:
>
> 1. **Data ingestion pipeline** — steps 1–6 (event collectors, aggregator, storage)
> 2. **Query layer** — steps 7–11 (chart queries, caching, tenant scoping)
> 3. **Visualization components** — steps 12–18 (chart library wrappers, dashboard grid, filter panel)
> 4. **Sharing + permissions** — steps 19–24 (saved dashboards, share links, role checks)
>
> Three options:
>
> - **A) Decompose first** *(recommended)* — run `/myspec:feature-decompose analytics-dashboard`. The four subsystems become sub-features, each with its own (smaller) plan. Sharing + permissions probably ships last and may even land in `ideas/` for later.
> - **B) Single oversized plan** — I can produce a 24-task plan with 4 milestones, but `feature-implement` will spend a long time in one plan and milestone checkpoints will be the only sane interrupt point. Doable, not advisable.
> - **C) Phase by time** — pick the foundational subsystem (likely data ingestion), tighten the spec to v2 covering only that, and track the other three as follow-up features in `ideas/`.
>
> Which would you like?

### User responds

```
A — decompose
```

### Skill flow (continued)

The skill does **not** create a plan, and never reaches Step 3.5 or Step 7. It hands off:

> Skipping plan creation. Run `/myspec:feature-decompose analytics-dashboard` next. After decomposition, you'll run `/myspec:feature-tech-spec` per sub-feature (the parent's tech-spec content carries over as starting drafts), then `/myspec:feature-plan` per sub-feature — and you'll choose the plan mode fresh for each.

### Result

No `implementation-plan.md` written. The user pivots to decomposition. See [feature-decompose.md](feature-decompose.md) and [flows/feature-decomposition.md](../flows/feature-decomposition.md).

### Why this example matters

- **The ~20-task ceiling is a hard stop, regardless of plan mode.** Picking orchestrator mode wouldn't rescue a 24-step tech-spec — the refusal happens at Step 1, before mode-specific work. The fix is a smaller scope, not a fancier executor.
- **Plan-stage decomposition routing is rare but valuable.** Catching it at spec or tech-spec is preferable, but the plan stage is the last useful checkpoint before subagents start dispatching.
- **The skill names the seams.** "Steps 1–6 are ingestion, 7–11 are query layer…" — that summary is what makes the decompose path tractable. Without it, the user re-reads the tech-spec to figure out where to cut.
- **Override exists** — option B is offered so users with a deadline don't get stuck. But the recommendation is unambiguous and the consequences of B are spelled out.
- **Phasing-by-time is also offered.** Sometimes decomposition is wrong — tightening the scope to a v1 subsystem is a valid escape hatch.
