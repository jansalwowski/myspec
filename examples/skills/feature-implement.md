# `/myspec:feature-implement` — examples

Executes an approved `implementation-plan.md` by dispatching subagents per task. Handles parallel groups via worktree isolation, runs phase reviews at each barrier, and pauses at milestone checkpoints.

**Contents**

- [Sequential plan execution](#sequential-plan-execution) — one task at a time
- [Parallel group with worktree dispatch](#parallel-group-with-worktree-dispatch) — concurrent agents, barrier merge
- [Resume mid-milestone after interruption](#resume-mid-milestone-after-interruption) — picking up `[~]` markers from a stopped run

---

## Sequential plan execution

The simple shape: a plan with no parallel groups. The agent walks tasks one at a time, runs phase reviews, hits the milestone checkpoint, asks the user.

### Setup

`favorite-reports` has a 6-task, single-milestone plan (see [feature-plan.md single-milestone](feature-plan.md#single-milestone-plan)). All tasks `[ ]`.

### Invocation

```
/myspec:feature-implement favorite-reports
```

### Skill flow

#### 1. Parse plan → DAG

The skill announces:

> Executing feature-implement on `ai/features/favorite-reports/implementation-plan.md`.

Parses the Execution Order table. Detects 6 sequential tasks, no barriers, one milestone.

#### 2. Resume detection

Scans checkboxes — all `[ ]`. Fresh run.

#### 3. Task dispatch loop

For T1 (migration):

1. Edits the plan file: `[ ] T1: migration` → `[~] T1: migration`.
2. Dispatches a subagent with the task text + tech-spec interfaces context. Subagent writes the migration file, the test, runs `pnpm db:migrate:test`, commits.
3. Subagent reports back. The orchestrator runs phase review:
   - Spec compliance: AC-1 ("favoriting persists across sessions") — yes, table has `(user_id, report_id)` PK and a `created_at` column ✓
   - Code quality: matches existing migration style ✓
   - Tests pass ✓
4. Edits the plan: `[~]` → `[x]`.

Repeats for T2–T6. Each task takes ~2–4 minutes with a single dispatch.

#### 4. Milestone checkpoint

After T6:

> **Milestone 1 complete** — Favorite Reports.
>
> All 6 tasks `[x]`, phase reviews passed.
>
> - Migration applied
> - Service + API tested
> - UI integrated, sort logic verified
>
> **Reply `continue` to proceed (no further milestones), `stop` to commit and exit, or `fresh` to spawn a new agent.**

The plan only has one milestone, so `continue` ends the run. The user replies `continue` (or `stop` — same outcome here).

### Result

All 6 tasks `[x]`, six commits on the feature branch:

```
feat(favorite-reports): add report_favorites migration
feat(favorite-reports): add ReportFavoritesService
feat(favorite-reports): add favorites API handlers
feat(favorite-reports): add useReportFavorites hook
feat(favorite-reports): add StarButton component
feat(favorite-reports): pin favorited reports to top of list
```

The skill ends with:

> Implementation complete. Run `/myspec:feature-verify favorite-reports` to check for drift, then `/myspec:feature-complete favorite-reports`.

### Why this example matters

- **Phase review per task, not per milestone.** Catching a quality issue at T2 means T3–T6 don't build on it. The skill's design assumes early detection beats late rollback.
- **Checkbox states are load-bearing.** `[~]` during dispatch, `[x]` after phase review — these are what `resume detection` uses if the agent crashes. Without them, a resumed run can't tell what was completed.
- **Conventional-commit messages from the plan** mean the git history reads cleanly. The plan author writes them once; subagents copy them verbatim.

---

## Parallel group with worktree dispatch

The interesting case: concurrent subagents in isolated worktrees, merged at the barrier.

### Setup

`scheduled-reports` has the multi-milestone plan with three parallel groups (see [feature-plan.md multi-milestone](feature-plan.md#multi-milestone-with-parallel-groups)). All tasks `[ ]`.

### Invocation

```
/myspec:feature-implement scheduled-reports
```

### Skill flow

#### Phases 1, 2 (parallel:repos), 3 — the interesting bit

**Phase 1 (sequential)**: T1 migration. Standard dispatch. `[x]`.

**Phase 2 (parallel:repos)**: T2 ScheduleRepository, T3 ExportRunRepository.

The orchestrator:

1. Marks T2 and T3 both `[~]` in the plan file.
2. Dispatches **two subagents simultaneously**, each with `isolation: "worktree"`:
   - Agent A worktree: gets T2's task text + tech-spec interfaces. Constraint passed: "Do not modify files outside `src/features/schedules/repository.ts` and its test file."
   - Agent B worktree: gets T3's task text + same shared interfaces. Constraint: "Do not modify files outside `src/features/schedules/run-repository.ts` and its test file."
3. Both agents work concurrently. ~3 minutes each.
4. Both report back. The orchestrator now does the **merge barrier**:
   - Pulls Agent A's worktree → merges into main feature branch. Verifies no conflicts (file constraint held).
   - Pulls Agent B's worktree → merges. Verifies no conflicts.
   - Runs `pnpm typecheck` across the merged tree. Passes.
   - Runs the verification commands from `.claude/verification.json`. Passes.
5. Phase review (one reviewer for both tasks):
   - T2 spec compliance ✓, code quality ✓, tests pass ✓
   - T3 spec compliance ✓, code quality ✓, tests pass ✓
   - Cross-task: no inadvertent shared types between T2 and T3 ✓
6. Marks both `[x]`.

**Phase 3 (sequential barrier)**: T4 shared types file. Single agent. The barrier task is the natural place for a "standard" model — it has integration judgment, while the parallel tasks were mechanical.

#### Continuing through Milestone 1

Phases 4 (parallel:services) and 5 (barrier integration test) follow the same pattern. End of Milestone 1 — checkpoint:

> **Milestone 1 complete** — Scheduled Reports core CRUD + cron infrastructure.
>
> All 7 tasks `[x]`. Tests pass. Branch in working state.
>
> **Reply `continue` for Milestone 2 (UI + notifications), `stop` to commit and exit, or `fresh` to spawn a new agent.**

User: `continue`.

#### Milestone 2

Phase 6 (parallel:ui) dispatches **three** subagents — SchedulesList, ScheduleForm, RunHistoryTable — each with their own file lock list. Three worktrees, three merges, one phase review.

Phase 7 (barrier): SchedulesPage wires components. Single agent.

Final checkpoint. User: `continue`. Done.

### Result

11 tasks `[x]`, ~14 commits on the feature branch. Total wall-clock time: roughly 40 minutes (vs. ~70 minutes if everything had been sequential).

### Why this example matters

- **Worktree isolation is what makes parallelism safe.** Without it, two subagents racing on the same branch corrupt the working tree. With it, they can't see each other's writes until merge — and the merge is the barrier's job.
- **File lock lists are the contract** between the plan author and the dispatched subagents. Plans that omit them produce broken parallel groups.
- **Phase review is one reviewer for the whole group**, not per-task. It checks both individual quality *and* cross-task consistency (e.g., no overlap, types align). One reviewer keeps the global picture coherent.
- **Model selection optimization**: parallel tasks (mechanical, isolated, well-specified) use a fast model; barrier tasks (integration judgment) use the standard model. The skill makes this choice automatically based on the plan's Mode column.
- **Milestone checkpoints are a session boundary**, not just a status line. The user can hit `stop` at the end of M1, log off, come back tomorrow, and run `/myspec:feature-implement scheduled-reports` again — see the next scenario for the resume mechanics.

---

## Resume mid-milestone after interruption

The user's laptop crashed during Milestone 1, Phase 4. Some tasks are `[x]`, the in-flight task is `[~]`, the rest are `[ ]`. The user runs the skill again.

### Setup

The plan file when resumed:

```markdown
| Phase | Mode | Tasks | Depends On |
|-------|------|-------|------------|
| 1 | sequential | [x] T1: migration | — |
| 2 | parallel:repos | [x] T2: ScheduleRepository, [x] T3: ExportRunRepository | 1 |
| 3 | sequential | [x] T4: shared types | 2 |
| 4 | parallel:services | [~] T5: ScheduleRunner job, [~] T6: API handlers | 3 |
| 5 | sequential | [ ] T7: integration test | 4 |
... (Milestone 2 unstarted) ...
```

### Invocation

```
/myspec:feature-implement scheduled-reports
```

### Skill flow

#### 1. Resume detection

The skill scans checkboxes:

```
Detected resume state:
  - 4 tasks [x] (already complete)
  - 2 tasks [~] (in-progress when previous run stopped)
  - 6 tasks [ ] (todo)

[~] tasks will be re-executed from scratch — they may have written
partial code that needs cleanup. The orchestrator will inspect the
working tree before dispatching.
```

#### 2. Inspect working-tree state

The skill runs `git status` on the feature branch and any leftover worktrees:

```
On branch feature/scheduled-reports
Your branch is ahead of 'origin/feature/scheduled-reports' by 4 commits.

Worktrees still present:
  /tmp/feature-implement/scheduled-reports-T5  (last activity: 2 hours ago)
  /tmp/feature-implement/scheduled-reports-T6  (last activity: 2 hours ago)

Both worktrees have uncommitted changes.
```

The skill reports:

> Found two stale worktrees from the interrupted run. They have uncommitted partial work.
>
> Recommended: delete the stale worktrees and re-execute T5 and T6 from scratch. Their `[~]` markers indicate they didn't pass phase review, so the partial work isn't trustworthy.
>
> Alternative: if you remember exactly what was happening when the crash occurred, you can manually inspect the worktrees and salvage. But re-execution is faster and more reliable.
>
> Reply `clean` to delete worktrees and re-execute T5/T6, or `inspect` to pause for manual review.

User: `clean`.

#### 3. Cleanup and re-dispatch

The skill:

1. Removes the two stale worktrees.
2. Marks T5 and T6 as `[~]` (already were) and re-dispatches both in fresh worktrees.
3. Continues the rest of Milestone 1.

From here on, execution proceeds normally — Phase 4 completes, Phase 5 barrier runs, Milestone 1 checkpoint, etc.

### Result

T5 and T6 produce fresh, complete work. The interrupted run's partial commits are not in the history — only the clean re-execution lands. Milestone 1 finishes; Milestone 2 begins normally.

### Why this example matters

- **`[~]` is not "almost done."** It means *"a previous agent started this and we don't know how far it got."* The default move is re-execute, not patch up.
- **Stale worktrees are a real failure mode.** Without explicit cleanup, the next run can't create worktrees with the same names, or worse, picks up half-finished code. The skill checks for this.
- **`fresh` and `stop` checkpoints are designed for this.** A user who knows they'll be interrupted can preempt by hitting `stop` at a milestone boundary — that gives them a clean exit point with no `[~]` markers.
- **The skill never silently flips `[~]` to `[x]`.** The only path to `[x]` is "task completes + phase review passes" in the current run. This means crashes always re-execute the in-flight task; they never accidentally skip work.
