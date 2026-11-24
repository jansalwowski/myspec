---
title: "Feature Documentation"
purpose: "Feature doc layout, status vocabularies, and the sub-feature manifest convention"
paths:
  - ${aiDir}/features/**
updated: 2026-11-24
---

# Feature Documentation

Optional pipeline steps (all `/myspec:*` skills): `feature-requirements` (rough requirements into a brief before mockups or the full spec), `feature-decompose` (feature too large for one tech-spec), `cross-spec-validation` (after spec approval or updates), `feature-mockup` → `feature-mockup-review` (visual spec validation before tech design; `/myspec:setup mockup` configures), `feature-spec {feature} scenarios|seed-data`.

## Feature Documentation Structure

| File | Phase | Purpose |
|------|-------|---------|
| `spec.md` | 1 | Product specification (what & why) — REQUIRED |
| `dependencies.md` | 1 | Cross-feature dependency map — REQUIRED |
| `tech-spec.md` | 2 | Implementation specification (how) |
| `scenarios.md` | 1 | Test scenarios in Gherkin format (optional) |
| `seed.json` | 1 | Test seed data (optional) |
| `plans/` | 5 | Archived implementation plans (moved here on feature-complete) |
| `CHANGELOG.md` | 5 | Feature evolution history — one entry per archived plan |

## Status State Machine

Two status vocabularies exist; do not mix them.

- **Doc status** (`status:` in spec.md / tech-spec.md frontmatter): `draft | approved | deprecated`. The review skills flip `draft → approved` on pass (no Critical/High findings) with user confirmation; `feature-update` flips `approved → draft`; deprecation is manual or via `cross-spec-validation`.
- **Brief stage** (`stage: brief` in spec.md frontmatter, beside `status: draft`): a short spec of tagged one-line requirements, written by `feature-requirements` before mockups or the full spec. It has no User Stories or Acceptance Criteria and no dependencies.md yet. `feature-spec` completes it in place and removes `stage`. A brief is never `approved`, so `feature-tech-spec` and `feature-plan` refuse it.
- **Manifest status** (per-feature `status:` in `${aiDir}/features/index.yaml` — the single source of truth for progress): `planned | draft | in-progress | complete | deprecated`. `feature-spec`, `feature-requirements` and `idea-process` create `draft`; `feature-implement` flips `draft → in-progress` at execution start; `feature-complete` flips `in-progress → complete` only when the plan's checkboxes are all `[x]` or remaining tasks are explicitly deferred; `planned` and `deprecated` are set by hand.
- **Manifest `note:`**: one line, ≤150 chars, current state only (e.g. a deferral pointer). Replace, never append. History goes to `CHANGELOG.md`; never PR state or SHAs.

Completion percentage comes from **implementation-plan.md checkboxes**, never from tech-spec checkboxes or code inspection. Per-status doc expectations are codified in `/myspec:feature-status-audit` — treat its matrix as authoritative.

## Sub-Feature Convention

The top-level manifest holds main features only. A feature flagged `subfeatures: true` there has a dedicated `{feature}/index.yaml` whose list key is `sub-features:` — the only two spellings.
