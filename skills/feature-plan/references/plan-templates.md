# Plan Document Templates

Canonical implementation-plan template: one implementer subagent per task, reviewed at phase boundaries.

## Plan Header

Every implementation-plan.md starts with this frontmatter. Downstream consumers depend on it: `feature-complete` kebab-cases `title` for the archive filename, and `feature-verify` compares `last_updated` against tech-spec.md to detect stale plans.

```yaml
---
title: "{Feature Title} -- Implementation Plan"
feature: {feature-dir-name}
based_on_spec_version: {spec_version from spec.md}
spec: ${aiDir}/features/{feature}/spec.md
tech_spec: ${aiDir}/features/{feature}/tech-spec.md
created: {TODAY}
last_updated: {TODAY}
---
```

`spec` / `tech_spec` are explicit pointers, not decoration: the plan argues from those two documents, so they travel with it — anyone executing or reviewing the plan reads both alongside it.

Update `last_updated` whenever the plan is edited (including checkbox updates by `feature-implement`).

## Global Constraints

Directly after the header, before the Execution Order table:

```markdown
## Global Constraints

> Every task's requirements implicitly include this section.

- `tech-spec.md` §Constraints: "Node >= 20.11; no new runtime dependencies"
- `spec.md` NFR-2: "List endpoints return at most 50 items per page"
- `tech-spec.md` §Naming: "All schedule tables are prefixed `sched_`"
```

Project-wide exact values — version floors, size/perf limits, naming rules, invariants — one line each, copied **verbatim** from spec.md / tech-spec.md with a source reference. Per-task text must never re-derive or paraphrase these values; that is how they drift. Task-scoped behavior stays in each task's Spec contract block.

## Task Status

All task steps use checkbox syntax. Plans are generated with `[ ]` (todo). `feature-implement` updates them during execution:

| Status | Meaning | Set by |
|--------|---------|--------|
| `[ ]` | Todo — not started | `feature-plan` (initial state) |
| `[~]` | In progress — agent is working on this | `feature-implement` (when starting task) |
| `[x]` | Done — completed and verified | `feature-implement` (after phase review passes) |

Resume behavior: A new agent reads the plan, skips `[x]` tasks, re-executes `[~]` tasks from scratch, and starts `[ ]` tasks normally.

## Milestone Section

```markdown
### Milestone N: [Descriptive Name]

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: [Backend task] | sequential | — |
| 2 | Task 2: [Frontend task] | sequential | Phase 1 |
| 3 | Task 3: [Tests] | sequential | Phase 2 |
```

Notes:
- Phase numbers must be globally unique across the entire plan (Milestone 2 starts at the next available phase number)
- First phase of Milestone 2+ uses `Milestone N` in Depends On (not a phase number from the previous milestone)
- Single-milestone plans omit the `### Milestone N:` heading — the Execution Order table stands alone

## Sequential Task

```markdown
### Task N: [Component Name]

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` §X.Y: "<exact sentence from spec covering this task's behavior>"
- `tech-spec.md` step Z: "<exact sentence from tech-spec covering this task's interface/impl detail>"
- (Add one bullet per spec/tech-spec passage that constrains this task. If the task is implementing AC #N, quote AC #N verbatim. If wording diverges from spec, the spec wording wins.)

**Files:**
- Create: `exact/path/to/file.ts`
- Modify: `exact/path/to/existing.ts`
- Test: `exact/path/to/file.test.ts`

**Touch only (required when Files contains Modify):** the specific lines/sections this task adds or changes. Do NOT scan, audit, or modify pre-existing content even if you notice issues — pre-existing tech debt is out of scope. Reviewers will reject diffs that touch unrelated lines.

**Interfaces:**
- Consumes: `createSchedule(input: ScheduleInput): Promise<Schedule>` — from Task N-1
- Produces: `listSchedules(userId: string): Promise<Schedule[]>` — Task N+2 relies on this
- (Exact signatures — names, parameter and return types — from the tech-spec. A task's implementer sees only their own task text; this block is how they learn the names and types neighboring tasks use. `Consumes: nothing` / `Produces: nothing` is valid.)

**Depends on:** Task N-1

- [ ] **Step 1: Write the failing test**
  [test code]

- [ ] **Step 2: Run test — expect FAIL**
  Run test command from `.claude/verification.json` (`test` check) on specific file

- [ ] **Step 3: Implement**
  [implementation code]

- [ ] **Step 4: Run test — expect PASS**
  Run test command from `.claude/verification.json` on specific file

- [ ] **Step 5: Commit**
  `git commit -m "feat({feature}): add component-name"`
```

## Parallel Task

```markdown
### Task N: [Component Name] [parallel:groupName]

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` §X.Y: "<exact sentence>"
- `tech-spec.md` step Z: "<exact sentence>"

**Files:**
- Create: `exact/path/to/file.ts`
- Test: `exact/path/to/file.test.ts`

**Touch only (required when Files contains Modify):** the specific lines/sections this task adds or changes. Pre-existing tech debt is out of scope.

**Interfaces:**
- Consumes: `<exact signature>` — from Task M (barrier)
- Produces: `<exact signature>` — Task P relies on this

**Depends on:** Task M (barrier)
**Parallel with:** Tasks N+1, N+2, N+3

> **Isolation:** This task runs in its own worktree. Do not reference files created by sibling parallel tasks.

- [ ] **Step 1: Write the failing test**
  [test code]
...
```

## Parallel Group Barrier

```markdown
## Barrier: Merge parallel:groupName

> After all tasks in `parallel:groupName` complete and pass review, merge worktrees back to the working branch before proceeding.

- [ ] Merge Task N worktree
- [ ] Merge Task N+1 worktree
- [ ] Merge Task N+2 worktree
- [ ] Read `.claude/verification.json` and run each required check — all pass
- [ ] Resolve any integration conflicts
- [ ] Commit merge: `git commit -m "feat({feature}): integrate {groupName}"`
```
