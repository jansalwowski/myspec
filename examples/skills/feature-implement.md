# `/myspec:feature-implement` — examples

Executes an approved `implementation-plan.md` by dispatching one implementer subagent per task, reviewing at each phase barrier, and pausing at milestone checkpoints. Always starts with a blocking question about *where* implementation should happen.

**Contents**

- [Sequential execution](#sequential-execution) — one task at a time, single phase, per-phase review at the barrier
- [Parallel group with worktree dispatch](#parallel-group-with-worktree-dispatch) — concurrent implementers in `.claude/worktrees/feat-*`, barrier merge
- [Resume mid-milestone after interruption](#resume-mid-milestone-after-interruption) — `[x]`/`[~]`/`[ ]` handling and stale-worktree cleanup

---

## Sequential execution

The simple shape: a single-phase plan with no parallel groups. The skill first asks *where* to work, then walks tasks one at a time. Each implementer owns its task end to end — code, tests, commit — and the phase review runs once at the barrier, not per task.

### Setup

`favorite-reports` has a 6-task, single-milestone, single-phase plan (see [feature-plan.md single-milestone](feature-plan.md#single-milestone-plan)). All tasks `[ ]`. The user is on `main`, working tree clean.

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

Parses the Execution Order table: 6 sequential tasks, no barriers between them — they form a single phase ending at one barrier. One milestone.

**Resume detection:** all checkboxes `[ ]`. Fresh run.

#### Step 2–3 — Task dispatch loop

For T1 (migration):

1. Edits the plan file: `[ ] T1` → `[~] T1` (before dispatching).
2. Dispatches one implementer subagent (`implementer-prompt.md`) with the task text inline — it never reads the plan file. The tier is named on the dispatch (`cheap` here: one file plus its test, fully specified in the task text). It writes the migration and its test, runs the task's verification commands, commits with the task block's `**Commit:**` message, self-reviews its own diff, and reports `DONE`.
3. The skill leaves T1 at `[~]` — the only route to `[x]` is the phase review.

Repeats for T2–T6 in order, each leaving its checkbox at `[~]`. The implementer never spawns a reviewer of its own: review is the controller's job and is already scheduled.

#### Step 4 — Phase review (once, at the barrier)

After all 6 implementers report `DONE`, the phase hits its barrier and the review runs **once for the whole phase**. The controller writes the package to one temp file — `git log --oneline` + `git diff --stat` + `git diff -U10` over the `PHASE_BASE` recorded before the first dispatch, never `HEAD~1` — and dispatches the phase reviewer (`phase-reviewer-prompt.md`, mid tier) with the path:

- plan ↔ spec: the 6 tasks cover AC-1 ("favoriting persists across sessions"), AC-2 (pin-to-top) ✓
- impl ↔ plan: each task's declared files and interfaces are present ✓
- test coverage: each in-scope acceptance criterion has a test in the diff; `pnpm test` and `pnpm typecheck` green, lint clean ✓
- naming, pattern conformance, maintainability ✓
- Verdict: `APPROVED`.

Had the review returned findings instead, they would be triaged, never silently dropped: **Minor** findings park in the plan's `## Execution Log` (`Deferred minor (Phase 1): …`) for the holistic reviewer to triage — they never enter a fix loop. **Critical/Important** findings enter a capped loop: rounds 1–3 resume the same implementer with the findings verbatim (its context is intact), rounds 4–5 dispatch fresh on a higher tier, and every round ends with a *scoped* re-review that verdicts each finding ADDRESSED / NOT ADDRESSED against the fix diff only — never a full phase re-review. If round 5 still leaves findings open, the Controller adjudicates each one — parked with a recorded `Ruling:` or carried into the next phase — never a round 6. And the Controller never pre-judges: a dispatch prompt containing "do not flag X" is the bug, not the finding.

#### Checkboxes close

Only now — after `APPROVED` — the skill flips all six checkboxes `[~]` → `[x]`. The six commits already exist, one per task, each staging exactly that task's file list (`git add -- <paths>`, never `git add -A`) with the plan's message verbatim:

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
2. Writes the full-feature review package to one temp file (`git log --oneline` + `git diff --stat` + `git diff -U10` over `BASE_SHA..HEAD`) and dispatches the holistic reviewer with the package path plus the plan's Execution Log entries to triage. This pass is mandatory and the tier (premium) is named explicitly on the dispatch — an omitted model would silently inherit the session's model. Returns `APPROVED`, no MUST FIX triage items.
3. Prints the completion report — milestone summary, holistic verdict, **Rulings I made: none**, deferred-minors triage — then asks via `AskUserQuestion` — it does **not** auto-hand-off:

> **Implementation complete. What next?**
>
> - **feature-implement-review** → independent audit that the code fulfills the spec + plan, persists a report (Recommended for anything non-trivial)
> - **code-review** → quality, standards, and bug review of the changes
> - **feature-complete** → skip the reviews; sync docs, archive plan, merge
> - **Stop here** → leave the branch as-is; continue later

The two review passes are **complementary, not exclusive** (conformance vs. code quality). After whichever the user picks finishes, the skill offers this same choice again so they can run the other or proceed to `feature-complete`.

User picks **feature-implement-review**. The skill invokes `/myspec:feature-implement-review favorite-reports`.

### Result

- All 6 tasks `[x]`, six commits on `feat/favorite-reports`, checkboxes closed after the phase passed review.
- One phase review, not six.
- Routed to `/myspec:feature-implement-review` by the user's Step 5 choice.

### Why this example matters

- **Step 0 is blocking and always asked.** Even on a clean `main` with an obvious recommendation, the skill confirms *where* to work. Silent assumption is the bug Step 0 exists to prevent; worktrees live at `.claude/worktrees/feat-{name}`, never `/tmp`.
- **The implementer owns its task end to end.** Code, tests, verification commands, commit, self-review — then it reports. It does not spawn a reviewer of its own; that review is already scheduled and a duplicate one costs full price for a verdict that counts for nothing.
- **Review is per-phase, at the barrier.** All six implementers finish, then one reviewer covers the whole phase's diff at once — spec conformance, quality, test coverage, docs — from a package file, never a pasted diff.
- **Findings are triaged, never suppressed.** The Controller may not tell a reviewer what not to flag. Minor findings park in the plan's `## Execution Log`, plan-conflicting findings get a recorded `Ruling: <what> — <why> — <what it costs if wrong>`, and every ruling resurfaces under "Rulings I made" in the Step 5 completion report.
- **One commit per task, staged by path.** Each implementer stages exactly its own file list and copies the plan's commit message verbatim, so the history reads cleanly and nothing outside the declared scope sneaks in.

---

## Parallel group with worktree dispatch

The interesting case: a plan with parallel groups. Concurrent implementers in isolated `.claude/worktrees/feat-*` checkouts, merged back at the group's barrier before the phase review runs.

### Setup

`scheduled-reports` has the multi-milestone plan with parallel groups (see [feature-plan.md multi-milestone](feature-plan.md#multi-milestone-with-parallel-groups)). All tasks `[ ]`.

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

User picks **Worktree**. The skill creates `.claude/worktrees/feat-scheduled-reports` on branch `feat/scheduled-reports` (via the EnterWorktree tool, or `git worktree add .claude/worktrees/feat-scheduled-reports -b feat/scheduled-reports`), provisions it with `.claude/lib/worktree-provision.sh <path> --base origin/main`, and records `BASE_SHA`.

#### Milestone 1 — parallel dispatch and barrier

The skill walks the DAG. **Phase 2 (`parallel:repos`)** is the showcase: T2 ScheduleRepository, T3 ExportRunRepository, disjoint file lists.

1. Records `PHASE_BASE` (`git rev-parse HEAD`), then marks T2 and T3 both `[~]`.
2. Dispatches **two implementers in one message**, each with `isolation: "worktree"`. A child worktree is bare, so each is provisioned before work starts — real dependency install unless the branch leaves the lockfile alone, `.env`-class files symlinked, lint cache copied (`_shared/worktree-provisioning.md` is the recipe). Each implementer gets only its file list and task text inline:
   - Implementer A → `src/features/schedules/repository.ts` (+ test)
   - Implementer B → `src/features/schedules/run-repository.ts` (+ test)
3. Both write code and tests, run the task's verification commands in their own worktree, commit, and report `DONE`.
4. **Barrier merge:** the controller merges each worktree's commit back onto `feat/scheduled-reports`, one at a time. No conflicts — the file lists were disjoint. Then it runs the barrier verification commands across the merged tree.
5. **Phase review** over `PHASE_BASE..HEAD` covers both tasks at once → `APPROVED`. Both checkboxes flip to `[x]`.

Had the review returned Critical/Important findings, the fix loop would run: rounds 1–3 resume the implementer that owns the finding (its context is intact), rounds 4–5 dispatch fresh one tier up, and every round ends with a *scoped* re-review over `FIX_BASE..HEAD` that verdicts each finding ADDRESSED / NOT ADDRESSED — never a full phase re-review. Minor findings never enter the loop; they park in the plan's `## Execution Log` for the holistic reviewer to triage.

#### Milestone Checkpoint

After every phase in Milestone 1 passes, the skill runs the milestone verification commands and pauses:

> ═══ Milestone 1 complete: Scheduled Reports core CRUD + cron infra ═══
>
>   Completed: T1 migration, T2 ScheduleRepository, T3 ExportRunRepository, T4 shared types, …
>   Next: Milestone 2 — UI + notifications (4 tasks)
>
>   continue / stop / fresh — Choice?

This plan has 12 tasks, so `fresh` carries the `(Recommended)` marker: one milestone per session. The user takes it, the skill commits and exits, and a new `/myspec:feature-implement` session picks up at Milestone 2 from the checkbox state. **Milestone 2's** `parallel:ui` phase then dispatches three implementers (SchedulesList, ScheduleForm, RunHistoryTable) in three worktrees, merged at the barrier the same way.

#### Step 5 — Completion

Final Verification runs, then the controller builds the full-feature review package (one temp file: commit list + stat + `git diff -U10` over `BASE_SHA..HEAD`) and dispatches the holistic reviewer on the premium tier with the package path and the plan's Execution Log entries. Per-phase reviews saw one phase's diff each; this one sees the feature — no overlap, and it is never skipped. The completion report surfaces every `Ruling:` line from the Execution Log under **Rulings I made**, then offers the same 4-option choice (feature-implement-review / code-review / feature-complete / Stop here).

### Result

- All tasks `[x]`, one commit per task, parallel work merged at each barrier.
- Parallel implementers ran in `.claude/worktrees/feat-scheduled-reports`, provisioned before dispatch.
- Per-phase reviews plus one holistic review at the end; user-chosen completion.

### Why this example matters

- **Parallel dispatch goes out in one message.** All of a group's tasks are dispatched together, each with `isolation: "worktree"`; dispatching them one at a time serializes exactly the work the plan marked parallel.
- **Worktrees live under `.claude/worktrees/feat-*`,** not `/tmp`, and they are bare. Provisioning them is part of the dispatch — an implementer that cannot install deps or run lint is a setup bug to fix in the dispatch, never a reason for the controller to absorb the task itself.
- **The barrier is where isolation ends.** Merge one worktree at a time, run the barrier verification, and only then review the phase. A phase review over an unmerged tree reviews something nobody will ship.
- **`PHASE_BASE`, not `HEAD~1`.** A phase with two parallel commits plus a merge is several commits deep; `HEAD~1` silently reviews the last one.
- **Past five tasks, one milestone per session.** The checkpoint recommends `fresh` because a long multi-milestone run is dispatch-latency-bound and the controller's context degrades as it goes.

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

T5 and T6 are re-dispatched as fresh implementers in new worktrees under `.claude/worktrees/feat-scheduled-reports`, merged at the barrier, and reviewed as one phase. Only after the phase review returns `APPROVED` do they flip `[~]` → `[x]`. Phase 4 completes, the Phase 5 barrier (T7) runs, and the Milestone 1 checkpoint is reached normally.

### Result

- The 4 `[x]` tasks were skipped untouched; T5/T6 re-executed cleanly; the 6 `[ ]` tasks proceed in order.
- Stale `.claude/worktrees/feat-scheduled-reports-T5/T6` pruned; only the clean re-execution's commits land.
- Milestone 1 finishes, Milestone 2 begins.

### Why this example matters

- **The three checkbox states are load-bearing.** `[x]` skip, `[ ]` execute, `[~]` *re-execute from scratch*. The skill reads them on startup to find the resume point — without them a crashed run couldn't tell what was finished.
- **`[~]` never silently becomes `[x]`.** The only route to `[x]` is completing the task *and* passing review in the current run, so an interruption always re-runs the in-flight task — it never accidentally skips work.
- **Stale worktrees are a real failure mode** and the skill checks for them at `.claude/worktrees/feat-*`. Left behind, they collide with new dispatches or leak half-finished code into the merge. Pruning before re-dispatch is the safe default.
- **`stop` / `fresh` at a milestone checkpoint is the clean way to preempt this.** A user who expects to be interrupted can exit at a milestone boundary, leaving no `[~]` markers and a fully committed tree to resume from.
