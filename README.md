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

Both runtimes share the same project-level verification config at `.claude/verification.json` when it exists.

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
| `/myspec:feature-plan` | Create execution-ready implementation plan from tech-spec. Step 0 picks **normal** (single-executor, default) or **orchestrator** (per-milestone Worker / SpecReview / QualityReview chain — no Planner since plan tasks are already atomic) — opt-in |
| `/myspec:feature-implement` | Execute implementation plan with subagent dispatch. Auto-detects `orchestration: agent-chain` in plan front-matter and offers `orchestrator` / `orchestrator-auto` / `normal-fallback` run modes |
| `/myspec:feature-implement-review` | Independently audit that the built code fulfills the spec and plan (traceability + behavioral); writes conformance-report.md and routes findings — never edits code |
| `/myspec:code-review` | Review changed code for quality, standards, and bugs — universal dimensions plus project rules. Configurable via `/myspec:setup code-review` |
| `/myspec:feature-update` | Plan changes to an already-implemented feature |
| `/myspec:feature-verify` | Verify feature implementation matches spec |
| `/myspec:features-status-audit` | Batch-audit the whole feature manifest against on-disk docs (`lib/features-status-audit/audit.mjs`) |
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
| `/myspec:session-complete` | Archive session, extract memories |
| `/myspec:session-clean` | Sweep dangling auto-created sessions in `.claude/state/sessions/` — deletes empty, archives substantive, never touches the running agent's own session ([examples](examples/skills/session-clean.md)) |
| `/myspec:memory-sanitize` | Audit the user-level auto-memory store in `~/.claude-personal/projects/`: triage entries (keep/drop/promote/merge/compress/conflict), grep for live citations before any delete, compress bloated bodies against the length budget in `.claude/rules/auto-memory-style.md`, supersede contradictions non-destructively, never auto-promote or auto-rewrite ([examples](examples/skills/memory-sanitize.md)) |
| **Ideas Pipeline** | |
| `/myspec:idea-intake` | Process new idea into priority queue |
| `/myspec:idea-process` | Convert idea to feature specification |
| **Utilities** | |
| `/myspec:brainstorm` | Explore a problem space before committing to a spec |
| `/myspec:root-cause-debugging` | Systematic 4-phase debugging methodology with 3-attempt escalation rule |
| `/myspec:skill-verify` | Verify a skill file follows optimization guidelines |
| `/myspec:worktree-cleanup` | Clean up git worktrees after feature branches |
| `/myspec:docs-sanitize` | Clean up documentation naming and structure |
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
  "provision": { "symlink": ["node_modules"], "copy": [".eslintcache"] }
}
```

`allowLinkedModules` lets the Stop hook verify a worktree whose `node_modules` is a symlink; `blockInMain` adds command patterns the Bash guard blocks in the main checkout while a session works in a worktree; `provision` is what `worktree-provision.sh` links and copies into a new worktree.

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

**Upgrading from 1.x:** 2.0 migrates from 1.28.0 or later. A project on an older version runs the 1.28 update first: check out the plugin at tag `v1.28.0`, start Claude with `--plugin-dir` pointing at it, run `/myspec:update`, then return to the current plugin.

## Framework rules shipped to `.claude/rules/`

`init` (first-time) and `update` (subsequent) install eight rule files into the consuming project's `.claude/rules/` directory. Three load on every turn (`workflow.md`, `memory-system.md`, `auto-memory-style.md`); the other five carry `paths:` frontmatter and load only for matching work:

| File | Governs |
|------|---------|
| `workflow.md` | Feature workflow phases, the status state machine, when to invoke which skill |
| `memory-system.md` | Project-level memory (`${aiDir}/memory/` — sessions, procedural/semantic/episodic). Triggers, layer budgets, session lifecycle. |
| `auto-memory-style.md` | Harness-managed **user-level** auto-memory at `~/.claude-personal/projects/<encoded_cwd>/memory/`. Length budget per type, cut list, pre-write ADD/UPDATE/NO-OP consolidation, conflict resolution. |
| `ideas.md` | Ideas pipeline (intake → priority → processing) |
| `skill-optimization.md` | Skill-authoring meta-rules (frontmatter, naming, token efficiency) |
| `paths.md` | Path portability — `${aiDir}` placeholder, `<repo_root>`/`<encoded_cwd>` forms, no absolute paths in shared artifacts |
| `skill-self-test.md` | Skill `dependencies:` validation (declared packages/paths must exist) |
| `work-isolation.md` | The develop-vs-worktree decision, the two hooks that enforce it, worktree provisioning, promotion of develop-mode work to a PR (path-gated to source trees) |

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
  INDEX.md                      # Documentation index
```
