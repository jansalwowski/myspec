---
name: "feature-spec-sync"
description: "Use when feature docs have drifted from code — after refactoring, or before completing a feature. Handles spec.md and tech-spec.md drift, dead repo paths in any feature doc (--paths), version mismatches. Do NOT use for the project topology file (backbone-sync) or the feature manifest (feature-status-audit)."
tags: [documentation, maintenance, verification, sync]
---

# Spec Sync

Detect and fix discrepancies between feature documentation (spec.md, tech-spec.md) and actual code. Interactive workflow with user confirmation for all changes.

**Paths mode** (`--paths`, or the user asks only about dead or stale paths): run check A without `--only` to sweep every feature, then steps 3-7 on its findings. Skip B-D and the prerequisites.

## Prerequisites

- Feature must exist in `${aiDir}/features/{feature}/`
- Feature must have `tech-spec.md`

## Workflow

### 1. Load Context

Read the target feature's documentation:
- Read `${aiDir}/features/{feature}/spec.md`
- Read `${aiDir}/features/{feature}/tech-spec.md`
- Read `${aiDir}/features/index.yaml` (or `${aiDir}/features/{parent}/index.yaml` for sub-features)

### 2. Detect Discrepancies

Scan for four types of issues:

**A. Dead Paths**

From the project root:

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/feature-spec-sync/dead-paths.mjs" --only={feature}
```

It checks every backticked repo path in the feature's live docs (spec.md, tech-spec.md, index.yaml, scenarios.md, seed.json, sub-features included) and prints `MISSING` or `MOVED <old> -> <new>` with doc:line. It skips plans/, CHANGELOG.md, placeholders, globs, URLs, fenced code and rename/history tables. Exit 0 clean, 1 findings, 3 cannot run. `--prefix=a,b` also checks extension-less paths under top-level dirs that were deleted outright; `--json` for machine output.

- Drop MISSING paths the tech-spec lists as still to be created in an unimplemented feature — planned, not drift.
- For MISSING with no candidate, Glob for near names (`guide.ts` → `guides.ts`) before offering removal.

**B. Spec Version Alignment**

Compare frontmatter fields:
- `spec.md` → `spec_version` field
- `tech-spec.md` → `based_on_spec_version` field
- Detect: MISMATCH (values differ), MISSING (field absent)

**C. Implementation Checkboxes**

Only when tech-spec.md still carries checkbox lists (the template's Implementation Steps is a numbered outline without them; `feature-complete` compacts old ones away):
- Find all checkboxes: `- \[([ x])\] (.+)`
- For unchecked items `[ ]`, check if described files exist
- For checked items `[x]`, verify files still exist
- Categorize: SHOULD_BE_CHECKED (files exist but unchecked), SHOULD_BE_UNCHECKED (checked but files missing)

**D. Feature Status Validation**

Completion % is computed from **implementation-plan.md checkboxes**, the canonical source per `.claude/rules/workflow.md` — never from tech-spec.md checkboxes or code inspection:
- Count total tasks, count checked tasks
- Calculate completion % = checked / total * 100
- Compare to `status` field in index.yaml
- Detect: MISMATCH if status doesn't match completion (e.g., status=complete but <100%, status=draft but >80%)
- No `implementation-plan.md`: nothing to count. `in-progress` needs a live plan, so that pair is a MISMATCH; for any other status the missing plan is informational, as in `feature-status-audit`'s matrix (authoritative per `workflow.md`): `complete` requires only spec.md and tech-spec.md, and `plans/` or `CHANGELOG.md` are never required

### 3. Present Findings

Show table with all discrepancies:

```
Discrepancies Found in {feature}
================================

| # | Type | Severity | Location | Description | Status |
|---|------|----------|----------|-------------|--------|
| 1 | File Path | High | tech-spec.md:145 | apps/api/src/services/guide.ts | MISSING |
| 2 | File Path | Medium | tech-spec.md:146 | apps/api/src/services/guides.ts | MOVED (guide.ts → guides.ts) |
| 3 | Spec Version | High | Frontmatter | spec_version=3 vs based_on_spec_version=2 | MISMATCH |
| 4 | Checkbox | Medium | tech-spec.md:89 | "Create GuideService" (file exists) | SHOULD_BE_CHECKED |
| 5 | Feature Status | Medium | index.yaml | 12/15 steps (80%) but status=draft | MISMATCH |
```

**Severity Levels**:
- **High**: Spec version mismatch, file paths that are completely missing
- **Medium**: Files that moved, checkboxes out of sync, status mismatch
- **Low**: Minor inconsistencies

### 4. Ask User for Action

Present options: review specific item, fix all (interactive), fix by type, or exit.

Wait for user selection.

### 5. Interactive Fix Workflow

For each discrepancy, present:
- Location and current state
- Similar files found (for MISSING paths)
- Resolution options (update, remove, skip)

Always include "skip" option. For file paths with fuzzy matches, list alternatives.

### 6. Execute Changes

For each user-approved change:
- Show exact edit being made (old → new)
- Execute using Edit tool
- Confirm: "✓ Updated {file}:{line}"

**Non-destructive Rule**: Never auto-delete content. Always present options and wait for confirmation.

### 7. Summary Report

After all fixes, summarize: changes made, items skipped, files modified.

## Detection Patterns Reference

Use these for scanning:

**Implementation checkboxes:**
```regex
- \[([ x])\] (.+)
```

**YAML frontmatter fields:**
```regex
^spec_version: (\d+)
^based_on_spec_version: (\d+)
```

## Verification Checklist

After running spec-sync:

- [ ] `dead-paths.mjs` exits 0, or every remaining finding was triaged with the user
- [ ] `spec_version` matches `based_on_spec_version`
- [ ] Implementation checkboxes reflect actual code state
- [ ] Feature status in index.yaml matches completion %
- [ ] No edits made without user confirmation
- [ ] Summary report lists all changes and skips

## Rules

- Work on one feature at a time for manageable output
- Always present findings before making changes
- Never auto-fix without user approval
- Fuzzy matching helps catch file renames (guide.ts → guides.ts, singular → plural)
- High-severity issues should be fixed first
- Status suggestions must respect transition ownership (see the Status State Machine in `.claude/rules/workflow.md`): `in-progress` is set by `/myspec:feature-implement` at execution start, so any completion % is normal for it — suggest `draft` only when no implementation plan exists yet. Never suggest `complete` from checkbox counts — that transition belongs to `/myspec:feature-complete`; at ≥80% suggest running `/myspec:feature-verify` instead
