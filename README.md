# myspec

Specification-Driven Development framework for Claude Code and Codex. Provides skills for feature workflows, memory system, ideas pipeline, and project scaffolding.

## Installation

### Codex

This repository now includes a native Codex manifest at `.codex-plugin/plugin.json`.
It also includes a Codex marketplace manifest at `.agents/plugins/marketplace.json` and a marketplace-compatible plugin wrapper at `plugins/myspec/`.

Install it as a local plugin by pointing Codex at this repository root, then use the skills from `skills/`.

In Codex, use skill names directly, for example:

```
Use the myspec init skill to set up this project.
Use the myspec bootstrap skill before making changes.
Use the myspec feature-spec skill for the new authentication flow.
```

Codex support includes native plugin hooks via `hooks.json`. Claude compatibility remains project-local through `.claude/hooks/`, `.claude/settings.json`, and `.claude/verification.json`.

The same hook scripts are now portable:
- in Claude, `init` can copy them into `.claude/hooks/`
- in Codex, the plugin runs them directly from this repository

Both runtimes share the same project-level verification config at `.claude/verification.json` when it exists. A repo whose lint or type-check is already red on the default branch gives that check a `diffCommand`: the gate runs it in place of `command`, with `$MYSPEC_BASE_REF` exported as the merge base with the default branch, so the check covers what the branch changed instead of blocking on pre-existing debt.

The gate runs only after the session wrote code, and it verifies each checkout of the repository the session wrote in, so a linked worktree edited from the main checkout gets verified. Reading, grepping or running a file doesn't count, and neither does a write in another repository. When several sessions share one checkout, the checks can fail on another session's uncommitted work. A failure that names only files this session didn't write becomes a warning. Any other failure still blocks, and the block lists the uncommitted changes that aren't the session's. Each check also gets `$MYSPEC_SESSION_FILES`, one repo-relative path per line, for a per-file linter that should cover only the files this session wrote. Rules and known limits: [`docs/stop-gate.md`](docs/stop-gate.md).

Each check runs under a 120 s cap, and the whole stop, every check in every checkout, under a 300 s budget: a check the budget leaves no time for is reported as not run, and the stop blocks. `MYSPEC_GATE_BUDGET_SECONDS` lowers the budget and cannot raise it. At the cap the gate kills the check's process group on this machine, and nothing else. Work a check runs in a container or on another host (`docker exec`, `docker compose exec`, `kubectl exec`, `ssh`) keeps running after its client dies, and the next stop starts another run on top of it (issue #147). Give such a check a `cleanup` command. The gate runs it after a timeout, under its own 30 s cap, with the same `$MYSPEC_CHECK_RUN_ID` the check saw:

```json
{
  "name": "Test",
  "command": "docker compose exec -T -e MYSPEC_CHECK_RUN_ID <service> sh -c 'echo $$ > \"/tmp/$MYSPEC_CHECK_RUN_ID.pid\"; exec <test command>'",
  "cleanup": "docker compose exec -T -e MYSPEC_CHECK_RUN_ID <service> sh -c 'kill -TERM -\"$(cat \"/tmp/$MYSPEC_CHECK_RUN_ID.pid\")\"'",
  "required": true
}
```

The exec'd shell leads its own process group in the container, so `kill -TERM -<pid>` also stops the runner's workers. Write it without `--`, which BusyBox `kill` rejects.

### Add the marketplace (once per machine)

```
/plugin marketplace add jansalwowski/myspec
```

### Install the plugin

```
/plugin install myspec@myspec-marketplace
```

### Initialize a project

```
/myspec:init
```

This starts an interactive wizard that creates `.myspec.json`, scaffolds the AI documentation directory, and copies framework files.

### Local development

```bash
claude --plugin-dir /path/to/myspec
```

Use `/reload-plugins` after making changes.

Run `scripts/install-git-hooks.sh` once per clone. It sets up two hooks:

- **pre-commit:** lints staged skills, staged `lib/` JS with ESLint, and staged `hooks/` and `lib/` shell scripts with ShellCheck. ESLint and ShellCheck are each skipped with a notice when they can't run.
- **pre-push:** runs the eval cases for the skills you changed. These evals run on your Claude Code login and only report; they never block the push. Skip them with `MYSPEC_SKIP_EVALS=1`.

See [evals/README.md](evals/README.md) and the Quality gates section of [AGENTS.md](AGENTS.md).

For Codex, reload or reinstall the local plugin after editing the manifest or skills, depending on your Codex setup.

To add this repository as a Codex marketplace from Git, use:

