---
title: "Global Pre-flight Checklist"
purpose: "Preventive checks before starting any work"
feature: "global"
updated: 2026-03-24
---

# Pre-flight Checklist (Global)

Run these checks before starting work on any feature or task.

> **Tiered**: Full preflight for significant work (features, multi-file changes, debugging). For trivial changes (single-file fix, typo, config), read `${aiDir}/memory/index.md` directly and skip this checklist.

<!-- myspec:framework-start -->

## Always

- [ ] Read `${aiDir}/memory/index.md` (Layer 1 global index) for critical patterns to avoid
  → **Verify**: Can name 1 anti-pattern relevant to current task
- [ ] Check `${aiDir}/memory/sessions/active/*.md` for existing sessions:
  - If one is related to this work → Ask user: resume it or complete it first?
  - If unrelated sessions are dangling (>1h stale) → run `/myspec:session-clean`
  - Never touch another agent's fresh session (multi-agent workflows keep several active files)
  → **Verify**: No conflicting active session
- [ ] Read feature-specific `${aiDir}/features/{feature}/pre-flight.md` (if exists)
  → **Verify**: Completed feature-specific checks

## Before Implementation

- [ ] Verify spec is approved (check `status:` in frontmatter)
- [ ] Check `${aiDir}/features/{feature}/dependencies.md` for affected features
- [ ] Scan centralized memory indexes for relevant memories:
  - [ ] `${aiDir}/memory/procedural/index.md` — how-to patterns and workflows
  - [ ] `${aiDir}/memory/semantic/index.md` — facts, concepts, anti-patterns
  - [ ] `${aiDir}/memory/episodic/index.md` — past session outcomes and lessons
  → **Verify**: Scanned "Use When" column for keyword matches to current task
- [ ] Run anchor checks on loaded memories — if anchored file/pattern missing, flag as stale

## Before Risky Changes

→ See `.claude/rules/memory-system.md` "Before Risky Changes" (always in context).

## During Work

- [ ] Ensure a session file exists at `${aiDir}/memory/sessions/active/{session_id}.md` (auto-created on first code edit; for non-code sessions use `/myspec:session-start`)
- [ ] Log actions in session table (per `.claude/rules/memory-system.md`)
- [ ] Scan `${aiDir}/memory/` indexes when encountering errors

## Escalation Triggers

→ See `.claude/rules/memory-system.md` "Escalation Protocol" (always in context). The triggers and message template are defined there as the single source of truth.

## Completing Work

- [ ] Set your session file's status to `completed` (own file in `${aiDir}/memory/sessions/active/`)
- [ ] Fill `Outcome` section in session log
- [ ] Ask user: "Should we create a memory from this session?"
- [ ] Archive session log to `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md` (all of this is what `/myspec:session-complete` does)

<!-- myspec:framework-end -->

<!-- myspec:project-start -->

## After Implementation (Feature Work)

When completing implementation of a feature or sub-feature:

- [ ] **Verify implementation works** (run project verification commands):
  - [ ] Run type checking — verify no type errors
  - [ ] Run tests — verify all tests pass
  - [ ] Run app if applicable — verify feature works
- [ ] Update `${aiDir}/features/{feature}/tech-spec.md`:
  - [ ] Mark completed implementation steps with [x]
  - [ ] Update File Inventory with actual files created/modified
  - [ ] Document any decisions that changed from original plan
  - [ ] Update `last_updated` date
  - [ ] If approach changed significantly, update Architecture section
- [ ] Update `${aiDir}/features/index.yaml`:
  - [ ] Change status: `draft` → `in-progress` → `complete` (as appropriate)
  - [ ] Add/update `note:` field for partial completion or deferred scope
- [ ] If spec changed during implementation:
  - [ ] Bump `spec_version` in spec.md
  - [ ] Update `based_on_spec_version` in tech-spec.md
- [ ] Update `dependencies.md` if new dependencies discovered

<!-- myspec:project-end -->
