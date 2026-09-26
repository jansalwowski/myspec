---
title: "Scheduled Reports -- Implementation Plan"
feature: scheduled-reports
based_on_spec_version: 1
created: 2026-01-01
last_updated: 2026-01-01
---

## Global Constraints

- `tech-spec.md` §Constraints: "Node >= 20.11"

### Milestone 1: Core CRUD

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: migration | sequential | — |
| 2 | Task 2: ScheduleRepository, Task 3: ExportRunRepository | parallel:repos | Phase 1 |

### Task 1: Migration

**Files:**
- Create: `db/migrations/001_schedules.sql`

A code sample that looks like plan structure but is not:

```markdown
### Task 2: not a real heading
- [ ] not a real step
```

- [ ] **Step 1: Write the failing test**
- [ ] **Step 2: Implement**
- [ ] **Step 3: Commit**

### Task 2: ScheduleRepository [parallel:repos]

**Depends on:** Task 1
**Parallel with:** Task 3

- [ ] **Step 1: Write the failing test**
  #### Detail heading inside the task
- [ ] **Step 2: Implement**

### Task 3: ExportRunRepository [parallel:repos]

- [ ] **Step 1: Write the failing test**
- [ ] **Step 2: Implement**

## Barrier: Merge parallel:repos

- [ ] Merge Task 2 worktree
- [ ] Merge Task 3 worktree

### Milestone 2: Settings UI

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 3 | Task 10: SchedulesList, Task 11: ScheduleForm | parallel:ui | Milestone 1 |

- [ ] Milestone 2 checkpoint (not a task step)

### Task 10: SchedulesList [parallel:ui]

- [ ] **Step 1: Implement**

### Task 11: ScheduleForm [parallel:ui]

Prose only, no steps yet.

## Spec Coverage

| Source | Requirement (verbatim) | Tasks |
|--------|------------------------|-------|
| spec.md AC-1 | "A user can create a schedule" | T1, T2 |
