# Plan Document Templates

Canonical normal-mode (single-executor) template. For orchestrator mode (per-milestone Planner / Worker / SpecReview / QualityReview chain), see [`plan-templates-orchestrator.md`](./plan-templates-orchestrator.md).

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

**Files:**
- Create: `exact/path/to/file.ts`
- Modify: `exact/path/to/existing.ts`
- Test: `exact/path/to/file.test.ts`

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

**Files:**
- Create: `exact/path/to/file.ts`
- Test: `exact/path/to/file.test.ts`

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
