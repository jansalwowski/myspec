# `/myspec:feature-plan` — examples

Converts an approved `tech-spec.md` into an execution-ready `implementation-plan.md` with milestones, phases, parallel groups, and per-task TDD steps. The plan is what `/feature-implement` later dispatches to subagents.

One implementer subagent owns each task end to end; the plan's shape — milestones, phases, parallel groups — is what `/feature-implement` schedules against.

**Contents**

- [Single-milestone plan](#single-milestone-plan) — small feature, no parallelism
- [Multi-milestone with parallel groups](#multi-milestone-with-parallel-groups) — seams, barriers, milestone sizing
- [Plan refuses, recommends decompose](#plan-refuses-recommends-decompose) — tech-spec is too big

---

## Single-milestone plan

Most features land here: 4–8 tasks, one milestone, mostly sequential because each step depends on the previous. The plan is mechanically derived from the tech-spec, and the task blocks stay lean — one implementer agent owns each task end to end.

### Setup

`favorite-reports` (from earlier examples) has an approved tech-spec with 6 implementation steps. Each step depends on the previous (migration → service → API → hook → UI → sort logic).

### Invocation

```
/myspec:feature-plan favorite-reports
```

### Skill flow

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

**Verify at phase review:** `pnpm test reports/favorites` — covers add, remove, list, isFavorite

- [ ] **Step 1: Write the failing test**
  `should add a favorite for a user+report pair`
  [test code]

- [ ] **Step 2: Implement**
  `ReportFavoritesService.add()` using `ReportFavoriteRepository`
  [implementation code]
  (repeat the cycle for remove, list, isFavorite)

- [ ] **Step 3: Commit**
  `git commit -m "feat(favorite-reports): add ReportFavoritesService"`
```

The task names its command but does not run it. The implementer writes the test and the code
and stops; the phase reviewer runs every task's command once the phase is complete.

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

- **The Spec contract block is non-negotiable.** Every task quotes the spec/tech-spec sentence that constrains it. If a task has no such passage, that's the signal the task shouldn't exist.
- **Global Constraints and Interfaces are the anti-drift rails.** Project-wide exacts live once in the header section (every task implicitly includes them); exact signatures live in each task's Interfaces block. Task 4's hook calls `list(userId)` because Task 2's Produces line says so — an implementer who sees only their task text never guesses a name.
- **Touch only lands wherever a task modifies an existing file.** Without it, a reviewer flags adjacent pre-existing code as a regression. Task 6 touches the list query, so it scopes the diff explicitly.
- **Single-milestone, all-sequential is fine.** Don't split into milestones to look "complex." The milestone checkpoint at the end gives the user an exit point.
- **The commit decision is part of the skill.** Leaving the plan uncommitted is the failure mode Step 7 exists to prevent — there's no "leave uncommitted" option offered.

---

## Multi-milestone with parallel groups

The interesting case: a tech-spec with 11–14 implementation steps, natural seams for parallelism, and two clean milestones. This is where the plan's structure does real work — parallel groups let `feature-implement` dispatch several implementers at once, and barriers say where they have to rejoin.

### Setup

`scheduled-reports` has an approved tech-spec with 11 steps. The user already ran `/feature-tech-spec` (see [feature-tech-spec.md ADR-heavy example](feature-tech-spec.md#adr-heavy-design-with-architectural-alternatives)) and confirmed two milestones. One step — the bullmq `ScheduleRunner` with retry/backoff and an AST-ish cadence resolver — is meaningfully heavier than the rest.

### Invocation

```
/myspec:feature-plan scheduled-reports
```

### Skill flow

#### 1–2. Read context + dependency graph

The skill reads the tech-spec and finds three parallel-safe seams:

- **Repos seam** — `ScheduleRepository` and `ExportRunRepository` touch different files and don't import each other.
- **Services seam** — the `ScheduleRunner` job and the API handlers can be built in parallel once shared types exist (the types file becomes the barrier).
- **UI components seam** — three list/form/history components are file-disjoint.

#### 3. Expand to execution tasks

```markdown
### Milestone 1: Core CRUD + cron infrastructure

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: migration (schedules + export_runs) | sequential | — |
| 2 | Task 2: ScheduleRepository, Task 3: ExportRunRepository | parallel:repos | Phase 1 |
| 3 | Task 4: shared types (src/schedules/types.ts) | sequential (barrier) | Phase 2 |
| 4 | Task 5: ScheduleRunner job, Task 6: API handlers | parallel:services | Phase 3 |
| 5 | Task 7: integration test (end-to-end run) | sequential (barrier) | Phase 4 |

### Milestone 2: Settings UI + notifications

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 6 | Task 8: SchedulesList, Task 9: ScheduleForm, Task 10: RunHistoryTable | parallel:ui | Milestone 1 |
| 7 | Task 11: SchedulesPage wires components | sequential (barrier) | Phase 6 |
```

A task in a parallel group carries an isolation note, because its implementer runs in its own worktree and cannot see a sibling's files:

```markdown
### Task 2: ScheduleRepository [parallel:repos]

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` AC-1: "A user can create a schedule choosing one of the three cadence presets."
- `tech-spec.md` step 2: "ScheduleRepository persists schedules with create / get / listForUser / delete."

**Files:**
- Create: `src/features/schedules/repository.ts`
- Test: `src/features/schedules/__tests__/repository.test.ts`

**Interfaces:**
- Consumes: `schedules` table — from Task 1 migration
- Produces: `ScheduleRepository.create(input: ScheduleInput): Promise<Schedule>`, `.get(id: string)`, `.listForUser(userId: string)`, `.delete(id: string)` — Tasks 5 and 6 rely on these

**Depends on:** Task 1 (barrier)
**Parallel with:** Task 3

**Verify at phase review:** `pnpm test schedules/repository`

> **Isolation:** runs in its own worktree. Do not reference files created by Task 3.

- [ ] **Step 1: Write the failing test**
  Crafted to fail on the current codebase (asserts behavior Step 2 adds).
  [test code]

- [ ] **Step 2: Implement**
  [implementation code]

- [ ] **Step 3: Commit**
  `git commit -m "feat(scheduled-reports): add ScheduleRepository"`
```

#### Task right-sizing

**Task 8 (`SchedulesList`)** initially bundled the list table *and* the inline filter/sort controls *and* an optimistic-update hook — nine files, three separable deliverables. A reviewer could reject the hook while approving the table, which is the signal to split: Task 8 becomes `useSchedulesList` (the hook) and Task 8b becomes `SchedulesList` (the table consuming it). The skill renumbers downstream tasks and updates the Execution Order table.

**Task 5 (`ScheduleRunner` job)** is also big — bullmq registration, a retry/backoff state machine, and a cadence resolver — but it stays one task: splitting the retry machine from the cadence resolver would leave two half-tasks neither of which can be tested independently. Size is a signal, not a rule; the test cycle is the boundary.

#### Step 4: Review loop (large plans only)

12 tasks across 7 phases / 2 milestones (≥10 tasks → review loop applies). The skill self-reviews each milestone:

- Every tech-spec step → corresponding task ✓
- Parallel groups → zero file overlap ✓
- Every task has a Spec contract block; every `Modify:` task has Touch only ✓
- Every task has an Interfaces block whose signatures match between producer and consumer ✓

Passes.

### User confirms

```
yes
```

### Step 7: Commit decision (BLOCKING)

The user is already on `feat/scheduled-reports` (not the default branch), so the skill recommends committing to `HEAD` and commits `feat(scheduled-reports): add implementation plan`.

### Result

`implementation-plan.md` with 12 tasks (after the Task 8 split), 2 milestones, and 3 parallel groups. Status `draft`.

### Why this example matters

- **Parallel groups are a file-disjointness claim, not a wish.** Each group's tasks touch strictly separate files, and the barrier after the group is where the worktrees rejoin and verification runs. A group whose tasks share a file is a plan bug.
- **Interfaces are what make parallelism safe.** Task 5 and Task 6 are written simultaneously by implementers who never see each other's code; the Produces line on Task 2 is the only place they learn the signature they both call.
- **Right-sizing cuts both ways.** Task 8 split because a reviewer could reject one half and approve the other; Task 5 stayed whole because neither half has its own test cycle.
- **Vertical-slice milestones still hold.** Milestone 1 is a complete vertical (migration → repos → types → services → integration test) — testable end-to-end before any UI exists.
- **Two milestones means two sessions.** Past five tasks the milestone checkpoint recommends `fresh`: a long multi-milestone run in one session is dispatch-latency-bound and the controller's context degrades as it goes.

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

The skill reads the tech-spec in Step 1 and counts steps. 24 is well past the ~20-task ceiling in the skill's Red Flags. Before expanding any tasks, it stops:

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

The skill does **not** create a plan, and never reaches Step 7. It hands off:

> Skipping plan creation. Run `/myspec:feature-decompose analytics-dashboard` next. After decomposition, you'll run `/myspec:feature-tech-spec` per sub-feature (the parent's tech-spec content carries over as starting drafts), then `/myspec:feature-plan` per sub-feature.

### Result

No `implementation-plan.md` written. The user pivots to decomposition. See [feature-decompose.md](feature-decompose.md) and [flows/feature-decomposition.md](../flows/feature-decomposition.md).

### Why this example matters

- **The ~20-task ceiling is a hard stop.** The refusal happens at Step 1, before any task is expanded. The fix is a smaller scope, not a longer plan.
- **Plan-stage decomposition routing is rare but valuable.** Catching it at spec or tech-spec is preferable, but the plan stage is the last useful checkpoint before subagents start dispatching.
- **The skill names the seams.** "Steps 1–6 are ingestion, 7–11 are query layer…" — that summary is what makes the decompose path tractable. Without it, the user re-reads the tech-spec to figure out where to cut.
- **Override exists** — option B is offered so users with a deadline don't get stuck. But the recommendation is unambiguous and the consequences of B are spelled out.
- **Phasing-by-time is also offered.** Sometimes decomposition is wrong — tightening the scope to a v1 subsystem is a valid escape hatch.