```bash
codex marketplace add git@github.com:jansalwowski/myspec.git --ref main
```

## Skills Reference

| Skill | Purpose |
|-------|---------|
| **Project Setup** | |
| `/myspec:init` | Initialize myspec in a new project |
| `/myspec:update` | Update framework files to latest version |
| `/myspec:setup <type>` | Generate project-specific files from guided wizards (backbone, claude-md, conventions, code-review, mockup, index-md, workflow, pre-flight, anti-patterns) |
| `/myspec:bootstrap` | Load project context, memory indexes, and active session at session start |
| **Feature Workflow** | |
| `/myspec:feature-discover` | Reverse-engineer an undocumented feature from existing code into discovery.md (+ optional spec.md / tech-spec.md) ([examples](examples/skills/feature-discover.md)) |
| `/myspec:feature-spec` | Create feature specification (spec.md + dependencies.md) |
| `/myspec:feature-decompose` | Split large feature into sub-features |
| `/myspec:feature-spec-review` | Validate spec for completeness and consistency |
| `/myspec:cross-spec-validation` | Check spec against related specs for contradictions and broken contracts |
| `/myspec:feature-mockup` | Build spec-validation UI mockups under `${aiDir}/features/{feature}/mockups/` — technology-agnostic; stack config via `/myspec:setup mockup` ([examples](examples/skills/feature-mockup.md)) |
| `/myspec:feature-mockup-review` | Audit mockups for UX issues, scope creep, loose ends, missing states, and project hard-guard violations ([examples](examples/skills/feature-mockup-review.md)) |
| `/myspec:feature-tech-spec` | Create technical design from approved spec |
| `/myspec:feature-tech-spec-review` | Review tech-spec for implementability and pattern conformance |
| `/myspec:feature-plan` | Create execution-ready implementation plan from tech-spec: milestones, phases, parallel groups, per-task spec contracts and interfaces |
| `/myspec:feature-implement` | Execute implementation plan by dispatching one implementer subagent per task, reviewing at every phase boundary, and closing with a holistic full-diff review |
| `/myspec:feature-implement-review` | Independently audit that the built code fulfills the spec and plan (traceability + behavioral); writes conformance-report.md and routes findings — never edits code |
| `/myspec:code-review` | Review changed code for quality, standards, and bugs — universal dimensions plus project rules. Configurable via `/myspec:setup code-review` |
| `/myspec:feature-update` | Plan changes to an already-implemented feature |
| `/myspec:feature-verify` | Verify feature implementation matches spec |
| `/myspec:feature-status-audit` | Batch-audit the whole feature manifest against on-disk docs (`lib/feature-status-audit/audit.mjs`) |
| `/myspec:feature-complete` | Mark feature done, update docs |
| `/myspec:feature-spec-cleanup` | Move technical content from spec to tech-spec |
| `/myspec:feature-spec-sync` | Detect and fix documentation drift |
| `/myspec:feature-scenario` | Generate Gherkin test scenarios |
| `/myspec:feature-seed-data` | Generate test seed data for a feature |
| **Memory System** | |
| `/myspec:memory-preflight` | Pre-work checks across all memory types |
| `/myspec:memory-create` | Create typed memory (procedural/semantic/episodic) |
| `/myspec:memory-lookup` | Search memories for solutions |
| `/myspec:memorize <content>` | One-shot capture of an explicit user-provided fact or rule into a typed memory ([examples](examples/README.md)) |
| `/myspec:memorify` | Scan the current conversation, surface candidates, and save approved ones as memories ([examples](examples/README.md)) |
| `/myspec:session-start` | Start tracked work session |
| `/myspec:session-complete` | Archive session, extract memories, report repeated friction and whose side it is on ([docs/friction-report.md](docs/friction-report.md)) |
| `/myspec:session-clean` | Sweep dangling auto-created sessions in `.claude/state/sessions/` — deletes empty, archives substantive, never touches the running agent's own session ([examples](examples/skills/session-clean.md)) |
| `/myspec:memory-sanitize` | Audit the user-level auto-memory store in `~/.claude-personal/projects/`: triage entries (keep/drop/promote/merge/compress/conflict), grep for live citations before any delete, compress bloated bodies against the length budget in `.claude/rules/auto-memory-style.md`, supersede contradictions non-destructively, never auto-promote or auto-rewrite ([examples](examples/skills/memory-sanitize.md)) |
| **Ideas Pipeline** | |
| `/myspec:idea-intake` | Process new idea into priority queue |
| `/myspec:idea-process` | Convert idea to feature specification |
| **Utilities** | |
| `/myspec:brainstorm` | Explore a problem space before committing to a spec |
| `/myspec:root-cause-debugging` | Systematic 4-phase debugging methodology with 3-attempt escalation rule |
| `/myspec:skill-verify` | Verify a skill file follows optimization guidelines |
| `/myspec:backbone-sync` | Audit the project topology file against the repo in both directions — stale entries, undocumented workspace members and commands, git-backed liveness signals (`lib/backbone-audit/audit.mjs`) — then fix it. Refuses to run rather than half-read unsupported YAML, and names every check that could not run instead of reporting clean |
| `/myspec:worktree-clean` | Clean up git worktrees after feature branches |
| `/myspec:doctor` | Health check of every agent-facing surface, in three tiers: `lib/setup-doctor.mjs` for the mechanical checks (~1s, no model), one surface on request, or the full six-surface audit (CLAUDE.md + rules, skills/agents, `${aiDir}` docs, memory tree, hooks + harness config, feature manifest) with approval-gated fixes as grouped PRs |
| `/myspec:upstream-sync` | Check tracked upstream repos (e.g. obra/superpowers) for changes worth porting into local skills |

