---
name: "feature-spec-sync"
description: >
  Use when documentation seems outdated, after refactoring, or before feature completion.
  Handles spec.md / tech-spec.md drift, stale file paths, and version mismatches.
  Do NOT use for creating new specs or mid-implementation.
tags: [documentation, maintenance, verification, sync]
---

# Spec Sync

Detect and fix discrepancies between feature documentation (spec.md, tech-spec.md) and actual code. Interactive workflow with user confirmation for all changes.

## Prerequisites

- Feature must exist in `${aiDir}/features/{feature}/`
- Feature must have `tech-spec.md`

## Instructions

### 1. Load Context

Read the target feature's documentation:
- Read `${aiDir}/features/{feature}/spec.md`
- Read `${aiDir}/features/{feature}/tech-spec.md`
- Read `${aiDir}/features/index.yaml` (or `${aiDir}/features/{parent}/index.yaml` for sub-features)

### 2. Detect Discrepancies

Scan for four types of issues:

**A. File Path Validation**

From tech-spec.md "File Inventory" section:
- Extract all file paths from the File Inventory section (adapt the regex below to the project's directory structure)
- Use Glob to verify each path exists
- For missing files, use fuzzy matching to find similar paths (e.g., `guide.ts` → `guides.ts`)
- Categorize: EXISTS, MISSING, MOVED (similar file found)

**B. Spec Version Alignment**

Compare frontmatter fields:
- `spec.md` → `spec_version` field
- `tech-spec.md` → `based_on_spec_version` field
- Detect: MISMATCH (values differ), MISSING (field absent)

**C. Implementation Checkboxes**

From tech-spec.md "Implementation Steps":
- Find all checkboxes: `- \[([ x])\] (.+)`
- For unchecked items `[ ]`, check if described files exist
- For checked items `[x]`, verify files still exist
- Categorize: SHOULD_BE_CHECKED (files exist but unchecked), SHOULD_BE_UNCHECKED (checked but files missing)

**D. Feature Status Validation**

From index.yaml and tech-spec.md:
- Count total implementation steps
- Count checked steps
- Calculate completion % = checked / total * 100
- Compare to `status` field in index.yaml
- Detect: MISMATCH if status doesn't match completion (e.g., status=complete but <100%, status=draft but >80%)

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

**File paths in tech-spec.md** (adapt to project structure):
```regex
(src|apps|packages|lib)/[a-zA-Z0-9/_-]+\.(ts|tsx|vue|js|jsx|py|rb|go|prisma|graphql)
```

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

- [ ] All file paths in tech-spec.md exist (verify with Glob)
- [ ] `spec_version` matches `based_on_spec_version`
- [ ] Implementation checkboxes reflect actual code state
- [ ] Feature status in index.yaml matches completion %
- [ ] No edits made without user confirmation
- [ ] Summary report lists all changes and skips

## Notes

- Work on one feature at a time for manageable output
- Always present findings before making changes
- Never auto-fix without user approval
- Fuzzy matching helps catch file renames (guide.ts → guides.ts, singular → plural)
- High-severity issues should be fixed first
- Status suggestions based on completion: <30% = draft, 30-80% = in-progress, >80% = complete or needs review
