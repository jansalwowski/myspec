# Project settings for hooks and provisioning: design

Status: draft for review, 2026-10-01. Tracking: #212 (tracker), #230, #231, #232, #233, #221, #222, #193; #226 is decided here too.

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
| Mixed teams | One developer runs checks in a container and another runs them natively; one has a different container name. Team policy and machine facts have to be separable. |
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
| 3. Local | `.myspec.local.json` | no (gitignored by `init` and `update`) | Facts about one machine | a container name that differs, `install` off on a slow link |
| 4. Session | `MYSPEC_*` environment variables | no | One-off overrides | `MYSPEC_ALLOW_LINKED_MODULES=1` |

A later layer wins key by key. Objects merge; lists merge by the rule in principle 3. Only keys marked *local* in the catalogue may be set in layer 3, so a local file can change where a check runs but cannot switch a required check off. The existing `MYSPEC_*` variables keep working unchanged and are listed in the schema as layer 4.

`verification.json` stays where the checks are. Settings about checks live on the check, so a check and its scope never sit in two files.

## Catalogue

Keys marked **new** are proposed; the rest exist and are listed so the schema starts complete.

### Provisioning a worktree: `.myspec.json` `isolation.provision`

| Key | Type | Default | Local | Issue | Effect |
|---|---|---|---|---|---|
| `symlink` | list of path or `{path, lockfiles}` | `["node_modules"]` | no | exists | Link a dependency tree from the main checkout, guarded by lockfiles. |
| `copy` | list of path or `{path, mode}` | `[".eslintcache"]` | no | exists; **new** object form, #222 | Copy a file or, **new**, a directory. `mode: "clone"` uses a copy-on-write clone where the filesystem supports one (`cp -c` on APFS, `--reflink=auto` on Btrfs/XFS) and falls back to a plain copy. A clone is right for a dependency tree whose autoloader resolves paths from its own location. |
| `clean` | list of glob | `[]` | no | **new**, #193 | Delete matching files in the new worktree before any check runs, e.g. incremental build caches (`**/*.tsbuildinfo`, `.mypy_cache/**`) so the first check there is cold. |
| `install` | command, or list of `{run, cwd, when}` | none | yes | **new**, #230 | Run after links, copies and cleans. `cwd` is repo-relative (default the root). `when` is a list of repo-relative paths that must all exist for the step to run, such as its lockfile. Each step runs with `MYSPEC_WORKTREE` and `MYSPEC_MAIN_CHECKOUT` exported. A failing step stops provisioning and is reported; it is never retried silently. |

Polyglot example:

```json
"install": [
  { "run": "composer install --no-interaction", "cwd": "api", "when": ["api/composer.lock"] },
  { "run": "pnpm install --frozen-lockfile --prefer-offline", "when": ["pnpm-lock.yaml"] },
  { "run": "go mod download", "cwd": "worker", "when": ["worker/go.sum"] }
]
```