## Configuration

`.myspec.json` at project root:

```json
{
  "aiDir": ".ai",
  "frameworkVersion": "<current plugin version>",
  "project": {
    "name": "Project Name",
    "description": "One-line description",
    "techStack": "PHP 8.3, Laravel 11, PostgreSQL"
  },
  "migrations": ["2.0.0-schema", "2.0.0-doctor-rule"]
}
```

`init` copies `frameworkVersion` and `migrations` from `framework-files/manifest.json` at run time. `aiDir` is required, stored without a trailing slash, and defaults to `.ai`.

A project that deliberately customizes a framework-owned file pins it, so `update` skips it instead of reverting the local edits:

```json
"frameworkFiles": {
  "rules/auto-memory-style.md": {
    "pinned": "locally compressed to halve always-loaded context"
  }
}
```

The key is the manifest key, not the destination path. Pinning is the project's decision — `update` reports pinned files and never adds or clears a pin itself.

An optional `isolation` block configures the work-isolation hooks; every key has a default:

```json
"isolation": {
  "worktreeRoot": ".claude/worktrees",
  "allowLinkedModules": false,
  "blockInMain": [],
  "ignoreBlockInMain": [],
  "provision": { "symlink": ["node_modules"], "copy": [".eslintcache"] }
}
```

`allowLinkedModules` makes `worktree-provision.sh` link a dependency directory even when its lockfiles differ from the main checkout's, and record the link without lockfile hashes, so the Stop hook does not compare them (for repos whose worktrees share one tree by design); `blockInMain` adds command patterns (anchored EREs) to the ones the Bash guard blocks in the main checkout while a session works in a worktree, whose default list in `lib/myspec-config.schema.json` covers builds and installs across the common stacks, and `ignoreBlockInMain` drops a default pattern by its exact text; `provision` is what `worktree-provision.sh` links and copies into a new worktree.

A `symlink` entry is a path string or an object naming the lockfiles that pin it; `"lockfiles": []` marks an entry unguarded:

```json
"symlink": ["node_modules", ".env", { "path": "deps", "lockfiles": ["deps.lock"] }]
```

A string entry whose basename is a well-known dependency directory takes its lockfiles from a built-in map — `node_modules` (npm, Yarn, pnpm, Bun lockfiles), `vendor` (`composer.lock`, `Gemfile.lock`, `go.sum`), `vendor/bundle` (`Gemfile.lock`), `.venv` / `venv` (`poetry.lock`, `Pipfile.lock`, `uv.lock`, `pdm.lock`, `requirements*.txt`) — matched beside the entry and at the repo root; a `*` stays within one directory. Any other string entry is unguarded. Provisioning skips an entry whose lockfiles the branch changed against `--base` or that differ from the main checkout's, and a tree that loads the project's own source from the main checkout (a Composer `vendor`, a `.venv` with an editable install, a tree holding workspace links such as an npm, Yarn, pnpm or Bun workspace package or a Composer path repository): through a link, checks would run the main checkout's code. It records what it linked, with each lockfile's hash, in the worktree's `.claude/state/provision.json`; the Stop hook blocks when a recorded lockfile changed or a recorded link moved, and says to rerun provision. A link provision did not make is reported by `/myspec:doctor` (`link-unrecorded`), not blocked.

