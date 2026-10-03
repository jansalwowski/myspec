# Project settings for hooks and provisioning: design

Status: reviewed 2026-10-01; the review answers are folded in (see Decisions). Tracking: #212 (tracker), #230, #231, #232, #233, #221, #222, #193; #226 is decided here too.

## Problem

Framework hooks hardcode choices that projects legitimately need to make differently: what counts as a code edit, which checks a change should trigger, where a check's work actually runs, and how a fresh worktree gets its dependencies. A project's only lever today is pinning the hook file. A pin freezes the file out of every later fix, so the project trades one false result for all future ones. #210, #211 and #219 all describe a project that pinned or patched a hook locally and then fell behind.

The goal is that **the framework owns the scripts and the project owns the data.** A project should never need to edit or pin a hook to make it correct for its repository.

## Contexts the design must hold in

myspec is adopted by different organisations in different shapes. Every setting below is checked against all of these.

| Context | What it means for settings |
|---|---|
| Single-stack repo | Defaults must already be right; no setting should be required. |
| Monorepo, one ecosystem (npm/Yarn/pnpm/Bun workspaces, Cargo workspace, Go workspace, Gradle multi-project) | Per-package dependency trees, workspace links that resolve into the main checkout (#229), checks that only matter for some packages. |
| Polyglot monorepo (e.g. a PHP API, a TypeScript front end and a Go worker in one repo) | Several install steps in different directories, several toolchains, checks scoped by directory. No setting may assume one language. |
| Polyrepo (a set of repos, each with its own myspec setup, possibly on different framework versions) | Settings live per repo. Nothing may assume a sibling repo exists or shares its configuration. A write into another repo never arms this repo's gate (stop-gate R2). |
| Containerised development (Docker Compose, devcontainers) | Checks run inside a container that mounts the main checkout, not the worktree (#219). The mount layout differs per project. |
| Mixed teams | One developer runs checks in a container and another runs them natively. Today the mount layout is fixed in the committed compose file, so it is team policy; one-off differences go through `MYSPEC_*` env. A per-machine layer is deferred until an issue needs it (see Layers). |
| Restricted environments (offline, slow network, locked-down CI) | An install step must be optional and must say what it would have done. A setting cannot assume network access. |

## Principles

1. **Settings are data: commands, globs and paths, never stack names.** The framework never branches on "is this a PHP project". A project writes the command it runs and the paths it cares about. Defaults that cover common stacks stay data in the scripts (`DEP_DIRS`, `CODE_EXT`), as AGENTS.md "Stack-agnostic content" requires.
2. **Absent means today's behaviour.** Every setting is optional, and with no settings every hook behaves exactly as it does on `main`. Nothing here is breaking; there are no renames.
3. **Extend before you replace.** A list setting adds to the framework default (`extra…`) or removes named entries from it (`ignore…`). It does not replace the default wholesale, because a replaced list silently misses every entry the framework adds later, which is the pinning problem again.
4. **One reader, one precedence.** Every hook and lib script reads settings through one helper with one precedence order (see Layers). No script parses `.myspec.json` its own way.
5. **Fail closed, say so.** A setting that cannot be read (bad JSON, wrong type) is ignored in favour of the default, and the hook names the ignored key in its message. A malformed setting never disables a gate silently. A setting that loosens a gate (skips a check, ignores a path) is listed by doctor so it can't become invisible policy.
6. **Repo-relative everywhere.** Every path and glob is relative to the repository root, and resolves the same in the main checkout and in a linked worktree. No setting holds an absolute path; `no-absolute-paths` and `paths.md` already require that of committed files.
7. **The schema is data too.** One schema file lists every key, its type, its default and the issue that introduced it. Doctor validates against it (#233), and the documentation table below is checked against it in `lib/tests`. A key added to a script without a schema entry fails a test.

## Layers

| Layer | File | Committed | Holds | Example |
|---|---|---|---|---|
| 1. Framework default | the scripts | yes (framework) | Common-stack defaults | `DEP_DIRS`, `CODE_EXT` |
| 2. Project | `.myspec.json`, `.claude/verification.json` | yes | Team policy | which checks exist, which paths trigger them, how a worktree installs |
| 3. Session | `MYSPEC_*` environment variables | no | One-off overrides | `MYSPEC_ALLOW_LINKED_MODULES=1` |

A later layer wins key by key. Objects merge; lists merge by the rule in principle 3. The existing `MYSPEC_*` variables keep working unchanged and are listed in the schema as the session layer.

**Deferred: a per-machine layer** (a gitignored `.myspec.local.json` between project and session). No issue has shown a setting that differs per machine: #221's mount (`./:/var/www/html`) is fixed in the committed compose file, so it is team policy. The reader takes its layers as an ordered list, so a machine layer can slot in between 2 and 3 later without changing any caller.

`verification.json` stays where the checks are. Settings about checks live on the check, so a check and its scope never sit in two files.

## Catalogue

Keys marked **new** are proposed; the rest exist and are listed so the schema starts complete.

### Provisioning a worktree: `.myspec.json` `isolation.provision`

| Key | Type | Default | Issue | Effect |
|---|---|---|---|---|
| `symlink` | list of path or `{path, lockfiles}` | `["node_modules"]` | exists | Link a dependency tree from the main checkout, guarded by lockfiles. |
| `copy` | list of path or `{path, mode}` | `[".eslintcache"]` | exists; **new** object form, #222 | Copy a file or, **new**, a directory. `mode: "clone"` uses a copy-on-write clone where the filesystem supports one (`cp -c` on APFS, `--reflink=auto` on Btrfs/XFS) and falls back to a plain copy. A clone is right for a dependency tree whose autoloader resolves paths from its own location. |
| `clean` | list of glob | `[]` | **new**, #193 | Delete matching files in the new worktree before any check runs, e.g. incremental build caches (`**/*.tsbuildinfo`, `.mypy_cache/**`) so the first check there is cold. |
| `install` | command, or list of `{run, cwd, when}` | none | **new**, #230 | Run after links, copies and cleans. `cwd` is repo-relative (default the root). `when` is a list of repo-relative paths that must all exist for the step to run, such as its lockfile. Each step runs with `MYSPEC_WORKTREE` and `MYSPEC_MAIN_CHECKOUT` exported. A failing step stops provisioning and is reported; it is never retried silently. Runs by default when set (see cost below). |

Polyglot example:

```json
"install": [
  { "run": "composer install --no-interaction", "cwd": "api", "when": ["api/composer.lock"] },
  { "run": "pnpm install --frozen-lockfile --prefer-offline", "when": ["pnpm-lock.yaml"] },
  { "run": "go mod download", "cwd": "worker", "when": ["worker/go.sum"] }
]
```

Interaction with the guards: a tree that `install` built in the worktree is a real directory, not a link, so the linked-dependency guard (#229 / PR #236) passes it. That is why #236 should merge together with #230: #236 refuses the false pass, and `install` is the supported way to a true one. When a dependency tree holds workspace links that resolve into the main checkout and `install` is unset, provisioning skips that link and prints "set `isolation.provision.install` or run a real install", as it does today for a lockfile change. A workspace config alone skips nothing, so a tree with no such links (a pnpm workspace's Composer `vendor`) is still linked.

`--no-install` on `worktree-provision.sh` skips the install steps, for restricted environments, and prints each step it skipped.

**Cost under parallel tasks.** `feature-implement` provisions every parallel task worktree through `lib/task-worktree.sh create`, which calls `worktree-provision.sh` once per task, one after another, before dispatch, each under the controller's Bash timeout. With `install` set, N parallel tasks mean N installs. Step 2 settles this explicitly rather than leaving it to the default:
- Task worktrees run `install` too. Correctness comes first: a task worktree that links the main checkout's workspace tree is the #229 false pass, and its implementer's checks would describe the wrong tree.
- Step 2 measures one install on a content-addressed or cached store (pnpm store, Composer cache, Go module cache, pip wheel cache), where #211 reports about 11 s, and documents the total for N tasks in `skills/_shared/worktree-provisioning.md`.
- If the total is too slow for a project, the fix is to provision task worktrees concurrently in `task-worktree.sh`, not to skip `install` in them. Any concurrency stays under the controller's Bash timeout, and that timeout is never raised.

### What arms the stop gate: `.myspec.json` `hooks.markCodeChanged`

| Key | Type | Default | Issue | Effect |
|---|---|---|---|---|
| `extraCodeExtensions` | list of extension | `[]` | **new**, #231 | Treat these as code in addition to `CODE_EXT` (e.g. `twig`, `tf`, `proto`). |
| `ignorePaths` | list of glob | `[]` | **new**, #231 | A write to a matching path is recorded as `file`, not `code`, so it never arms the gate by itself. For generated output and scratch directories inside the repo. Loosens the gate, so doctor lists it. |

Removing a default extension is deliberately not offered. A project that wants an extension ignored can ignore the paths that hold it, which keeps the decision visible and scoped.

### Checks: `.claude/verification.json`

| Key | Type | Default | Issue | Effect |
|---|---|---|---|---|
| `checks[].paths` | list of glob | none (always runs) | **new**, #232 | Run the check only when a file this session wrote in this checkout (`$MYSPEC_SESSION_FILES`), or a path git reports changed there (uncommitted, or against the base), matches. In a polyglot monorepo, `api/**` scopes the PHP checks and `web/**` the TypeScript ones. Loosens the gate, so doctor lists it, and a required check scoped by `paths` is reported in the stop message when it was skipped. |
| `containers` | map of name → `{mountSource, mountTarget}` | none | **new**, #221 | Describes a container that bind-mounts part of the repo. `mountSource` is repo-relative (usually `.`), `mountTarget` is the absolute path inside the container. |
| `checks[].cwd` | repo-relative path | none (the checkout root) | #250 | The check runs from this directory of the verified checkout, so a package's check needs no `cd` in its command. An absolute value or one with a `..` segment is ignored and named in the stop message. With `runIn`, `MYSPEC_CHECK_WORKDIR` includes it. |
| `checks[].runIn` | container name | none | **new**, #221 | The gate exports `MYSPEC_CHECK_WORKDIR` = `mountTarget` + the path of the checkout's `mountSource` relative to the main checkout's `mountSource` (with `mountSource` `.`, the checkout's own path; with `api`, a worktree's `api/` is never under the main checkout's, so only the main checkout is visible). The command uses it, e.g. `docker compose -p myapp exec -w "$MYSPEC_CHECK_WORKDIR" api make lint`, which is right in the main checkout and in a worktree nested under the mount (`-p` pins the compose project, which compose otherwise names after the worktree directory). When the worktree is not under `mountSource`, the check is refused with "this worktree is not visible inside the container" and never run. A check with `runIn` is trusted to use the workdir and satisfies the #220 refusal; doctor warns when its command passes neither `-w`/`--workdir` nor `MYSPEC_CHECK_WORKDIR`. |

The framework never names a container runtime: the command is the project's, and `MYSPEC_CHECK_WORKDIR` works with Docker, Podman, `nerdctl` or `kubectl exec` alike.

### Worktree guard: `.myspec.json` `isolation`

| Key | Type | Default | Issue | Effect |
|---|---|---|---|---|
| `blockInMain` | list of anchored ERE | the built-in list (see schema) | exists; default #250 | Commands blocked in the main checkout while a session is in worktree mode. The default is the guard's former `HEAVY_PATTERNS`: builds, installs, e2e runs, `lint:fix`, `docker compose exec`, `git push`, `git worktree prune`, for the JS, PHP, Python, Ruby, Rust, Go, JVM (Maven, Gradle), .NET and Make stacks. A project's entries extend it. |
| `ignoreBlockInMain` | list of anchored ERE | `[]` | #250 | Default `blockInMain` entries, by their exact text, that the guard drops. Loosens the gate, so doctor lists it. |
| `allowLinkedModules` | bool | `false` | exists | Accept a linked dependency tree at the Stop gate. Loosens the gate. |
| `worktreeRoot` | repo-relative path | `.claude/worktrees` | exists | Where worktrees are created. |

### Deferred

These came up during triage and are not in this round, because no issue has shown a project that needs them yet: an allowlist for `no-absolute-paths` (#234 chose file-kind scoping instead), `allowInMain` carve-outs for the worktree guard, and per-check environment variables. They fit the same layers and schema if they are needed later.

## Reading settings

A new helper, `lib/myspec-config.sh get <dotted.key> [--root <checkout>]`, prints the effective value as JSON after merging the layers in order, and `lib/myspec-config.mjs` does the same for lib scripts. Settings are read from the checkout itself, so a branch that changes a setting is verified with its own setting. Hooks keep `jq` as their only dependency.

The schema lives in `lib/myspec-config.schema.json`. Hooks don't validate at runtime; they read with defaults and name an unreadable key. Validation is doctor's job.

## Visibility: doctor (#233)

- `setup-doctor schema` validates `.myspec.json` and `verification.json` against the schema: unknown keys (with a near-miss suggestion), wrong types, and `runIn` naming an undefined container are reported, and so are a glob the readers would skip and an `install` step whose `cwd` does not exist. The doctor names no key: the schema's `format` (`glob`, `dir`) and `refersTo` fields say what to check, and `name[]` / `name[].field` entries type the items of a list. A wrong type and an undefined reference are errors, because the readers drop the value and the stop gate refuses the check. The other findings are warnings.
- A new `setup-doctor settings` surface prints every key that differs from its default, its value and its layer, and marks the ones the schema flags `loosens`. Keys flagged `bookkeeping` are left out. `/myspec:doctor` includes it, so a reviewer of a consumer project sees the effective policy in one place.

## #226: how `work-isolation.md` loads

Decision proposed: **split it.**

- An always-loaded core of about 150 tokens: the user chooses develop or worktree before the first source edit, two hooks enforce it, and a block message says what to do and where the full procedure is.
- The core keeps #237's rule that a session learns its id only from a block message, never from guessing at the newest session log.
- The procedure (worktree creation, provisioning, `git -C`, finishing) moves to a reference file that the block messages and the isolation-related skills cite. It is read when it's needed, not on every session.
- The reference file is a new framework file, and a framework file's name is a contract (AGENTS.md "Config contracts"). It gets its own manifest entry with its install destination, `init` and `update` install it, and `update` gives existing projects the new file plus the shortened rule in one run.

Why not the other two options:
- **Always load:** about 1,100 tokens in every session of every project, while `rules/workflow.md` and `rules/memory-system.md` already sit at the 1,000-token budget (#185). The enforcement is in the hooks, so most of the text is procedure that is only needed once a block fires.
- **Globs derived from the topology file:** `backbone.yml` is optional and often stale, so the generated globs would miss directories in exactly the projects that need them, and writing project-specific globs into a framework-owned rule recreates the pinning problem. No directory list is ever complete across stacks: the misses #226 reports (`config/`, `plugins/`, `middleware/`, `bin/`, `scripts/`) are ordinary in one ecosystem and absent in the next.

This is independent of the settings work and can land as its own PR.

## Rollout

Each step is one PR. Steps 2 to 4 touch disjoint files and run in parallel once step 1 has merged.

| Step | Issues | Files | Notes |
|---|---|---|---|
| 1. Reader and schema | — | `lib/myspec-config.{sh,mjs}`, `lib/myspec-config.schema.json`, tests | Foundation, no behaviour change. Project and session layers only. |
| 2. Provisioning | #230, #222 (clone and directory copy), #193 (`clean`) | `lib/worktree-provision.sh`, `skills/_shared/worktree-provisioning.md`, tests | Merge #236 together with this. |
| 3. Checks | #232, #221 | `hooks/verify-before-stop.sh`, `templates/verification.json`, `docs/stop-gate.md`, tests | After #236, which edits the same check loop. |
| 4. Code-change detection | #231 | `hooks/mark-code-changed.sh`, tests | |
| 5. Doctor | #233 | `lib/setup-doctor.mjs`, `skills/doctor/SKILL.md`, tests | Last, because it validates everything above. |
| — | #226 | `framework-files/rules/work-isolation.md`, the new reference file and its `framework-files/manifest.json` entry, hook block messages | Independent; can run alongside step 1. |

Examples for every step pair at least two stacks, and none names a port.

## Decisions

The review on #238 settled the four open questions:

1. **Local layer: deferred.** Ship the framework, project and session layers only, with a reader that takes an ordered layer list so a machine layer can be added later.
2. **#226: split** `work-isolation.md`. The new reference file gets a manifest entry, and the always-loaded core keeps the rule that the session id comes only from a block message.
3. **`install` runs by default when set.** Task worktrees run it too, and step 2 measures and documents the per-task cost. Speed problems are fixed with concurrent provisioning, never by skipping the install.
4. **No removal of default code extensions.** `ignorePaths` covers it: `**/*.sql` removes an extension in effect, and doctor lists it.
