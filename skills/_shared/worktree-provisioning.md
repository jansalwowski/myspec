# Worktree provisioning

A linked worktree is a bare checkout: no installed dependencies (`node_modules`, `vendor`, `.venv`), no lint cache, no generated config. Lint and tests fail there on a branch that is otherwise clean (issue #11), and every agent used to re-invent the same workaround inside its own prompt. The recipe lives here once; `feature-implement`, `work-isolation.md`, and `promote-to-worktree.sh` point at it.

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

- **A branch that changes a lockfile gets no link for the tree it pins.** A linked tree then describes the wrong dependencies. The script checks each `symlink` entry against `--base` and says which it skipped; run a real install in the worktree. An entry is a string or `{"path": "deps", "lockfiles": ["deps.lock"]}`; a string named after a well-known dependency directory (`node_modules`, `vendor`, `vendor/bundle`, `.venv`, `venv`) takes its lockfiles from a built-in map, and any other string (an `.env` file) is unguarded. `"lockfiles": []` marks an entry unguarded on purpose.
- **Never symlink a build output directory** (`.nuxt`, `dist`, `.next`): a later build in the worktree writes through into the main checkout. Copy the one generated file the linter needs.
- **The Stop hook refuses a symlinked dependency directory whose lockfiles differ** from the checkout it points into (or when no lockfile exists). It checks every guarded `symlink` entry, plus any of the well-known directories at the root that the config does not list. A link this script made with an unchanged lockfile passes as is. A tree that loads the project's own source from the main checkout (a Composer `vendor`, a `.venv` with an editable install) is never linked and always blocks: the checks would run the main checkout's code. `isolation.allowLinkedModules: true` in `.myspec.json` accepts any link; set it only when the repo's worktrees share the main checkout's tree by construction, never for dependency work.
- **Lint caches lie across trees.** A copied `.eslintcache` suppresses pre-existing findings the same way the main checkout does; without it a cold run flags tech debt the branch did not introduce (issue #11, gap 3).

## Verify where you ran

Before reporting a result from a worktree as verified, confirm the command ran in the worktree (`git -C <worktree> status`), that the dependency directory there is what the branch needs, and that the Stop hook ran against that tree. A green result from the wrong tree is worse than no result.
