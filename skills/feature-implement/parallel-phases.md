# Disjoint Phases Run Together

Read from SKILL.md Step 1 (detection) and Step 3 (execution). Plans rarely declare `[parallel:*]` groups, so a run otherwise walks every phase in sequence even when two of them share nothing. Two phases run concurrently only when the plan opts in (`auto_parallel_phases: true` in its front-matter, which `feature-plan` writes into every new plan) and their files prove they cannot collide. A plan without the key was written when table order was execution order, so it runs serially as before.

## When phases are concurrent

Within one milestone, a set of phases runs together only when all of these hold. If any one cannot be shown from the plan text, the phase runs serially, as before.

1. **No dependency.** Neither phase reaches the other through the Execution Order table's `Depends On` column, directly or transitively, and both are ready: every phase each one depends on is complete. `Depends On` is authoritative. A plan that chains every phase to the one before it (`Phase 2` depends on `Phase 1`, and so on) has no concurrent phases.
2. **No interface link.** No task in one phase lists, under `Consumes`, an item that a task in the other phase lists under `Produces`.
3. **Disjoint files.** Collect each phase's paths from its tasks' `**Files:**` (Create, Modify, Test) and `**Touch only:**` lines. The two sets share no path, and no path in one set is a directory that contains a path in the other. Only these two lines count. A path you infer from a snippet or the tech-spec does not prove anything.
4. **No writes outside the listed paths.** Exclude a phase if any of its tasks, by design, writes a file it does not list: code generation, a dependency install, a lockfile change, or a migration whose name or number comes from a shared sequence.
5. **Sequential mode.** Every phase in the set is `sequential` in the Mode column. A phase holding a `[parallel:*]` group or a dual-stream fork keeps its own handling and runs alone.
6. **Opted in.** The plan front-matter sets `auto_parallel_phases: true`. Absent or `false`: every phase runs serially, and none of the checks above runs.

Log the decision once per set, before the first dispatch: `Ruling: Phases 3 and 4 run concurrently — no Depends On path, no Consumes/Produces link, disjoint Files/Touch only — cost if wrong: a merge conflict at the second phase's barrier`.

## Running a concurrent set

- Create one worktree per phase from the controller's HEAD with `task-worktree.sh create <feature>-p<N>`, before marking the phase's tasks `[~]`. The `--no-symlink` rule in SKILL.md Step 3 applies here too.
- Dispatch each phase's first implementer in the same message. Within a phase, tasks still run in listed order, all of them in that phase's worktree.
- The barrier and the review stay per phase, and they run one phase at a time in the controller's checkout, in the order the phases finish implementing. For each phase:
  1. Record `PHASE_BASE=$(git rev-parse HEAD)` and log `Base (Phase N): <sha>`.
  2. Run `task-worktree.sh merge <feature>-p<N>`. A conflict means the disjointness proof was wrong. Resolve it as SKILL.md Step 4a resolves a task merge, and log a `Ruling:` naming the shared file.
  3. Continue with Step 4a's full suite, then 4b to 4f, exactly as for a serial phase. The fix loop works in the controller's checkout.
- The other phase's implementers keep working in their worktree during this. Its merge waits until the current phase is marked complete (4e), so each review package and each fix loop covers exactly one phase.
- Resume: when a concurrent phase still has `[~]` tasks, discard its worktree with `task-worktree.sh discard <feature>-p<N>` and run the phase again from scratch, as with a parallel task.

## Opting in and out

`feature-plan` writes `auto_parallel_phases: true` into each plan it creates, together with the rule that `Depends On` names every real dependency. An older plan opts in by adding the key, once its `Depends On` column is checked. A new plan whose author relies on table order adds the missing `Depends On` edge, or sets the key to `false` to keep every phase serial.
