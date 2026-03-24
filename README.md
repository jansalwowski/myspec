# myspec

Specification-Driven Development framework for Claude Code. Provides skills for feature workflows, memory system, ideas pipeline, and project scaffolding.

## Installation

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

## Skills Reference

| Skill | Purpose |
|-------|---------|
| **Project Setup** | |
| `/myspec:init` | Initialize myspec in a new project |
| `/myspec:update` | Update framework files to latest version |
| `/myspec:setup <type>` | Guided generation for project files (anti-patterns, conventions, claude-md, pre-flight, index-md, workflow) |
| **Feature Workflow** | |
| `/myspec:feature-spec` | Create feature specification (spec.md + dependencies.md) |
| `/myspec:tech-spec` | Create technical design from approved spec |
| `/myspec:feature-complete` | Mark feature done, update docs |
| `/myspec:feature-decompose` | Split large feature into sub-features |
| `/myspec:spec-review` | Validate spec for completeness and consistency |
| `/myspec:spec-cleanup` | Move technical content from spec to tech-spec |
| `/myspec:spec-sync` | Detect and fix documentation drift |
| `/myspec:scenario` | Generate Gherkin test scenarios |
| **Memory System** | |
| `/myspec:memory-preflight` | Pre-work checks across all memory types |
| `/myspec:memory-create` | Create typed memory (procedural/semantic/episodic) |
| `/myspec:memory-lookup` | Search memories for solutions |
| `/myspec:session-start` | Start tracked work session |
| `/myspec:session-complete` | Archive session, extract memories |
| **Ideas Pipeline** | |
| `/myspec:idea-intake` | Process new idea into priority queue |
| `/myspec:idea-process` | Convert idea to feature specification |
| **Meta** | |
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
    "anti-patterns.md": { "version": "1.0.0", "lastUpdated": "2026-03-24" }
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
.myspec.json                    # Config file
${aiDir}/                       # AI documentation directory (.ai or ai)
  features/index.yaml           # Feature manifest
  memory/                       # Memory system
  templates/                    # Session/memory templates
  ideas/                        # Ideas pipeline
  conventions/                  # Project coding standards
  decisions/                    # Architecture decision records
  plans/                        # Implementation plans
  specs/                        # Design specs
  anti-patterns.md              # Framework + project anti-patterns
  pre-flight.md                 # Pre-work checklist
  memory-system.md              # Memory architecture reference
  INDEX.md                      # Documentation index
```
