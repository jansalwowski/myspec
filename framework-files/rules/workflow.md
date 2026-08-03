---
title: "AI-First Development Workflow"
purpose: "Feature development process and code generation policy"
load_when: "starting new features or modifying existing code"
updated: 2026-08-03
see_also:
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
| 1c. Mockup (optional) | Validate the approved spec visually before tech design | `/myspec:feature-mockup` |
| 1d. Mockup Review (optional) | Audit mockups for UX, scope, and hard-guard issues | `/myspec:feature-mockup-review` |
| 2. Technical Design | Spec approved, ready to plan implementation | `/myspec:feature-tech-spec` |
| 2a. Review | Validate tech-spec before implementation | `/myspec:feature-tech-spec-review` |
| 3. Implementation Plan | Tech-spec approved, ready to create tasks | `/myspec:feature-plan` |
| 4. Execution | Implementation plan approved, ready to build | `/myspec:feature-implement` |
| 5. Feature Completion | Implementation complete, updating docs | `/myspec:feature-complete` |
| — | Modifying an existing implemented feature | `/myspec:feature-update` |

> **New feature pipeline:** `feature-spec` → `feature-spec-review` → `feature-tech-spec` → `feature-tech-spec-review` → `feature-plan` → `feature-implement` → `feature-complete`
> **Modification pipeline:** `feature-update` → `feature-plan` → `feature-implement` → `feature-complete`
> **Optional:** `/myspec:feature-decompose` (large features), `/myspec:cross-spec-validation` (after spec approval or updates — checks related specs), `/myspec:feature-mockup` → `/myspec:feature-mockup-review` (visual spec validation between spec approval and tech design; configure with `/myspec:setup mockup`), `/myspec:feature-scenario` (test scenarios), `/myspec:feature-seed-data` (test data)

## Feature Documentation Structure

| File | Phase | Purpose |
|------|-------|---------|
| `spec.md` | 1 | Product specification (what & why) - REQUIRED |
| `dependencies.md` | 1 | Cross-feature dependency map - REQUIRED |
| `tech-spec.md` | 2 | Implementation specification (how) |
| `scenarios.md` | 3 | Test scenarios in Gherkin format |
| `seed.json` | 3 | Test seed data |
| `plans/` | 5 | Archived implementation plans (dated, moved here on feature-complete) |
| `CHANGELOG.md` | 5 | Feature evolution history — one entry per archived plan |

## Status State Machine

Two status vocabularies exist; do not mix them.

**Doc status** — `status:` in spec.md / tech-spec.md frontmatter: `draft | approved | deprecated`.

| Transition | Owner |
|-----------|-------|
| (created as) `draft` | `/myspec:feature-spec`, `/myspec:feature-tech-spec`, `/myspec:feature-discover` |
| `draft → approved` | `/myspec:feature-spec-review` / `/myspec:feature-tech-spec-review` on pass (no Critical/High findings), with user confirmation |
| `approved → draft` | `/myspec:feature-update` (changed requirements need re-review) |
| `→ deprecated` | manual, or supersession found by `/myspec:cross-spec-validation` |

**Manifest status** — per-feature `status:` in `${aiDir}/features/index.yaml` (the single source of truth for feature progress): `planned | draft | in-progress | complete | deprecated`.

| Transition | Owner |
|-----------|-------|
| `planned` | manual manifest entry for a not-yet-started feature (no skill writes it) |
| `planned → draft` / (created as) `draft` | `/myspec:feature-spec`, `/myspec:idea-process` (when docs are created) |
| `draft → in-progress` | `/myspec:feature-implement` at execution start |
| `in-progress → complete` | `/myspec:feature-complete` — only when the implementation plan's checkboxes are all `[x]` or remaining tasks are explicitly deferred |
| `→ deprecated` | manual |

Completion percentage is computed from **implementation-plan.md checkboxes** whenever a plan exists; tech-spec step checkboxes are only a fallback when no plan has been created (per `/myspec:feature-spec-sync`), and code inspection is never the source. Per-status doc expectations are codified in `/myspec:features-status-audit` (lib/features-status-audit/audit.mjs); treat that matrix as authoritative.

## Sub-Feature Convention

| Pattern | Location | Contains |
|---------|----------|----------|
| Main features | `${aiDir}/features/index.yaml` | Top-level features only |
| Sub-features | `${aiDir}/features/{feature}/index.yaml` | Sub-feature array |

**Marker**: Features with `subfeatures: true` (boolean, in the top-level manifest) have a dedicated `{feature}/index.yaml` whose list key is `sub-features:` — these are the only two spellings; do not introduce others.

## Documentation Requirements

| Change Type | Documentation Location |
|-------------|----------------------|
| New feature | `${aiDir}/features/{feature}/` |
| Feature changes | Update `${aiDir}/features/{feature}/` |
| Architecture decisions | `${aiDir}/decisions/` |

## Frontmatter

All markdown files in `${aiDir}/` must have YAML frontmatter for AI context loading. Verify with the project's documentation audit command if configured.
