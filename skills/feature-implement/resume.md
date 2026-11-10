# Resuming a Run

Read from SKILL.md Step 1 (Resume), at startup only, on the trigger SKILL.md gives. Never apply it mid-run: a `[~]` task there is one this session dispatched, and its worktree is live. `<plugin lib>` is the path SKILL.md resolves.

1. **Scan every task checkbox.**
   - `[x]` = already done — skip entirely
   - `[~]` = was in progress when the previous session stopped — unless its phase finished implementing (step 2), re-execute this task from scratch. When it ran in a worktree, first clear the stale one with `"<plugin lib>/task-worktree.sh" discard <slug>` (a no-op when none exists) — `create` refuses an existing slug, and the partial work never passed review. The slug is `<feature>-t<N>` for a parallel task, and `<feature>-p<N>` for a concurrent phase (parallel-phases.md), which then runs again from scratch, every task of it
   - `[ ]` = todo — execute normally
2. **A phase that finished implementing resumes at its barrier or review, never by re-executing its tasks** — its work is already on the feature branch, so re-implementing it would redo the phase on top of its own commits, and the review would span both copies. Read the phase's stage stamps, `$STATE/phase-N.times` (`$STATE` is what `"<plugin lib>/implement-state.sh" init {feature}` prints):
   - **last stamp `review` or `fix-R`** — resume at Step 4 (b): a fresh phase review over the recorded `PHASE_BASE`, passing the existing `$STATE/phase-N-verify.log`. A fix loop cut off mid-round starts over from that review's findings; the rounds its `Fix base (Phase N, round R)` entries log count toward the five.
   - **last stamp `barrier`** — resume at Step 4a. A task worktree still present is merged, not discarded (the barrier starts only once every task is done), and a merge still in progress (`git rev-parse -q --verify MERGE_HEAD` exits 0) is finished first, as parallel-tasks.md resolves a conflict.
   - **a concurrent phase with no `barrier` stamp,** whose `Base (Phase N)` entry is logged and whose `<feature>-p<N>` worktree is gone from `git worktree list`, or whose merge is still in progress — parallel-phases.md logs that base just before the merge, so the merge has started: finish it as above, then resume at Step 4a.

   Any other phase, or one with no stamps (a run from before them), re-executes its `[~]` tasks as step 1 says.
3. **Recover the run's state.** `BASE_SHA` comes from the `Base (feature)` entry, and for the phase being resumed, `PHASE_BASE` from its `Base (Phase N)` entry, so the phase review still spans the commits made before the restart. A plan from before these entries has none: take `BASE_SHA` from `git merge-base HEAD <integration branch>` and record the phase base afresh. Packages and logs from before the restart are in the state directory Step 2 sets.
4. **Find where to resume.** Start at the first milestone containing any non-`[x]` task — unless an earlier milestone, or any milestone when every task is `[x]`, carries `**Checkpoint probes:**` without a passing entry per probe; resume at the first such milestone's probe gate (Step 4b) instead. A passing entry is a `Probe` line with PASS (SERVED for a `D<n>` demo) or a `Waiver` line.

Step 0 still asks where to work, and Step 2 still runs: `implement-state.sh init` returns the same `$STATE`, and the orchestration marker is set again for the new session.
