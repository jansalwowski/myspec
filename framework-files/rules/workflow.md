---
title: "AI-First Development Workflow"
purpose: "Feature development process and code generation policy"
updated: 2026-09-03
see_also:
  - ${aiDir}/features/index.yaml
---

# AI-First Development Workflow

**Documentation is the source of truth.** This project is developed using AI.

## Code Generation Policy

Any source-code change — new files, modifications, components/functions/modules, anything outside `${aiDir}/` and `docs/` — requires explicit user instruction ("implement this", "write the code", "create the file", "make these changes"). Reading, analyzing, planning, and editing documentation under `${aiDir}/` or `docs/` never require permission.

## Feature Pipelines

- **New feature:** `feature-spec` → `feature-spec-review` → `feature-tech-spec` → `feature-tech-spec-review` → `feature-plan` → `feature-implement` → `feature-complete`
- **Modification:** `feature-update` → `feature-plan` → `feature-implement` → `feature-complete`
- **Optional:** `feature-decompose` (feature too large for one tech-spec), `cross-spec-validation` (after spec approval or updates), `feature-mockup` → `feature-mockup-review` (visual spec validation between spec approval and tech design; configure with `/myspec:setup mockup`), `feature-scenario`, `feature-seed-data`

All are `/myspec:*` skills; each skill's own description covers when to invoke it.

## Feature Documentation Structure

| File | Phase | Purpose |
|------|-------|---------|
| `spec.md` | 1 | Product specification (what & why) — REQUIRED |
| `dependencies.md` | 1 | Cross-feature dependency map — REQUIRED |
| `tech-spec.md` | 2 | Implementation specification (how) |
| `scenarios.md` | 3 | Test scenarios in Gherkin format |
| `seed.json` | 3 | Test seed data |
| `plans/` | 5 | Archived implementation plans (dated, moved here on feature-complete) |
| `CHANGELOG.md` | 5 | Feature evolution history — one entry per archived plan |

## Status State Machine

Two status vocabularies exist; do not mix them.

- **Doc status** (`status:` in spec.md / tech-spec.md frontmatter): `draft | approved | deprecated`. The review skills flip `draft → approved` on pass (no Critical/High findings) with user confirmation; `feature-update` flips `approved → draft`; deprecation is manual or via `cross-spec-validation`.
- **Manifest status** (per-feature `status:` in `${aiDir}/features/index.yaml` — the single source of truth for progress): `planned | draft | in-progress | complete | deprecated`. `feature-spec` and `idea-process` create `draft`; `feature-implement` flips `draft → in-progress` at execution start; `feature-complete` flips `in-progress → complete` only when the plan's checkboxes are all `[x]` or remaining tasks are explicitly deferred; `planned` and `deprecated` are set by hand.

Completion percentage comes from **implementation-plan.md checkboxes** whenever a plan exists (tech-spec checkboxes are a fallback when no plan exists; code inspection never is). Per-status doc expectations are codified in `/myspec:feature-status-audit` — treat its matrix as authoritative.

## Sub-Feature Convention

The top-level manifest holds main features only. A feature flagged `subfeatures: true` there has a dedicated `{feature}/index.yaml` whose list key is `sub-features:` — these are the only two spellings; do not introduce others.

## Documentation Requirements

New feature → `${aiDir}/features/{feature}/`; feature changes → update the same directory; architecture decisions → `${aiDir}/decisions/`. Every markdown file under `${aiDir}/` carries YAML frontmatter — enforced by the `validate-frontmatter.sh` PostToolUse hook (`${aiDir}/ideas/` exempt).
