---
title: "AI-First Development Workflow"
purpose: "Feature development process and code generation policy"
load_when: "starting new features or modifying existing code"
updated: 2026-03-29
see_also:
  - ${aiDir}/conventions/documentation.md
  - ${aiDir}/features/index.yaml
---

# AI-First Development Workflow

**Documentation is the source of truth.** This project is developed using AI.

## Code Generation Policy

### Requires Explicit User Instruction

- Writing new source code files
- Modifying existing source code
- Creating components, functions, modules
- Any changes outside `${aiDir}/` and `docs/`

**Triggers:** "implement this", "write the code", "create the file", "make these changes"

### Always Allowed

- Reading and analyzing code
- Answering questions
- Creating/updating documentation in `${aiDir}/` or `docs/`
- Proposing plans
- Research and exploration

## Feature Workflow Skills

| Phase | When | Skill |
|-------|------|-------|
| 1. Specification | Starting new feature | `/myspec:feature-spec` |
| 1a. Decompose | Feature too large for single tech-spec | `/myspec:feature-decompose` |
| 1b. Review | Validate spec before tech-spec | `/myspec:feature-spec-review` |
| 2. Technical Design | Spec approved, ready to plan implementation | `/myspec:feature-tech-spec` |
| 2a. Review | Validate tech-spec before implementation | `/myspec:feature-tech-spec-review` |
| 3. Implementation Plan | Tech-spec approved, ready to create tasks | `/myspec:feature-plan` |
| 4. Execution | Implementation plan approved, ready to build | `/myspec:feature-implement` |
| 5. Feature Completion | Implementation complete, updating docs | `/myspec:feature-complete` |
| — | Modifying an existing implemented feature | `/myspec:feature-update` |

> **New feature pipeline:** `feature-spec` → `feature-spec-review` → `feature-tech-spec` → `feature-tech-spec-review` → `feature-plan` → `feature-implement` → `feature-complete`
> **Modification pipeline:** `feature-update` → `feature-plan` → `feature-implement` → `feature-complete`
> **Optional:** `/myspec:feature-decompose` (large features), `/myspec:feature-scenario` (test scenarios), `/myspec:feature-seed-data` (test data)

## Feature Documentation Structure

| File | Phase | Purpose |
|------|-------|---------|
| `spec.md` | 1 | Product specification (what & why) - REQUIRED |
| `dependencies.md` | 1 | Cross-feature dependency map - REQUIRED |
| `tech-spec.md` | 2 | Implementation specification (how) |
| `scenarios.md` | 3 | Test scenarios in Gherkin format |
| `seed/` | 3 | Test seed data (JSON files) |
| `plans/` | 5 | Archived implementation plans (dated, moved here on feature-complete) |
| `CHANGELOG.md` | 5 | Feature evolution history — one entry per archived plan |

## Feature Manifest

`${aiDir}/features/index.yaml` is the single source of truth for feature status.

Update when:
- Creating a new feature
- Changing feature status (draft → in-progress → complete)
- Updating dependencies

## Sub-Feature Convention

| Pattern | Location | Contains |
|---------|----------|----------|
| Main features | `${aiDir}/features/index.yaml` | Top-level features only |
| Sub-features | `${aiDir}/features/{feature}/index.yaml` | Sub-feature array |

**Marker**: Features with `subfeatures: true` have a dedicated `{feature}/index.yaml` with sub-features.

## Documentation Requirements

| Change Type | Documentation Location |
|-------------|----------------------|
| New feature | `${aiDir}/features/{feature}/` |
| Feature changes | Update `${aiDir}/features/{feature}/` |
| Architecture decisions | `${aiDir}/decisions/` |

## Frontmatter

All markdown files in `${aiDir}/` must have YAML frontmatter for AI context loading. Verify with the project's documentation audit command if configured.
