# Parallel Tasks and Dual-Stream Forks

Read from SKILL.md Step 3, when a phase holds a `**parallel:groupName**` group or a dual-stream fork. `<plugin lib>` is the path SKILL.md resolves. Concurrent phases are a different mechanism: [parallel-phases.md](parallel-phases.md).

Parallelism pays only when each task outweighs its merge and review overhead; run small parallel groups sequentially in the controller's checkout.

## Dispatch

Dispatch ALL group tasks simultaneously in ONE message. Harness `isolation: "worktree"` forks from the default branch, not the feature HEAD, so create each task's worktree yourself (`"<plugin lib>/task-worktree.sh" create <feature>-t<N>`; recipe in `_shared/worktree-provisioning.md`) and pass its path as the implementer's working directory.

```
Validate file disjointness → task-worktree.sh create per task → mark [~] → dispatch Task N,
Task M, Task K as separate Agent calls in the same message → track per-task status
→ If one fails: keep successful worktrees, fix the failed task, then barrier
```

- Tasks that share a file are not parallel: the worktree merge will conflict on the shared path. Run them sequentially.
- Create the worktrees before marking the tasks `[~]`, so the uncommitted plan edit does not trip `create`'s dirty-tree warning — a warning that fires every time trains you to ignore the one that matters.
- When a task regenerates output into a dependency directory (codegen into `node_modules`, `vendor`, `.venv`, …), pass `--no-symlink` and run the project's install in that worktree yourself before dispatch — implementers never install.

## Dual-stream fork

Dispatch both stream heads simultaneously, each in its own task worktree. Each stream proceeds independently (with its own sequential/parallel phases). Join waits for both streams.

## Barrier merge (Step 4a)

Merge worktrees back to the feature branch **one at a time** (`"<plugin lib>/task-worktree.sh" merge <feature>-t<N>`), then run the phase's full suite as Step 4a says. On conflict: attempt resolution (auto-generated files like lockfiles, codegen output → take union). Escalate to the user if truly stuck.

The merge removes each task worktree; who works where in the fix loop: [fix-loop.md](fix-loop.md) (Who fixes).

## Resume

At startup only, a parallel task left `[~]` by a stopped session: [resume.md](resume.md) step 1.