Interaction with the guards: a tree that `install` built in the worktree is a real directory, not a link, so the linked-dependency guard (#229 / PR #236) passes it. That is why #236 should merge together with #230: #236 refuses the false pass, and `install` is the supported way to a true one. When a workspace config exists and the root `node_modules` (or another `DEP_DIRS` entry) would be linked while `install` is unset, provisioning skips the link and prints "set `isolation.provision.install` or run a real install", as it does today for a lockfile change.

`--no-install` on `worktree-provision.sh` skips the install steps, for restricted environments, and prints each step it skipped.

### What arms the stop gate: `.myspec.json` `hooks.markCodeChanged`

| Key | Type | Default | Local | Issue | Effect |
|---|---|---|---|---|---|
| `extraCodeExtensions` | list of extension | `[]` | no | **new**, #231 | Treat these as code in addition to `CODE_EXT` (e.g. `twig`, `tf`, `proto`). |
| `ignorePaths` | list of glob | `[]` | no | **new**, #231 | A write to a matching path is recorded as `file`, not `code`, so it never arms the gate by itself. For generated output and scratch directories inside the repo. Loosens the gate, so doctor lists it. |

Removing a default extension is deliberately not offered. A project that wants an extension ignored can ignore the paths that hold it, which keeps the decision visible and scoped.

### Checks: `.claude/verification.json`

| Key | Type | Default | Local | Issue | Effect |
|---|---|---|---|---|---|
| `checks[].paths` | list of glob | none (always runs) | no | **new**, #232 | Run the check only when a file this session wrote in this checkout (`$MYSPEC_SESSION_FILES`) matches. In a polyglot monorepo, `api/**` scopes the PHP checks and `web/**` the TypeScript ones. Loosens the gate, so doctor lists it, and a required check scoped by `paths` is reported in the stop message when it was skipped. |
| `containers` | map of name → `{mountSource, mountTarget}` | none | yes | **new**, #221 | Describes a container that bind-mounts part of the repo. `mountSource` is repo-relative (usually `.`), `mountTarget` is the absolute path inside the container. |
| `checks[].runIn` | container name | none | no | **new**, #221 | The gate exports `MYSPEC_CHECK_WORKDIR` = `mountTarget` + the checkout's path relative to the main checkout's `mountSource`. The command uses it, e.g. `docker compose exec -w "$MYSPEC_CHECK_WORKDIR" api make lint`, which is right in the main checkout and in a worktree nested under the mount. When the worktree is not under `mountSource`, the check is refused with "this worktree is not visible inside the container" and never run. A check with `runIn` satisfies the #220 refusal. |

`containers` is local-overridable because the mount layout is a fact about a developer's machine; `runIn` is not, because which checks run in a container is team policy. The framework never names a container runtime: the command is the project's, and `MYSPEC_CHECK_WORKDIR` works with Docker, Podman, `nerdctl` or `kubectl exec` alike.

### Worktree guard: `.myspec.json` `isolation`

| Key | Type | Default | Local | Issue | Effect |
|---|---|---|---|---|---|
| `blockInMain` | list of anchored ERE | `[]` | no | exists | Extra commands blocked in the main checkout while a session is in worktree mode. |
| `allowLinkedModules` | bool | `false` | yes | exists | Accept a linked dependency tree at the Stop gate. Loosens the gate. |
| `worktreeRoot` | repo-relative path | `.claude/worktrees` | no | exists | Where worktrees are created. |

### Deferred

These came up during triage and are not in this round, because no issue has shown a project that needs them yet: an allowlist for `no-absolute-paths` (#234 chose file-kind scoping instead), `allowInMain` carve-outs for the worktree guard, and per-check environment variables. They fit the same layers and schema if they are needed later.

## Reading settings

A new helper, `lib/myspec-config.sh get <dotted.key> [--root <checkout>]`, prints the effective value as JSON after merging layers 1–4, and `lib/myspec-config.mjs` does the same for lib scripts. It reads from the main checkout's root when called from a linked worktree, since `.myspec.local.json` is untracked and exists only there; `.myspec.json` is read from the checkout itself, so a branch that changes a setting is verified with its own setting. Hooks keep `jq` as their only dependency.

The schema lives in `lib/myspec-config.schema.json`. Hooks don't validate at runtime; they read with defaults and name an unreadable key. Validation is doctor's job.

## Visibility: doctor (#233)

- `setup-doctor schema` validates `.myspec.json`, `.myspec.local.json` and `verification.json` against the schema: unknown keys (with a near-miss suggestion), wrong types, a local-only key set in the committed file and vice versa, and `runIn` naming an undefined container.
- A new `setup-doctor settings` surface prints every key that differs from its default, its value and its layer, and marks the ones that loosen a gate. `/myspec:doctor` includes it, so a reviewer of a consumer project sees the effective policy in one place.

## #226: how `work-isolation.md` loads

Decision proposed: **split it.**

- An always-loaded core of about 150 tokens: the user chooses develop or worktree before the first source edit, two hooks enforce it, and a block message says what to do and where the full procedure is.
- The procedure (worktree creation, provisioning, `git -C`, finishing) moves to a reference file that the block messages and the isolation-related skills cite. It is read when it's needed, not on every session.

Why not the other two options:
- **Always load:** about 1,100 tokens in every session of every project, while `rules/workflow.md` and `rules/memory-system.md` already sit at the 1,000-token budget (#185). The enforcement is in the hooks, so most of the text is procedure that is only needed once a block fires.
- **Globs derived from the topology file:** `backbone.yml` is optional and often stale, so the generated globs would miss directories in exactly the projects that need them, and writing project-specific globs into a framework-owned rule recreates the pinning problem. No directory list is ever complete across stacks: the misses #226 reports (`config/`, `plugins/`, `middleware/`, `bin/`, `scripts/`) are ordinary in one ecosystem and absent in the next.

This is independent of the settings work and can land as its own PR.

## Rollout

Each step is one PR. Steps 2 to 4 touch disjoint files and run in parallel once step 1 has merged.

| Step | Issues | Files | Notes |
|---|---|---|---|
| 1. Reader and schema | — | `lib/myspec-config.{sh,mjs}`, `lib/myspec-config.schema.json`, tests, `init`/`update` gitignore entry for `.myspec.local.json` | Foundation, no behaviour change. |
| 2. Provisioning | #230, #222 (clone and directory copy), #193 (`clean`) | `lib/worktree-provision.sh`, `skills/_shared/worktree-provisioning.md`, tests | Merge #236 together with this. |
| 3. Checks | #232, #221 | `hooks/verify-before-stop.sh`, `templates/verification.json`, `docs/stop-gate.md`, tests | After #236, which edits the same check loop. |
| 4. Code-change detection | #231 | `hooks/mark-code-changed.sh`, tests | |
| 5. Doctor | #233 | `lib/setup-doctor.mjs`, `skills/doctor/SKILL.md`, tests | Last, because it validates everything above. |
| — | #226 | `framework-files/rules/work-isolation.md`, a new reference file, hook block messages | Independent; can run alongside step 1. |

Examples for every step pair at least two stacks, and none names a port.

## Questions for review

1. **The local layer (`.myspec.local.json`).** It is what lets a mixed team share one `verification.json`. Ship it in step 1, or start with layers 1, 2 and 4 only?
2. **#226 split.** Agree with splitting the rule over always-loading it or deriving globs?
3. **`install` runs by default** when it is set, with `--no-install` to skip. The alternative is to print the steps and let the agent run them. Running them is what makes #236 safe to merge; printing keeps provisioning fast and offline-safe.
4. **No removal of default code extensions.** Is `ignorePaths` enough, or is there a project that needs an extension removed outright?
