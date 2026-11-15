---
title: "AI-First Development Workflow"
purpose: "Feature development process and code generation policy"
updated: 2026-11-15
see_also:
  - ${aiDir}/features/index.yaml
---

# AI-First Development Workflow

**Documentation is the source of truth.** This project is developed using AI.

## Code Generation Policy

Any source-code change — new files, modifications, components/functions/modules, anything outside `${aiDir}/` and `docs/` — requires explicit user instruction ("implement this", "write the code", "create the file", "make these changes"). Reading, analyzing, planning, and editing documentation under `${aiDir}/` or `docs/` never require permission.

## Feature Pipelines

All are `/myspec:*` skills.

- **New feature:** `feature-spec` → `feature-spec-review` → `feature-tech-spec` → `feature-tech-spec-review` → `feature-plan` → `feature-implement` → `feature-complete`
- **Modification:** `feature-update` → `feature-plan` → `feature-implement` → `feature-complete`

## Documentation Requirements

New feature → `${aiDir}/features/{feature}/` (layout and status rules: `.claude/rules/feature-docs.md`, loaded with those files); feature changes → update the same directory; architecture decisions → `${aiDir}/decisions/`; a new app, package, or top-level command → the topology file named in `.myspec.json` (`/myspec:backbone-sync` audits it). Every markdown file under `${aiDir}/` carries YAML frontmatter — enforced by the `validate-frontmatter.sh` PreToolUse hook (`${aiDir}/ideas/` exempt).
