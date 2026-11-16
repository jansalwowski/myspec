---
name: feature-verify
description: "Use when one feature's health needs auditing — spec, tech-spec, plan, implementation, sub-features, memories, manifest sync. Keywords: feature health, verify feature, feature drift. Do NOT use to audit every feature (feature-status-audit)."
allowed-tools: [Read, Grep, Glob, Bash]
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

Then run the two scripts once, from the project root, with `{feature}` as given (a sub-feature as `parent/sub`):

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/feature-status-audit/audit.mjs" --only={feature} --json
node "${CLAUDE_PLUGIN_ROOT}/lib/feature-spec-sync/dead-paths.mjs" --only={feature}
```

`audit.mjs` owns status drift, required and expected docs per status, doc status vocabulary, archived plans and parent acceptance criteria. For a top-level feature its `results` hold the feature and its sub-features; for a sub-feature, that one result. It exits 0 clean, 2 when any result has a Critical issue, 3 when it cannot run (a name in no manifest included). `dead-paths.mjs` lists `MISSING` and `MOVED` paths cited in the feature's docs and its sub-features' docs; it exits 0 clean, 1 with findings, 3 when it cannot run. If a script exits 3, report its error and show the categories it feeds as `NOT RUN`. Do not redo its checks by hand.

Report every `audit.mjs` issue with the script's severity. Do not check those conditions again by hand. An issue on a sub-feature's result goes to Sub-Features. Put each issue on `{feature}`'s own result in a category:

| Script message | Category |
|----------------|----------|
| `directory missing`, `required doc missing`, `expected doc missing`, `present but status=` (docs ahead), `draft with no documentation files` | Workflow Phase |
| `frontmatter status: X is not a doc status` | Spec or Tech-Spec |
| `implementation-plan.md is ...`, `implementation-plan.md still present`, `archived plans/...` | Plan |
| `unknown status: "X"`, `frontmatter status: draft but manifest status=complete` | Index Sync |
| `subfeatures: true but no index.yaml`, `all N sub-features complete but spec.md acceptance criteria ...` | Sub-Features |

### 2. Check Spec

Read `${aiDir}/features/{feature}/spec.md`:

| Check | Severity | Condition |
|-------|----------|-----------|
| Frontmatter complete | High | Missing any of: title, status, phase, priority, spec_version, created, last_updated |
| Phase matches manifest | Low | spec.md phase != index.yaml phase |

### 3. Check Tech-Spec

Read `${aiDir}/features/{feature}/tech-spec.md`:

| Check | Severity | Condition |
|-------|----------|-----------|
| Frontmatter complete | High | Missing any of: title, status, based_on_spec_version, created, last_updated |
| Spec version aligned | Critical | `based_on_spec_version` != spec.md `spec_version` (same severity as feature-tech-spec-review and the report example below) |

A missing spec.md or tech-spec.md and an invalid doc status come from `audit.mjs` (Step 1).

### 4. Check Plan

Scan for `${aiDir}/features/{feature}/implementation-plan.md` and `${aiDir}/features/{feature}/plans/`:

| Check | Severity | Condition |
|-------|----------|-----------|
| Plan missing | Medium | Status is in-progress, no implementation-plan.md, no archived plans in plans/ |
| Plan stale | High | implementation-plan.md exists and tech-spec.md `last_updated` is newer than plan `last_updated` |

Use `docs.implementationPlan` and `docs.archivedPlans` from the `audit.mjs` JSON for the Plan missing check. Plan ratio drift, an active plan under `complete` and archived plans at 0/N come from `audit.mjs` (Step 1). Do not count checkboxes by hand.

### 5. Check Implementation

Dead paths come from `dead-paths.mjs` (Step 1). Drop a `MISSING` path that the tech-spec lists as still to be created in a feature that is not yet implemented. A finding in a sub-feature's directory goes to Sub-Features, once.

| Check | Severity | Condition |
|-------|----------|-----------|
| Cited path missing | High | `dead-paths.mjs` reports `MISSING` (same severity as `feature-spec-sync`) |
| Cited path moved | Medium | `dead-paths.mjs` reports `MOVED` (same severity as `feature-spec-sync`) |
| Code ahead of docs | Medium | Files exist in expected directories but not listed in File Inventory |

If tech-spec.md has checkbox task lists (the template uses a numbered outline without checkboxes):
- Low finding: task log in tech-spec.md; the `feature-complete` compaction step removes it
- For unchecked `[ ]` items: check if described files/components exist (code ahead of docs)
- For checked `[x]` items: verify referenced files still exist (docs ahead of code)

### 6. Check Sub-Features

If manifest entry has `subfeatures: true`:
- Read `${aiDir}/features/{feature}/index.yaml`
- For each sub-feature entry, check:

| Check | Severity | Condition |
|-------|----------|-----------|
| Parent complete, child not | High | Parent status=complete but any sub-feature status != complete |
| All children complete, parent not | Medium | All sub-features complete but parent status != complete |
| Orphaned sub-feature | Low | Directory exists but not listed in index.yaml |

A missing sub-feature directory or spec.md, a missing sub-feature index.yaml and open parent acceptance criteria come from `audit.mjs` (Step 1).

If user requests recursive check: run Steps 2–5 for each sub-feature and append results. Its `audit.mjs` issues and dead paths are already in Sub-Features from Step 1: do not report them again.

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
| Dependencies exist | Medium | `depends-on` lists a feature not found in any index.yaml |
| Dependencies ready | Low | `depends-on` lists a feature with status=planned |
| implementation-plan field | Low | Manifest `implementation-plan:` points to a file that doesn't exist |
| Status behind code | High | Manifest status is planned or draft but the code the docs describe exists |

Status drift (plan ratio against manifest status) and `subfeatures: true` without an index.yaml come from `audit.mjs` (Step 1).

### 9. Check Workflow Phase Appropriateness

The `audit.mjs` issues in the Workflow Phase category (Step 1) are this check. Its matrix of required and expected docs per status is the one in `/myspec:feature-status-audit`. Add nothing by hand.

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

List numbered recommendations. Each issue type maps to one fix skill. For an `audit.mjs` issue, use the fix in `/myspec:feature-status-audit`'s routing table (its Step 3). For the other issues:

| Issue | Recommended Skill |
|-------|------------------|
| Spec version mismatch | `/myspec:feature-spec-sync` |
| Dead or moved path | `/myspec:feature-spec-sync` |
| Tech-spec checkbox drift | `/myspec:feature-spec-sync` |
| Stale or missing plan | `/myspec:feature-plan` |
| Status behind code | Confirm in git what merged, then `/myspec:feature-complete` if it shipped, or `/myspec:feature-plan` for the rest |
| Spec needs changes for new requirements | `/myspec:feature-update` |
| Sub-feature status inconsistency | `/myspec:feature-verify {subfeature}` |
| Relevant memories found | `/myspec:memory-lookup` |

Wait for user to choose which action to pursue.

## Rules

- Never modify any files. Read-only.
- Present full report before recommending actions.
- Severity levels are fixed: Critical > High > Medium > Low > Info. Do not downgrade.
- Check file existence with Glob, not filesystem assumptions. Conditions the two scripts check are taken from their output, not checked again.
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
- [ ] `audit.mjs --json` and `dead-paths.mjs` run once, each issue reported with the script's severity
- [ ] spec.md checked: frontmatter, phase
- [ ] tech-spec.md checked: frontmatter, version alignment
- [ ] Plan checked: existence, currency
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
