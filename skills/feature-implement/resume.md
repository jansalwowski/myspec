# Resuming a Run

Read from SKILL.md Step 1, when the plan already holds a `[x]` or `[~]` task or an `## Execution Log` section. `<plugin lib>` is the path SKILL.md resolves.

1. **Scan every task checkbox.**
   - `[x]` = already done — skip entirely
   - `[~]` = was in progress when the previous session stopped — re-execute this task from scratch. For a parallel task, first clear its stale worktree with `"<plugin lib>/task-worktree.sh" discard <feature>-t<N>` (a no-op when none exists) — `create` refuses an existing slug, and the partial work never passed review. A concurrent phase's worktree is `<feature>-p<N>` (parallel-phases.md)
   - `[ ]` = todo — execute normally
2. **Recover the run's state.** `BASE_SHA` comes from the `Base (feature)` entry, and for the phase being resumed, `PHASE_BASE` from its `Base (Phase N)` entry, so the phase review still spans the commits made before the restart. A plan from before these entries has none: take `BASE_SHA` from `git merge-base HEAD <integration branch>` and record the phase base afresh. Packages and logs from before the restart are in the state directory Step 2 sets.
3. **Find where to resume.** Start at the first milestone containing any non-`[x]` task — unless an earlier milestone, or any milestone when every task is `[x]`, carries `**Checkpoint probes:**` without a passing entry per probe; resume at the first such milestone's probe gate (Step 4b) instead. A passing entry is a `Probe` line with PASS (SERVED for a `D<n>` demo) or a `Waiver` line.

Step 0 still asks where to work, and Step 2 still runs: `implement-state.sh init` returns the same `$STATE`, and the orchestration marker is set again for the new session.
