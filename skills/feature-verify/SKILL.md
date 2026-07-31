---
name: feature-verify
description: >
  Use when auditing a feature's overall health — before starting work, or when
  unsure documentation matches reality. Covers spec, tech-spec, plan,
  implementation, sub-features, memories, and manifest sync.
  Keywords: feature health, feature audit, verify feature, feature drift, health check.
  Do NOT use for fixing drift (feature-spec-sync), completing features
  (feature-complete), or creating new specs (feature-spec).
allowed-tools: [Read, Grep, Glob]
---

# Feature Verify

Holistic read-only health check across all 8 feature documentation categories. Produces a diagnostic report with severity levels and routes to the correct fix skill for each issue.

**Core principle:** Diagnose, don't fix. Never modifies files.

**Announce at start:** "Running feature health check for {feature}."

## Workflow

### 1. Resolve Feature

- If argument provided: resolve to `${aiDir}/features/{argument}/`
- If argument contains `/`: treat as sub-feature path (e.g., `map-making/settings`)
- If no argument: ask user which feature to verify
- Confirm directory exists
- Read manifest entry from `${aiDir}/features/index.yaml` (or `${aiDir}/features/{parent}/index.yaml` for sub-features)
- Note: `status`, `phase`, `priority`, `depends-on`, `subfeatures`, `implementation-plan`, `note`

### 2. Check Spec

Read `${aiDir}/features/{feature}/spec.md`:

| Check | Severity | Condition |
|-------|----------|-----------|
| spec.md exists | Critical | File missing and status != planned |
| Frontmatter complete | High | Missing any of: title, status, phase, priority, spec_version, created, last_updated |
| Status valid | Medium | Status not in: draft, approved, deprecated |
| Phase matches manifest | Low | spec.md phase != index.yaml phase |

### 3. Check Tech-Spec

Read `${aiDir}/features/{feature}/tech-spec.md`:

| Check | Severity | Condition |
|-------|----------|-----------|
| tech-spec.md exists | Critical | Status is in-progress or complete but file missing |
| tech-spec.md exists | Low | Status is planned or draft but file missing |
| Frontmatter complete | High | Missing any of: title, status, based_on_spec_version, created, last_updated |
| Spec version aligned | Critical | `based_on_spec_version` != spec.md `spec_version` (same severity as feature-tech-spec-review and the report example below) |
| Status valid | Medium | Status not in: draft, approved, deprecated |

### 4. Check Plan

Scan for `${aiDir}/features/{feature}/implementation-plan.md` and `${aiDir}/features/{feature}/plans/`:

| Check | Severity | Condition |
|-------|----------|-----------|
| Plan missing | Medium | Status is in-progress, no implementation-plan.md, no archived plans in plans/ |
| Plan stale | High | implementation-plan.md exists and tech-spec.md `last_updated` is newer than plan `last_updated` |
| Orphaned plan | Medium | Status is complete but implementation-plan.md still exists (should be archived) |
| Checkbox mismatch | Medium | See heuristic below |

Checkbox-to-status heuristic (count `- [x]` vs `- [ ]` in implementation-plan.md):

| Checkbox state | Manifest status | Flag |
|----------------|-----------------|------|
| 0% done | in-progress | "no progress recorded in plan" |
| 100% done | in-progress | "plan complete — should run /feature-complete" |
| >0% done | draft | "status should be in-progress" |
| <100% done | complete | "premature completion — plan has unchecked items" |

### 5. Check Implementation

If tech-spec.md has a "File Inventory" section:
- Extract file paths matching: `(apps|packages)/[a-zA-Z0-9/_.-]+\.(ts|tsx|vue|js|jsx|prisma|graphql)`
- Use Glob to verify each path exists

| Check | Severity | Condition |
|-------|----------|-----------|
| Inventory files exist | High | Tech-spec references files that don't exist and status >= in-progress |
| Inventory files exist | Low | Tech-spec references files that don't exist and status = draft |
| Code ahead of docs | Medium | Files exist in expected directories but not listed in File Inventory |

If tech-spec.md has "Implementation Steps" with checkboxes:
- For unchecked `[ ]` items: check if described files/components exist (code ahead of docs)
- For checked `[x]` items: verify referenced files still exist (docs ahead of code)

### 6. Check Sub-Features

If manifest entry has `subfeatures: true`:
- Read `${aiDir}/features/{feature}/index.yaml`
- For each sub-feature entry, check:

| Check | Severity | Condition |
|-------|----------|-----------|
| Sub-feature dir exists | High | Listed in index.yaml but directory missing |
| Sub-feature spec exists | Medium | Directory exists but no spec.md |
| Parent complete, child not | High | Parent status=complete but any sub-feature status != complete |
| All children complete, parent not | Medium | All sub-features complete but parent status != complete |
| Orphaned sub-feature | Low | Directory exists but not listed in index.yaml |

If user requests recursive check: run Steps 2–5 for each sub-feature and append results.

### 7. Check Memories

Search memory indexes for references to this feature name:
- Read `${aiDir}/memory/procedural/index.md`
- Read `${aiDir}/memory/semantic/index.md`
- Read `${aiDir}/memory/episodic/index.md`

If memories reference this feature: list under "Memories Found" (Info severity — always informational, never a warning).
If no memories found and no memory indexes exist: skip this section silently (per Edge Cases).

### 8. Check Index Sync

