# `/myspec:feature-plan` — examples

Converts an approved `tech-spec.md` into an execution-ready `implementation-plan.md` with milestones, phases, parallel groups, and per-task TDD steps. The plan is what `/feature-implement` later dispatches to subagents.

**Contents**

- [Single-milestone plan](#single-milestone-plan) — small feature, no parallelism
- [Multi-milestone with parallel groups](#multi-milestone-with-parallel-groups) — barriers and `[parallel:groupName]` tags
- [Plan refuses, recommends decompose](#plan-refuses-recommends-decompose) — tech-spec is too big

---

## Single-milestone plan

Most features land here: 4–8 tasks, one milestone, mostly sequential because each step depends on the previous. The plan is mechanically derived from the tech-spec.

### Setup

`favorite-reports` (from earlier examples) has an approved tech-spec with 6 implementation steps. Each step depends on the previous (migration → service → API → hook → UI → sort logic).

### Invocation

```
/myspec:feature-plan favorite-reports
```

### Skill flow

#### 1. Read context

The skill loads `tech-spec.md` (6 steps, file inventory, interfaces) and `spec.md` (5 acceptance criteria).

#### 2. Build dependency graph

Each step depends on the previous one's output:

- Step 2 (service) imports the table type from Step 1's migration.
- Step 3 (API) imports the service from Step 2.
- Step 4 (hook) calls Step 3's API.
- Step 5 (UI) uses Step 4's hook.
- Step 6 (sort logic) needs the favorites data shape from Step 2.

Zero parallelism opportunities — every step is on the critical path.

#### 3. Drafts plan

```markdown
---
title: "Favorite Reports — Implementation Plan"
status: draft
based_on_tech_spec_version: 1
created: 2026-04-30
---

## Execution Order

### Milestone 1: End-to-end favoriting

| Phase | Mode | Tasks | Depends On |
|-------|------|-------|------------|
| 1 | sequential | T1: migration | — |
| 2 | sequential | T2: ReportFavoritesService + tests | 1 |
| 3 | sequential | T3: API handlers + tests | 2 |
| 4 | sequential | T4: useReportFavorites hook + tests | 3 |
| 5 | sequential | T5: StarButton component + tests | 4 |
| 6 | sequential | T6: pin-to-top sort + integration test | 5 |
```

Each task expands into TDD steps:

```markdown
### Task 2: ReportFavoritesService

**Files**: `src/features/reports/favorites/service.ts`, `src/features/reports/favorites/__tests__/service.test.ts`

**Steps**:
1. Write test: `should add a favorite for a user+report pair` (failing)
2. Run: `pnpm test reports/favorites` → expect 1 fail
3. Implement: ReportFavoritesService.add() using ReportFavoriteRepository
4. Run: `pnpm test reports/favorites` → expect 1 pass
5. Repeat for: remove, list, isFavorite
6. Run: `pnpm typecheck` → expect 0 errors
7. Commit: `feat(favorite-reports): add ReportFavoritesService`
```

### User confirms

```
yes
```

### Result

`implementation-plan.md` written, all tasks `[ ]`, status `draft`. The skill ends:

> **Next**: `/myspec:feature-implement favorite-reports` to execute the plan.

### Why this example matters

- **Single-milestone, all-sequential is fine.** Don't artificially split into milestones to look "complex." A 6-task feature in one milestone is the right shape; the milestone checkpoint at the end gives the user an exit point.
- **Per-task TDD steps are non-optional.** Each task contains the test code, the run command, the expected output, and the commit message. This is what makes the plan dispatchable to subagents — they can execute without re-reading the tech-spec for context.
- **No parallel groups when steps share types.** The favoritesService is imported by everything downstream; running it in parallel with the API handler would mean the API agent has nothing to import.

---

## Multi-milestone with parallel groups

The interesting case: a tech-spec with 11–14 implementation steps, natural seams for parallelism, and two clean milestones.

### Setup

`scheduled-reports` has an approved tech-spec with 11 steps. The user already ran `/feature-tech-spec` (see [feature-tech-spec.md ADR-heavy example](feature-tech-spec.md#adr-heavy-design-with-architectural-alternatives)) and confirmed two milestones.

### Invocation

```
/myspec:feature-plan scheduled-reports
```

### Skill flow

The skill reads the tech-spec and notices three parallel-safe seams:

- **Repos seam** — `ScheduleRepository` and `ExportRunRepository` touch different files and don't import each other.
- **Services seam** — `ScheduleRunner` job and the API handlers can be built in parallel once shared types exist (the types file becomes the barrier).
- **UI components seam** — three list/form/history components are file-disjoint.

Drafts the plan:

```markdown
## Execution Order

### Milestone 1: Core CRUD + cron infrastructure

| Phase | Mode | Tasks | Depends On |
|-------|------|-------|------------|
| 1 | sequential | T1: migration: schedules + export_runs | — |
| 2 | **parallel:repos** | T2: ScheduleRepository, T3: ExportRunRepository | 1 |
| 3 | sequential (barrier) | T4: shared types (src/schedules/types.ts) | 2 |
| 4 | **parallel:services** | T5: ScheduleRunner job, T6: API handlers | 3 |
| 5 | sequential (barrier) | T7: integration test (end-to-end run) | 4 |

### Milestone 2: Settings UI + notifications

| Phase | Mode | Tasks | Depends On |
|-------|------|-------|------------|
| 6 | **parallel:ui** | T8: SchedulesList, T9: ScheduleForm, T10: RunHistoryTable | Milestone 1 |
| 7 | sequential (barrier) | T11: SchedulesPage wires components | 6 |
```

Each parallel-tagged task includes a **file lock list** in its task body:

```markdown
### Task 2: ScheduleRepository

**Files (exclusive)**:
- src/features/schedules/repository.ts
- src/features/schedules/__tests__/repository.test.ts

**Do not modify outside this list.** Concurrent task T3 owns ExportRunRepository.
...
```

The barrier between phase 2 and phase 3 has explicit merge instructions:

```markdown
### Phase 3 Barrier: shared types

**Before this phase**: Phase 2 worktrees must merge cleanly. If T2 or T3 introduced a type that overlaps with the planned shared types, resolve here.

**Verify**: pnpm typecheck across the merged tree.
```

### Self-review (large plans only)

Because the plan has 11 tasks across 7 phases / 2 milestones (≥10 tasks → review-loop applies per the skill), the skill self-reviews each milestone:

- Every tech-spec step → corresponding task ✓
- Parallel groups → zero file overlap ✓ (verified by checking task File lists)
- TDD steps with run commands ✓
- No scope creep ✓

Passes review.

### User confirms

```
yes
```

### Result

`implementation-plan.md` with 11 tasks, 2 milestones, 3 parallel groups, 4 barriers. Status `draft`.

### Why this example matters

- **Parallel groups need exclusive file lists.** Without "do not modify outside this list," subagents will step on each other when implementing. The plan, not the tech-spec, is where this enforcement lands.
- **Barriers are merge points, not just labels.** Phase 3's barrier explicitly handles type-collision resolution between the parallel repo tasks. This is what makes worktree-based parallelism safe.
- **Vertical-slice milestones.** Milestone 1 is a complete vertical (BE through API + integration test) — by the milestone checkpoint, the feature is testable end-to-end even without the UI. That's the design intent of milestones, not "all backend then all frontend."
- **Self-review catches the obvious mistakes** before the user does. Parallel-group file overlap and missing TDD steps are the two most common authoring errors; the skill checks for both.

---

## Plan refuses, recommends decompose

When a tech-spec has too many steps to fit in one plan, the skill stops and routes to `feature-decompose` — even though tech-spec was already approved.

### Setup

A feature `analytics-dashboard` somehow ended up with an approved tech-spec containing **24 implementation steps**. The reviewer didn't catch that this should have been decomposed earlier; now it's at the planning stage.

### Invocation

```
/myspec:feature-plan analytics-dashboard
```

### Skill flow

The skill reads the tech-spec and counts steps. 24 is well past the recommended 20-task ceiling. Before drafting, it stops:

> The tech-spec for `analytics-dashboard` has 24 implementation steps. The recommended ceiling for a single plan is 20 tasks — beyond that, the milestone checkpoints get unwieldy and parallel groups become hard to keep file-disjoint.
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
> - **A) Decompose first** *(recommended)* — run `/myspec:feature-decompose analytics-dashboard`. The four subsystems become sub-features. Each gets its own (smaller) plan. Sharing + permissions probably ships last and may even land in `ideas/` for later.
> - **B) Single oversized plan** — I can produce a 24-task plan with 4 milestones, but `feature-implement` will spend a long time in this single plan and milestone checkpoints will be the only sane interrupt point. This is doable but not advisable.
> - **C) Phase by time** — pick the foundational subsystem (likely data ingestion) and tighten the spec to v2 covering only that. The other three become follow-up features tracked in ideas/.
>
> Which would you like?

### User responds

```
A — decompose
```

### Skill flow (continued)

The skill does **not** create a plan. It hands off:

> Skipping plan creation. Run `/myspec:feature-decompose analytics-dashboard` next. After decomposition, you'll run `/myspec:feature-tech-spec` per sub-feature (the parent's tech-spec content will be carried over as starting drafts), then `/myspec:feature-plan` per sub-feature.

### Result

No `implementation-plan.md` written. The user pivots to decomposition. See [feature-decompose.md](feature-decompose.md) and [flows/feature-decomposition.md](../flows/feature-decomposition.md).

### Why this example matters

- **Plan-stage decomposition routing is rare but valuable.** Catching it earlier (at spec or tech-spec) is preferable, but the plan stage is the last useful checkpoint before subagents start dispatching.
- **The skill names the seams.** "Steps 1–6 are ingestion, 7–11 are query layer..." — that summary is what makes the decompose path tractable. Without it, the user would be re-reading the tech-spec to figure out where to cut.
- **Override exists** — option B is offered so users with a deadline don't get stuck. But the recommendation is unambiguous, and the consequences of choosing B are spelled out.
- **Phasing-by-time is also offered.** Sometimes decomposition is wrong (see [feature-decompose.md scenario 2](feature-decompose.md#skill-refuses--feature-shouldnt-be-decomposed)) — phasing the scope down to v1 is a valid escape hatch.
