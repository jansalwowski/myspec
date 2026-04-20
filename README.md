# myspec

Specification-Driven Development framework for Claude Code and Codex. Provides skills for feature workflows, memory system, ideas pipeline, and project scaffolding.

## Installation

### Codex

This repository now includes a native Codex manifest at `.codex-plugin/plugin.json`.
It also includes a Codex marketplace manifest at `.agents/plugins/marketplace.json`.

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
codex marketplace add git@github.com:jansalwowski/myspec.git --ref feat/codex-plugin-support
```

## Skills Reference

| Skill | Purpose |
|-------|---------|
| **Project Setup** | |
| `/myspec:init` | Initialize myspec in a new project |
| `/myspec:update` | Update framework files to latest version |
| `/myspec:setup <type>` | Generate project-specific files from guided wizards (backbone, claude-md, conventions, index-md, workflow, pre-flight, anti-patterns) |
| `/myspec:bootstrap` | Load project context, memory indexes, and active session at session start |
| **Feature Workflow** | |
| `/myspec:feature-spec` | Create feature specification (spec.md + dependencies.md) |
| `/myspec:feature-decompose` | Split large feature into sub-features |
| `/myspec:feature-spec-review` | Validate spec for completeness and consistency |
| `/myspec:cross-spec-validation` | Check spec against related specs for contradictions and broken contracts |
| `/myspec:feature-tech-spec` | Create technical design from approved spec |
| `/myspec:feature-tech-spec-review` | Review tech-spec for implementability and pattern conformance |
| `/myspec:feature-plan` | Create execution-ready implementation plan from tech-spec |
| `/myspec:feature-implement` | Execute implementation plan with subagent dispatch |
| `/myspec:feature-update` | Plan changes to an already-implemented feature |
| `/myspec:feature-verify` | Verify feature implementation matches spec |
| `/myspec:feature-complete` | Mark feature done, update docs |
| `/myspec:feature-spec-cleanup` | Move technical content from spec to tech-spec |
| `/myspec:feature-spec-sync` | Detect and fix documentation drift |
| `/myspec:feature-scenario` | Generate Gherkin test scenarios |
| `/myspec:feature-seed-data` | Generate test seed data for a feature |
| **Memory System** | |
| `/myspec:memory-preflight` | Pre-work checks across all memory types |
| `/myspec:memory-create` | Create typed memory (procedural/semantic/episodic) |
| `/myspec:memory-lookup` | Search memories for solutions |
| `/myspec:session-start` | Start tracked work session |
| `/myspec:session-complete` | Archive session, extract memories |
| **Ideas Pipeline** | |
| `/myspec:idea-intake` | Process new idea into priority queue |
| `/myspec:idea-process` | Convert idea to feature specification |
| **Utilities** | |
| `/myspec:brainstorm` | Explore a problem space before committing to a spec |
| `/myspec:root-cause-debugging` | Systematic 4-phase debugging methodology with 3-attempt escalation rule |
| `/myspec:skill-verify` | Verify a skill file follows optimization guidelines |
| `/myspec:worktree-cleanup` | Clean up git worktrees after feature branches |
| `/myspec:docs-sanitize` | Clean up documentation naming and structure |

## Configuration

`.myspec.json` at project root:

```json
{
  "aiDir": ".ai",
  "frameworkVersion": "1.0.0",
  "project": {
    "name": "Project Name",
    "description": "One-line description",
    "techStack": "PHP 8.3, Laravel 11, PostgreSQL"
  },
  "frameworkFiles": {
    "memory-index.md": { "version": "1.0.0", "lastUpdated": "2026-03-24" }
  }
}
```

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

This updates framework-owned files while preserving your project customizations.

## Directory Structure (in consuming projects)

```
.myspec.json                    # Config file (aiDir, topologyFile, frameworkVersion, project)
backbone.yml                    # Project topology file (generated by /myspec:setup backbone)
${aiDir}/                       # AI documentation directory (.ai or ai)
  features/index.yaml           # Feature manifest
  memory/                       # Memory system
  templates/                    # Session/memory templates
  ideas/                        # Ideas pipeline
  conventions/                  # Project coding standards
  decisions/                    # Architecture decision records
  plans/                        # Implementation plans
  specs/                        # Design specs
  memory-index.md               # Framework + project memory index (Layer 1) and anti-patterns
  pre-flight.md                 # Pre-work checklist
  memory-system.md              # Memory architecture reference
  INDEX.md                      # Documentation index
```
