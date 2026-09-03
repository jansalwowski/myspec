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
- **The Stop hook refuses a symlinked `node_modules`** unless `.myspec.json` sets `isolation.allowLinkedModules: true`. Set it when the repo's worktrees share the main checkout's tree by construction; leave it unset for dependency work.
- **Lint caches lie across trees.** A copied `.eslintcache` suppresses pre-existing findings the same way the main checkout does; without it a cold run flags tech debt the branch did not introduce (issue #11, gap 3).

## Verify where you ran

Before reporting a result from a worktree as verified, confirm the command ran in the worktree (`git -C <worktree> status`), that `node_modules` there is what the branch needs, and that the Stop hook ran against that tree. A green result from the wrong tree is worse than no result.
