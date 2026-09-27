# Worktree provisioning

A linked worktree is a bare checkout: no `node_modules`, no lint cache, no generated config. Lint and tests fail there on a branch that is otherwise clean (issue #11), and every agent used to re-invent the same workaround inside its own prompt. The recipe lives here once; `feature-implement`, `work-isolation.md`, and `promote-to-worktree.sh` point at it.

## Create

```bash
git worktree add -b <type>/<slug> "$(git rev-parse --show-toplevel)/.claude/worktrees/<slug>" origin/<default-branch>
```

Base on `origin/<default-branch>`, not the local branch: a PR based on a local branch that is ahead of origin drags the user's unpushed commits into the PR. Subagents dispatched by a controller that itself works in a worktree base on the **controller's HEAD** instead, or they cannot see the controller's commits (issue #11, gap 1).

## Provision

```bash
.claude/lib/worktree-provision.sh <worktree-path> --base origin/<default-branch>
```

| Entry | Default | What happens |
|---|---|---|
| `isolation.provision.symlink` | `["node_modules"]` | symlinked from the main checkout when present there and absent in the worktree; listed in the worktree's `info/exclude` so it is never staged |
| `isolation.provision.copy` | `[".eslintcache"]` | copied, not linked — for anything a build or linter writes to |

Both lists are read from `.myspec.json`. Add `.env`-class files to `symlink`; add a single generated file the linter imports (a framework's generated eslint config, say) to `copy`.

Rules the script enforces or the recipe relies on:

- **A branch that changes a lockfile gets no `node_modules` link.** A linked tree then describes the wrong dependencies. The script detects this against `--base` and says so; run a real install in the worktree.
- **Never symlink a build output directory** (`.nuxt`, `dist`, `.next`): a later build in the worktree writes through into the main checkout. Copy the one generated file the linter needs.
- **The Stop hook refuses a symlinked `node_modules` whose lockfiles differ** from the checkout it points into (or when no lockfile exists). A link this script made with an unchanged lockfile passes as is. `isolation.allowLinkedModules: true` in `.myspec.json` accepts any link; set it only when the repo's worktrees share the main checkout's tree by construction, never for dependency work.
- **A step that writes into a linked directory writes through the link** into the checkout it points at — code generation into a dependency directory (`node_modules`, `vendor`, `.venv`, …) rewrites the source checkout's copy (issue #93). Pass `--no-symlink` (skips every `isolation.provision.symlink` entry) and run a real install when the work regenerates into one.
- **Lint caches lie across trees.** A copied `.eslintcache` suppresses pre-existing findings the same way the main checkout does; without it a cold run flags tech debt the branch did not introduce (issue #11, gap 3).

## Parallel task worktrees

Harness `isolation: "worktree"` forks from the default branch, so a parallel task after the first phase cannot see the feature commits it builds on. The controller creates each task's worktree itself, from its own checkout on the feature branch, with its work committed:

```bash
.claude/lib/task-worktree.sh create <slug> [--no-symlink]   # prints the worktree path
.claude/lib/task-worktree.sh merge <slug>                   # at the barrier, one task at a time
.claude/lib/task-worktree.sh discard <slug>                 # stale worktree from an interrupted run
```

`create` branches `<feature-branch>--<slug>` at the controller's HEAD and provisions it with the controller's checkout as the link source, whose linked dependency directories already match the feature's lockfiles. `merge` merges into the controller's branch, then removes the worktree and branch; on a conflict it stops mid-merge — resolve, commit, and rerun it to clean up. Worktrees land under `isolation.worktreeRoot` (default `.claude/worktrees`), and a `create` that fails midway removes what it made.

## Verify where you ran

Before reporting a result from a worktree as verified, confirm the command ran in the worktree (`git -C <worktree> status`), that `node_modules` there is what the branch needs, and that the Stop hook ran against that tree. A green result from the wrong tree is worse than no result.
