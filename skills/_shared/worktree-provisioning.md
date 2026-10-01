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

Read from `.myspec.json` `isolation.provision` in the worktree (the branch's own settings), or in the main checkout when the worktree has none. The steps run in this order:

| Entry | Default | What happens |
|---|---|---|
| `symlink` | `["node_modules"]` | Linked from the main checkout when present there and absent in the worktree. Listed in the worktree's `info/exclude` so it is never staged. |
| `copy` | `[".eslintcache"]` | Copied, not linked, for anything a build or linter writes to. A file or a directory. `{"path": "vendor", "mode": "clone"}` makes a copy-on-write clone (`--reflink=auto` on Btrfs/XFS, `cp -c` on APFS) and falls back to a plain copy where the filesystem has none. |
| `clean` | `[]` | Repo-relative globs deleted in the worktree, such as incremental build caches (`**/*.tsbuildinfo`, `.mypy_cache/**`), so the first check there is cold. Tracked files and links are never deleted. |
| `install` | none | A command, or a list of `{run, cwd, when}` steps, run in the worktree last. `cwd` is repo-relative (default the root). A step runs only when every path in `when` exists. Each step sees `MYSPEC_WORKTREE` and `MYSPEC_MAIN_CHECKOUT`. A failing step stops provisioning (exit 1) and is reported, never retried. |

Add `.env`-class files to `symlink`. Add a single generated file the linter imports (a framework's generated eslint config, say) to `copy`. Use a clone-mode `copy` for a tree whose autoloader resolves paths from its own location, such as a Composer `vendor`.

A polyglot repo installs each part where it lives:

```json
"install": [
  { "run": "composer install --no-interaction", "cwd": "api", "when": ["api/composer.lock"] },
  { "run": "pnpm install --frozen-lockfile --prefer-offline", "when": ["pnpm-lock.yaml"] },
  { "run": "go mod download", "cwd": "worker", "when": ["worker/go.sum"] }
]
```

A single-stack repo sets one command, e.g. `"install": "bundle install"` or `"install": "uv sync --frozen"`.

Rules the script enforces or the recipe relies on:

- **A branch that changes a lockfile gets no link for the tree it pins.** A linked tree then describes the wrong dependencies. The script checks each `symlink` entry against `--base` and says which it skipped; run a real install in the worktree. An entry is a string or `{"path": "deps", "lockfiles": ["deps.lock"]}`; a string named after a well-known dependency directory (`node_modules`, `vendor`, `vendor/bundle`, `.venv`, `venv`) takes its lockfiles from a built-in map, and any other string (an `.env` file) is unguarded. `"lockfiles": []` marks an entry unguarded on purpose.
- **`install` builds the dependency trees, so they are not linked.** With `install` set, a `symlink` entry that is a dependency directory (`node_modules`, `vendor`, `vendor/bundle`, `vendor-bin/*/vendor`, `.venv`, `venv`) is skipped: the install would otherwise write through the link into the main checkout. A tree the install built is a real directory, so the Stop hook's linked-dependency guard passes it. Other entries, such as an `.env` file, are still linked.
- **A tree holding workspace links needs `install`.** When a dependency tree in the main checkout holds a workspace link (an npm, Yarn, pnpm or Bun workspace package, a Composer path repository) and `install` is unset, the script skips that link and prints "set `isolation.provision.install` or run a real install". Through a link, its relative targets would resolve into the main checkout's packages, and the Stop hook refuses such a tree. A workspace config alone skips nothing: a pnpm workspace's Composer `vendor` with no such links is linked as usual.
- **`--no-install` is for restricted environments** (offline, locked-down CI). It skips every install step, prints each one it skipped, and links as if `install` were unset. Run the printed steps yourself before trusting a check there.
- **Never symlink a build output directory** (`.nuxt`, `dist`, `.next`): a later build in the worktree writes through into the main checkout. Copy the one generated file the linter needs.
- **The Stop hook refuses a symlinked dependency directory whose lockfiles differ** from the checkout it points into (or when no lockfile exists). It checks every guarded `symlink` entry, plus any of the well-known directories at the root that the config does not list, and the Composer bin plugin's `vendor-bin/*/vendor`. A link this script made with an unchanged lockfile passes as is. A tree that loads the project's own source from the main checkout is never linked and always blocks: the checks would run the main checkout's code. That covers a Composer `vendor` with autoload rules, a `.venv` with an editable install, and a tree holding workspace links (an npm, Yarn, pnpm or Bun workspace package, a Composer path repository), whose relative targets resolve into the main checkout's packages. Such a tree needs a real install in the worktree; linking each nested dependency directory does not help. `isolation.allowLinkedModules: true` in `.myspec.json` accepts any link; set it only when the repo's worktrees share the main checkout's tree by construction, never for dependency work.
- **A step that writes into a linked directory writes through the link** into the checkout it points at — code generation into a dependency directory (`node_modules`, `vendor`, `.venv`, …) rewrites the source checkout's copy (issue #93). Pass `--no-symlink` (skips every `isolation.provision.symlink` entry) and run a real install when the work regenerates into one.
- **A container check verifies the tree its container mounts.** A container exec (`docker exec`, `docker compose exec`, `podman exec` and the like) runs in the container's working directory, which mounts the checkout the container or compose project was started from, and compose names the project after the directory it runs in. In a linked worktree, or a submodule inside one, the Stop hook refuses such a check as unverifiable unless it passes `-w`/`--workdir` with this worktree's path inside the container. The hook trusts that path without verifying it.
- **Lint caches lie across trees.** A copied `.eslintcache` suppresses pre-existing findings the same way the main checkout does; without it a cold run flags tech debt the branch did not introduce (issue #11, gap 3).

## Parallel task worktrees

Harness `isolation: "worktree"` forks from the default branch, so a parallel task after the first phase cannot see the feature commits it builds on. The controller creates each task's worktree itself, from its own checkout on the feature branch, with its work committed:

```bash
.claude/lib/task-worktree.sh create <slug> [--no-symlink]   # prints the worktree path
.claude/lib/task-worktree.sh merge <slug>                   # at the barrier, one task at a time
.claude/lib/task-worktree.sh discard <slug>                 # stale worktree from an interrupted run
```

`create` branches `<feature-branch>--<slug>` at the controller's HEAD and provisions it with the controller's checkout as the link source, whose linked dependency directories already match the feature's lockfiles. `merge` merges into the controller's branch, then removes the worktree and branch; on a conflict it stops mid-merge — resolve, commit, and rerun it to clean up. Worktrees land under `isolation.worktreeRoot` (default `.claude/worktrees`), and a `create` that fails midway removes what it made, including a worktree whose install step failed.

Task worktrees run `install` too: a task worktree that links the main checkout's workspace tree would have its implementer's checks describe the wrong tree.

**Cost.** `create` provisions one task worktree at a time, before dispatch, each under the controller's Bash timeout, so N parallel tasks cost N installs in a row. Measured on a warm content-addressed store: a three-package pnpm workspace fixture (49 packages) installs with `--frozen-lockfile --prefer-offline` in about 0.6 s. A real monorepo is about 11 s (#211), so five tasks add about a minute before dispatch. A warm Composer, Go module or pip wheel cache should need no network either; measure the project's own install before relying on a total. If the total is too slow for a project, the fix is to provision task worktrees concurrently in `task-worktree.sh`, not to skip `install` and not to raise the timeout.

## Controller stays out

A controller never `cd`s into a task worktree, not even to inspect state: it uses `git -C <worktree>` and absolute paths, and runs any command there in a subshell, `(cd <worktree> && …)`, so its shell does not move. Moving the session's working directory into a worktree makes Claude Code load that worktree's `CLAUDE.md` and `.claude/rules/*.md` into context again — about 15k tokens per worktree entered (issue #123) — and a shell left there commits to the wrong branch. The implementer that owns the worktree is the one that runs `cd <worktree> && …`.

## Verify where you ran

Before reporting a result from a worktree as verified, confirm the command ran in the worktree (`git -C <worktree> status`), that the dependency directory there is what the branch needs, and that the Stop hook ran against that tree. A green result from the wrong tree is worse than no result.