When a session ends, a hook records one line per skill run in `.claude/state/metrics/runs.jsonl`: time, tokens, subagents, hook blocks and fix rounds. The file is gitignored, stays on your machine, and stores no prompt or file content. `/myspec:doctor` summarises it. To turn recording off, set `"feedback": { "metrics": false }`, `MYSPEC_DISABLE_METRICS=1` or `DO_NOT_TRACK=1`. See [docs/field-metrics.md](docs/field-metrics.md), which also covers opt-in OpenTelemetry.

`frameworkVersion` is kept in lockstep across `framework-files/manifest.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (with matching git `ref`), `.codex-plugin/plugin.json`, and `plugins/myspec/.codex-plugin/plugin.json`. Use `./scripts/bump-version.sh X.Y.Z` to update all five in one shot; see [RELEASING.md](RELEASING.md) for the full release workflow.

## Auto-setup for team repos

Add to your project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "myspec-marketplace": {
      "source": {
        "source": "github",
        "repo": "jansalwowski/myspec"
      }
    }
  },
  "enabledPlugins": {
    "myspec@myspec-marketplace": true
  }
}
```

## Updating

After updating the plugin (`/plugin marketplace update`), run in each project:

```
/myspec:update
```

This updates framework-owned files while preserving your project customizations. Since 2.0 it also runs the one-shot migrations listed in the manifest (recorded in `.myspec.json` `migrations`), deletes files the framework retired, and wires its own hooks in `.claude/settings.json`.

**Upgrading from 1.x:** see [docs/upgrading-to-2.0.md](docs/upgrading-to-2.0.md) — `/myspec:update` does the mechanical work, and that page covers what it cannot: references in your own files, and the behaviour changes with no file to grep. 2.0 migrates from 1.28.0 or later; a project on an older version runs the 1.28 update first (check out the plugin at tag `v1.28.0`, start Claude with `--plugin-dir` pointing at it, run `/myspec:update`, then return to the current plugin).

## Framework rules shipped to `.claude/rules/`

`init` (first-time) and `update` (subsequent) install eight rule files into the consuming project's `.claude/rules/` directory. Four load on every turn (`workflow.md`, `memory-system.md`, `auto-memory-style.md`, `work-isolation.md`); the other four carry `paths:` frontmatter and load only for matching work:

| File | Governs |
|------|---------|
| `workflow.md` | Feature workflow phases, the status state machine, when to invoke which skill |
| `memory-system.md` | Project-level memory (`${aiDir}/memory/` — sessions, procedural/semantic/episodic). Triggers, layer budgets, session lifecycle. |
| `auto-memory-style.md` | Harness-managed **user-level** auto-memory at `~/.claude-personal/projects/<encoded_cwd>/memory/`. Length budget per type, cut list, pre-write ADD/UPDATE/NO-OP consolidation, conflict resolution. |
| `ideas.md` | Ideas pipeline (intake → priority → processing) |
| `skill-optimization.md` | Skill-authoring meta-rules (frontmatter, naming, token efficiency) |
| `paths.md` | Path portability — `${aiDir}` placeholder, `<repo_root>`/`<encoded_cwd>` forms, no absolute paths in shared artifacts |
| `skill-self-test.md` | Skill `dependencies:` validation (declared packages/paths must exist) |
| `work-isolation.md` | The develop-vs-worktree contract in about 150 tokens: the user decides before the first source edit, two hooks enforce it, and the session id comes only from a block message. The procedure (the question, worktree creation and provisioning, promotion of develop-mode work to a PR) is `${aiDir}/work-isolation.md`, which the block messages cite |

The two memory rules cover different stores and do not overlap. `memory-system.md` is for the myspec-managed system in `${aiDir}/memory/`; `auto-memory-style.md` is for the harness-managed user-level store.

## Directory Structure (in consuming projects)

```
.myspec.json                    # Config file (aiDir, topologyFile, frameworkVersion, project, isolation)
.claude/state/                  # Gitignored per-checkout state: sessions/ (live logs), isolation/ (decisions), memory-ids.json
backbone.yml                    # Project topology file (generated by /myspec:setup backbone)
${aiDir}/                       # AI documentation directory (.ai or ai)
  features/index.yaml           # Feature manifest
  memory/                       # Memory system (indexes, typed memories, sessions/archive)
  .templates/                   # Session/memory templates (dot-dir)
  ideas/                        # Ideas pipeline
  conventions/                  # Project coding standards
  decisions/                    # Architecture decision records
  plans/                        # Implementation plans
  anti-patterns.md              # Framework anti-pattern index (project section appended by setup)
  pre-flight.md                 # Pre-work checklist
  work-isolation.md             # Develop-vs-worktree procedure the isolation hooks cite
  INDEX.md                      # Documentation index
```