| Check | Severity | Condition |
|-------|----------|-----------|
| Status matches reality | High | Manifest=complete but unchecked plan items exist, or manifest=draft but implementation files present |
| Dependencies exist | Medium | `depends-on` lists a feature not found in any index.yaml |
| Dependencies ready | Low | `depends-on` lists a feature with status=planned |
| implementation-plan field | Low | Manifest `implementation-plan:` points to a file that doesn't exist |
| subfeatures field | Medium | Manifest `subfeatures: true` but no `${aiDir}/features/{feature}/index.yaml` |

### 9. Check Workflow Phase Appropriateness

Verify the right documents exist for the current manifest status:

This matrix mirrors the authoritative one in `lib/features-status-audit/audit.mjs` (EXPECTATIONS) — keep them in sync:

| Status | Required | Expected | Flag If |
|--------|----------|----------|---------|
| planned | index.yaml entry | — | tech-spec.md or implementation-plan.md exists (ahead of status; spec.md alone is fine) |
| draft | spec.md | dependencies.md | implementation-plan.md exists (ahead of status) |
| in-progress | spec.md | tech-spec.md, dependencies.md | No tech-spec (Medium — likely skipped workflow step) |
| complete | spec.md, tech-spec.md | CHANGELOG.md, archived plans in plans/ | Active implementation-plan.md (should be archived) |
| deprecated | — | — | — |

### 10. Present Health Report

```
Feature Health Report: {feature}
==================================
Status: {status} | Phase: {phase} | Priority: {priority}

Category           | Result | Issues
-------------------|--------|-------
Spec               | OK / WARN / FAIL | N
Tech-Spec          | OK / WARN / FAIL | N
Plan               | OK / WARN / FAIL | N
Implementation     | OK / WARN / FAIL | N
Sub-Features       | OK / WARN / FAIL / N/A | N
Memories           | INFO   | N found
Index Sync         | OK / WARN / FAIL | N
Workflow Phase     | OK / WARN / FAIL | N

Issues (N total):
| # | Severity | Category | Issue | Fix |
|---|----------|----------|-------|-----|
| 1 | Critical  | Tech-Spec | based_on_spec_version=2 but spec_version=3 | /feature-spec-sync |
| 2 | High      | Plan      | implementation-plan.md stale (tech-spec newer) | /feature-plan |

Memories Found:
- [memory reference] (type)

Overall: HEALTHY / NEEDS ATTENTION / UNHEALTHY
```

Health classification:
- HEALTHY: 0 Critical, 0 High issues
- NEEDS ATTENTION: 0 Critical, 1+ High issues
- UNHEALTHY: 1+ Critical issues

### 11. Recommend Actions

List numbered recommendations. Each issue type maps to one fix skill:

| Issue | Recommended Skill |
|-------|------------------|
| Spec version mismatch | `/myspec:feature-spec-sync` |
| File inventory drift | `/myspec:feature-spec-sync` |
| Checkbox drift | `/myspec:feature-spec-sync` |
| Missing spec.md | `/myspec:feature-spec` |
| Missing tech-spec.md | `/myspec:feature-tech-spec` |
| Stale or missing plan | `/myspec:feature-plan` |
| All checkboxes done, status != complete | `/myspec:feature-complete` |
| Spec needs changes for new requirements | `/myspec:feature-update` |
| Sub-feature status inconsistency | `/myspec:feature-verify {subfeature}` |
| Relevant memories found | `/myspec:memory-lookup` |

Wait for user to choose which action to pursue.

## Rules

- Never modify any files. Read-only.
- Present full report before recommending actions.
- Severity levels are fixed: Critical > High > Medium > Low > Info. Do not downgrade.
- Check file existence with Glob, not filesystem assumptions.
- Memory check is always Info — never a warning or failure.
- Category with 0 issues → OK. 1+ Low/Medium → WARN. 1+ High/Critical → FAIL.

## Edge Cases

- **Feature with no docs**: Report all categories as FAIL, recommend `/myspec:feature-spec`.
- **Sub-feature path given**: Resolve manifest from parent's index.yaml, not main index.yaml.
- **Status=deprecated**: Skip implementation checks, only verify docs exist for reference.
- **Feature not in any index.yaml**: Flag as Critical — "directory exists but not registered in manifest".
- **No memory indexes found**: Skip Step 7 silently.

## Verification Checklist

- [ ] Feature path resolved and directory confirmed to exist
- [ ] Manifest entry found and read
- [ ] spec.md checked: existence, frontmatter, status validity
- [ ] tech-spec.md checked: existence, frontmatter, version alignment
- [ ] Plan checked: existence, currency, checkpoint progress
- [ ] File inventory checked against filesystem (if File Inventory section exists)
- [ ] Sub-features checked (if subfeatures: true)
- [ ] Memory indexes scanned for feature references
- [ ] Index.yaml sync validated
- [ ] Workflow phase appropriateness validated
- [ ] Health report output with severity-grouped issues table
- [ ] Recommended actions listed with specific skill references
- [ ] No files were modified during the check

## Integration

**Call before** [OPTIONAL]: `/myspec:feature-plan`, `/myspec:feature-implement`, `/myspec:feature-complete` — as a health pre-flight
**Standalone:** Direct invocation for any feature audit
**Routes to** [OPTIONAL — per finding]: `/myspec:feature-spec-sync`, `/myspec:feature-spec`, `/myspec:feature-tech-spec`, `/myspec:feature-plan`, `/myspec:feature-update`, `/myspec:feature-complete`, `/myspec:memory-lookup`
