# `/myspec:feature-implement` — examples

Executes an approved `implementation-plan.md` by dispatching write-only Worker subagents per task, reviewing at each phase barrier (SpecReviewer then QualityReviewer), and pausing at milestone checkpoints. The Controller commits; Workers never run tests, lint, or git. Always starts with a blocking question about *where* implementation should happen.

**Contents**

- [Sequential execution](#sequential-execution) — one task at a time, single phase, the Controller commits, per-phase review at the barrier
- [Parallel group with worktree dispatch under orchestrator mode](#parallel-group-with-worktree-dispatch-under-orchestrator-mode) — concurrent Workers in `.claude/worktrees/feat-*`, the role chain
- [Resume mid-milestone after interruption](#resume-mid-milestone-after-interruption) — `[x]`/`[~]`/`[ ]` handling and stale-worktree cleanup

---

## Sequential execution

The simple shape: a single-phase plan with no parallel groups. The skill first asks *where* to work, then walks tasks one at a time. Workers only write files; the Controller commits; the phase review runs once at the barrier — not per task.

### Setup

`favorite-reports` has a 6-task, single-milestone, single-phase plan (see [feature-plan.md single-milestone](feature-plan.md#single-milestone-plan)). All tasks `[ ]`. No `orchestration:` front-matter (normal mode). The user is on `main`, working tree clean.

### Invocation

```
/myspec:feature-implement favorite-reports
```

### Skill flow

#### Step 0 — Confirm implementation flow (BLOCKING)

The skill announces, then inspects git state *before* parsing the plan:

> Executing feature-implement on `ai/features/favorite-reports/implementation-plan.md`.

- Default branch: `main`. HEAD: `main`. Working tree clean.
- No existing worktree for this feature. Plan has no `[parallel:*]` groups.

HEAD is the default branch, so the recommendation is a new branch. The skill asks via `AskUserQuestion` and **waits** — it never assumes, even when the recommendation is obvious:

> **How should implementation proceed?**
>
> - **New branch feat/favorite-reports** (Recommended — HEAD is on main) → create and switch
> - **Worktree feat-favorite-reports** → `.claude/worktrees/feat-favorite-reports` (best for parallel tasks; isolated)
> - **Current branch main** → continue on main
> - **Main branch** → not recommended; only for trivial fixes

User picks **New branch**. The skill runs `git checkout -b feat/favorite-reports`, then records `BASE_SHA` (`git rev-parse HEAD`).

#### Step 1 — Parse plan → DAG

No `orchestration: agent-chain` in front-matter, so no run-mode prompt. Parses the Execution Order table: 6 sequential tasks, no barriers between them — they form a single phase ending at one barrier. One milestone.

**Resume detection:** all checkboxes `[ ]`. Fresh run.

#### Step 2–3 — Task dispatch loop

For T1 (migration):

1. Edits the plan file: `[ ] T1` → `[~] T1` (before dispatching).
2. Dispatches one Worker subagent with the task text inline (the Worker never reads the plan file). The Worker's toolset is **Read / Edit / MultiEdit / Write only** — no shell, no git, no Grep/Glob. It writes the migration file and its test, then reports `<result>OK src/db/migrations/004_report_favorites.ts, src/db/migrations/__tests__/004_report_favorites.test.ts</result>`. **It does not run the migration, does not run tests, and does not commit.**
3. The skill leaves T1 at `[~]`. No per-task review, no per-task commit yet.

Repeats the *dispatch* for T2–T6 in order, each leaving its checkbox at `[~]`. Workers write code and tests only.

#### Step 4 — Phase review (once, at the barrier)

After all 6 tasks' Workers have reported `OK`, the phase hits its barrier and the review runs **once for the whole phase** — two complementary reviewers in sequence:

1. **SpecReviewer** (mid-tier) — reviews `git diff HEAD` against the spec/tech-spec/plan blocks for the phase. Static checks only:
   - plan ↔ spec: the 6 tasks cover AC-1 ("favoriting persists across sessions"), AC-2 (pin-to-top) ✓
   - impl ↔ plan: each task's declared files and interfaces are present ✓
   - TDD evidence (static, does **not** run tests): each in-scope acceptance criterion has a test in the diff ✓
   - Verdict: `PASS`.
2. **QualityReviewer** (mid-tier) — gated on SpecReviewer `PASS`. This is the **sole verification pass**: it runs the test / lint / type-check commands from `.claude/verification.json` (Workers and SpecReviewer never ran them). Then naming, pattern conformance, maintainability, test quality.
   - `pnpm test` green, `pnpm typecheck` green, lint clean ✓
   - Verdict: `PASS`.

#### Controller commits

Only now — after both reviewers `PASS` — the **Controller** commits. It stages exactly the file lists the Workers reported (`git add -- <paths>`, never `git add -A`) and uses each task block's `**Commit:**` message verbatim. It then flips all six checkboxes `[~]` → `[x]`.

```
feat(favorite-reports): add report_favorites migration
feat(favorite-reports): add ReportFavoritesService
feat(favorite-reports): add favorites API handlers
feat(favorite-reports): add useReportFavorites hook
feat(favorite-reports): add StarButton component
feat(favorite-reports): pin favorited reports to top of list
```

This is the only milestone, so the skill goes directly to Step 5 (no Milestone Checkpoint prompt).

#### Step 5 — Completion + review choice

1. Runs the plan's Final Verification section.
2. Dispatches the holistic reviewer (premium tier) over the full `BASE_SHA..HEAD` diff — the quick in-flight gate. Returns `APPROVED`.
3. Asks via `AskUserQuestion` — it does **not** auto-hand-off:

> **Implementation complete. What next?**
>
> - **feature-implement-review** → independent audit that the code fulfills the spec + plan, persists a report (Recommended for anything non-trivial)
> - **code-review** → quality, standards, and bug review of the changes
> - **feature-complete** → skip the reviews; sync docs, archive plan, merge
> - **Stop here** → leave the branch as-is; continue later

The two review passes are **complementary, not exclusive** (conformance vs. code quality). After whichever the user picks finishes, the skill offers this same choice again so they can run the other or proceed to `feature-complete`.

User picks **feature-implement-review**. The skill invokes `/myspec:feature-implement-review favorite-reports`.

### Result

- All 6 tasks `[x]`, six commits on `feat/favorite-reports` — all authored by the Controller after the phase passed review.
- One phase review (SpecReviewer → QualityReviewer), not six.
- Routed to `/myspec:feature-implement-review` by the user's Step 5 choice.

### Why this example matters

- **Step 0 is blocking and always asked.** Even on a clean `main` with an obvious recommendation, the skill confirms *where* to work. Silent assumption is the bug Step 0 exists to prevent; worktrees live at `.claude/worktrees/feat-{name}`, never `/tmp`.
- **Workers are write-only.** They produce files and tests and nothing else — no shell, no test runs, no commits. This keeps their context lean and makes their output a clean, reviewable artifact. The QualityReviewer is the *sole* place tests/lint run.
- **Review is per-phase, at the barrier.** All six tasks' Workers finish, then one SpecReviewer + one QualityReviewer cover the whole phase's diff at once. The two passes are complementary: spec conformance first (static), code quality + verification second.
- **The Controller is the only committer.** It stages exactly the reported file lists and copies the plan's commit messages verbatim, so the history reads cleanly and nothing outside the declared scope sneaks in.

---

## Parallel group with worktree dispatch under orchestrator mode

The interesting case: a plan authored for orchestrator mode. Concurrent Workers in isolated `.claude/worktrees/feat-*` checkouts, each carried through the full role chain — Worker → SpecReview → QualityReview → Controller commit — before the group's barrier.

### Setup

`scheduled-reports` has the multi-milestone plan with parallel groups (see [feature-plan.md multi-milestone](feature-plan.md#multi-milestone-with-parallel-groups)). All tasks `[ ]`. Its front-matter declares `orchestration: agent-chain` and a `roles:` block (`worker: cheap`, `spec_reviewer: mid`, `quality_reviewer: mid`).

### Invocation

```
/myspec:feature-implement scheduled-reports
```

### Skill flow

#### Step 0 — Confirm implementation flow (BLOCKING)

Git state: on `main`, clean, no existing worktree, **plan has `[parallel:*]` groups**. That last fact drives the recommendation to a worktree:

> **How should implementation proceed?**
>
> - **Worktree feat-scheduled-reports** (Recommended — plan has parallel groups) → `.claude/worktrees/feat-scheduled-reports` (isolated)
> - **New branch feat/scheduled-reports** → create and switch
> - **Current branch main** → continue on main
> - **Main branch** → not recommended

User picks **Worktree**. The skill creates `.claude/worktrees/feat-scheduled-reports` on branch `feat/scheduled-reports` (via the EnterWorktree tool, or `git worktree add .claude/worktrees/feat-scheduled-reports -b feat/scheduled-reports`). Records `BASE_SHA`.

#### Step 1 — Orchestrator run-mode gate (BLOCKING)

Front-matter has `orchestration: agent-chain`, so **before dispatching anything** the skill shows the disclaimer and asks via `AskUserQuestion`:

> Orchestrator-auto runs end-to-end without per-milestone prompts. Chained autonomy across roles is more surface for cascading errors. Use only for plans you have already reviewed.
>
> **Plan was authored in orchestrator mode. Run mode?**
>
> - **orchestrator** (Recommended) → matches plan; pauses at every Milestone Checkpoint
> - **orchestrator-auto** → no checkpoint prompts on green verification; only pauses on FAIL-SPEC ≥ 3, FAIL-QUALITY ≥ 3, ESCALATE, or verification failure
> - **normal-fallback** → treat as single-executor; skip the role chain

User picks **orchestrator**. From here the Controller is **dispatch-only** — it writes zero code and runs zero task commands; every task goes through a Worker.

#### Milestone 1 — the role chain in action

The skill walks the DAG. **Phase 2 (`parallel:repos`)** is the showcase: T2 ScheduleRepository, T3 ExportRunRepository, disjoint file lists.

1. Marks T2 and T3 both `[~]`.
2. Dispatches **two Workers in one message**, each with `isolation: "worktree"`. The harness forks each child worktree off the main checkout's HEAD, so the Controller pre-stages each one: `git reset --hard feat/scheduled-reports`, symlink `node_modules`, copy `.eslintcache`. Each Worker gets only its file list and task text inline:
   - Worker A → `src/features/schedules/repository.ts` (+ test)
   - Worker B → `src/features/schedules/run-repository.ts` (+ test)
3. Both Workers write code + tests and report `<result>OK …</result>`. **Neither runs tests nor commits.**
4. **Per task, in each worktree, the chain runs to completion before the group's barrier:**
   - Controller stages the Worker's reported files as intent-to-add (`git add --intent-to-add -- …`) so `git diff HEAD` shows new files in full.
   - **SpecReviewer** (mid) reviews `git diff HEAD` → `PASS`.
   - **QualityReviewer** (mid) — gated on SpecReviewer PASS — runs `.claude/verification.json` commands (test/lint/typecheck) in that worktree → `PASS`.
   - **Controller commits** the task in its worktree using the task block's commit message, staging exactly the reported files.
5. **Barrier merge:** the Controller merges each worktree's commit back onto `feat/scheduled-reports` (cherry-picking, since child bases diverge from session HEAD), one at a time. No conflicts — the file lists were disjoint. Runs the barrier verification commands across the merged tree.
6. Both checkboxes are now `[x]`.

A FAIL on either reviewer would loop back to the same Worker with the reviewer's `<verdict>` bullets appended verbatim under `## Reviewer verdict (retry N)` — capped at 3 retries (4th pauses); an `ESCALATE` (plan ↔ spec mismatch the Worker can't fix) pauses immediately for a plan fix.

#### Milestone Checkpoint

After every task in Milestone 1 has gone through Worker → SpecReview → QualityReview → Commit, the Controller runs the milestone verification commands and pauses (this is `orchestrator`, not `-auto`):

> ═══ Milestone 1 complete: Scheduled Reports core CRUD + cron infra ═══
>
>   Completed: T1 migration, T2 ScheduleRepository, T3 ExportRunRepository, T4 shared types, …
>   Next: Milestone 2 — UI + notifications (4 tasks)
>
>   continue / stop / fresh — Choice?

User: `continue`. **Milestone 2's** `parallel:ui` phase dispatches three Workers (SchedulesList, ScheduleForm, RunHistoryTable) in three worktrees under `.claude/worktrees/feat-scheduled-reports`, each carried through the same chain, then merged at the barrier.

#### Step 5 — Completion (identical in both modes)

Orchestrator mode does **not** skip Step 5. The skill runs Final Verification, dispatches the holistic reviewer over `BASE_SHA..HEAD` (this covers the whole feature; the per-milestone SpecReview/QualityReview were per-milestone-diff — no overlap), then offers the same 4-option choice (feature-implement-review / code-review / feature-complete / Stop here). No `briefs/` directory is created — Workers received task text inline.

### Result

- All tasks `[x]`, committed by the Controller after each passed its chain.
- Parallel Workers ran in `.claude/worktrees/feat-scheduled-reports`, merged at barriers.
- Per-milestone reviews via the role chain; one holistic review at the end; user-chosen completion.

### Why this example matters

- **The role chain is per task, the checkpoint is per milestone.** Worker → SpecReview → QualityReview → Controller commit runs for *every* task; the `continue/stop/fresh` pause only happens at milestone boundaries.
- **Worktrees live under `.claude/worktrees/feat-*`,** not `/tmp`. They are bare checkouts, so the Controller pre-stages `node_modules`/`.eslintcache` before each Worker dispatch — environment friction is fixed in the dispatch setup, never absorbed by the Controller doing the work directly.
- **The Controller never executes tasks in orchestrator mode.** "Just doing this one directly" because a Worker hit friction is a contract breach — the value of the chain (gates, retry loop, reviewable Worker output) evaporates if bypassed. If genuinely unworkable, the skill surfaces it and offers explicit `normal-fallback`.
- **Reviewers, not Workers, run verification.** The QualityReviewer is the sole place tests/lint run; the Controller's only Bash for task work is the cherry-pick/merge and the checkpoint verification.

---

## Resume mid-milestone after interruption

The user's session died during Milestone 1, Phase 4. Some tasks are `[x]`, the in-flight ones are `[~]`, the rest `[ ]`. Re-running the skill detects this and cleans up the stale worktrees.

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

#### Step 0 — Confirm implementation flow (still asked)

Git state inspection finds an **existing worktree for this feature** (`.claude/worktrees/feat-scheduled-reports`), so the recommendation is to reuse it:

> **How should implementation proceed?**
>
> - **Worktree feat-scheduled-reports** (Recommended — worktree already exists) → reuse `.claude/worktrees/feat-scheduled-reports`
> - **Current branch feat/scheduled-reports** → continue on the branch
> - **New branch feat/scheduled-reports-2** → fresh branch
> - **Main branch** → not recommended

User picks **Worktree** (reuse).

#### Step 1 — Resume detection

The skill scans every checkbox:

```
Detected resume state:
  - 4 tasks [x]  → already complete, skip entirely
  - 2 tasks [~]  → in-progress when the previous run stopped
  - 6 tasks [ ]  → todo

[~] is NOT "almost done" — it means a previous agent started the task and
we don't know how far it got. T5 and T6 will be re-executed from scratch.
The skill never silently flips [~] → [x]; the only path to [x] is
"task completes + phase review passes" in this run.
```

The first milestone with a non-`[x]` task is Milestone 1, Phase 4 — resume there.

#### Step 2 — Inspect working tree, clean stale worktrees

Stale child worktrees from the dead run remain under `.claude/worktrees/`:

```
Worktrees still present (git worktree list):
  .claude/worktrees/feat-scheduled-reports-T5   (last activity: 2 hours ago, uncommitted changes)
  .claude/worktrees/feat-scheduled-reports-T6   (last activity: 2 hours ago, uncommitted changes)
```

> Found two stale worktrees from the interrupted run, both with uncommitted partial work. Their `[~]` markers mean they never passed review, so the partial code isn't trustworthy.
>
> Recommended: prune the stale worktrees and re-execute T5 and T6 from scratch.
>
> Alternative: pause so you can inspect and salvage manually — but re-execution is faster and more reliable.
>
> Reply `clean` to prune and re-execute, or `inspect` to pause.

User: `clean`. The skill prunes both worktrees (`git worktree remove`), leaving T5/T6 at `[~]`.

#### Step 3 — Re-dispatch and continue

T5 and T6 are re-dispatched as fresh Workers in new worktrees under `.claude/worktrees/feat-scheduled-reports`, each carried through the role chain (Worker → SpecReview → QualityReview → Controller commit). Only after both pass does the Controller flip them `[~]` → `[x]`. Phase 4 completes, the Phase 5 barrier (T7) runs, and the Milestone 1 checkpoint is reached normally.

### Result

- The 4 `[x]` tasks were skipped untouched; T5/T6 re-executed cleanly; the 6 `[ ]` tasks proceed in order.
- Stale `.claude/worktrees/feat-scheduled-reports-T5/T6` pruned; only the clean re-execution's commits land.
- Milestone 1 finishes, Milestone 2 begins.

### Why this example matters

- **The three checkbox states are load-bearing.** `[x]` skip, `[ ]` execute, `[~]` *re-execute from scratch*. The skill reads them on startup to find the resume point — without them a crashed run couldn't tell what was finished.
- **`[~]` never silently becomes `[x]`.** The only route to `[x]` is completing the task *and* passing review in the current run, so an interruption always re-runs the in-flight task — it never accidentally skips work.
- **Stale worktrees are a real failure mode** and the skill checks for them at `.claude/worktrees/feat-*`. Left behind, they collide with new dispatches or leak half-finished code into the merge. Pruning before re-dispatch is the safe default.
- **`stop` / `fresh` at a milestone checkpoint is the clean way to preempt this.** A user who expects to be interrupted can exit at a milestone boundary, leaving no `[~]` markers and a fully committed tree to resume from.
