---
name: "feature-decompose"
description: "Use when one feature has grown to cover several distinct capabilities and should be split into sub-features. Keywords: decompose, split feature, break down, modularize. Do NOT use for new or single-capability features."
tags: [feature, decompose, split, subfeatures, refactoring, modular]
---

# Feature Decomposition Skill

Splits a monolithic feature into modular sub-features, each a peer directory under the parent with its own docs.

## Prerequisites

Check these before starting:
- Feature exists in `${aiDir}/features/{feature}/`
- Feature has `spec.md` (required)
- Feature complexity justifies decomposition (multiple distinct capabilities)
- You are NOT creating a new feature (use feature-spec for new features)

## Workflow

### 1. Analyze Feature

Read using the Read tool:
- `${aiDir}/features/{feature}/spec.md` (required)
- `${aiDir}/features/{feature}/tech-spec.md` (if exists)
- `${aiDir}/features/{feature}/scenarios.md` (if exists)
- `${aiDir}/features/index.yaml`

Identify sub-features using signals in the table below.

### 2. Propose Sub-Features

Present proposed structure to user:

```markdown
## Proposed Sub-Features for {Feature}

### Sub-Feature 1: {name}
- **Status**: {complete|in-progress|draft}
- **Priority**: {P0|P1|P2|P3}
- **Description**: [1-2 sentences]
- **Content from parent**:
  - User stories: US1, US2
  - Requirements: REQ3, REQ4
  - Scenarios: S1, S5

### Sub-Feature 2: {name}
...

### Parent Feature Changes
- Remove: [sections moved to sub-features]
- Add: Sub-Features table
- Update: manifest entry gains `subfeatures: true` (spec.md `status:` unchanged)
```

**WAIT for user confirmation or modifications before proceeding.**

### 3. Create Sub-Feature Directories

For each confirmed sub-feature, create directory and files. See [templates.md](references/templates.md) for full templates:

- `${aiDir}/features/{feature}/{sub-feature}/spec.md` (always)
- `${aiDir}/features/{feature}/{sub-feature}/dependencies.md` (always)
- `${aiDir}/features/{feature}/{sub-feature}/tech-spec.md` (only if status=complete or in-progress)

### 4. Update Parent Files

Apply the patterns in [templates.md](references/templates.md) "Parent File Update Patterns":

- **spec.md**: add the Sub-Features table after Overview and remove the moved content
- **dependencies.md**: add the Sub-Features section
- **tech-spec.md** (if exists): add the Sub-Feature Mapping after Architecture

Do not change spec.md's `status:` — `in-progress` is a manifest-only status; spec frontmatter allows `draft | approved | deprecated`. Decomposition progress lives in the sub-feature manifest (next step).

### 5. Create Feature-Level index.yaml

Create `${aiDir}/features/{feature}/index.yaml` from [templates.md](references/templates.md) "Feature-Level index.yaml Template". Each sub-feature depends on the parent at minimum.

Then add `subfeatures: true` to the parent's entry in the main `${aiDir}/features/index.yaml`. The sub-feature list stays in the feature-level file.

### 6. Split Scenarios (if applicable)

If `scenarios.md` exists, read it, analyze which scenarios belong to which sub-feature, create sub-feature scenarios, and update parent. See [templates.md](references/templates.md) for scenarios template.

### 7. Run Verification

Decompose only moves Markdown and YAML, so check the docs, not the code:

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/feature-status-audit/audit.mjs" --only={feature}
node "${CLAUDE_PLUGIN_ROOT}/lib/feature-spec-sync/dead-paths.mjs" --only={feature}
```

The first checks the manifest entries against the files on disk, sub-features included. The second checks that every repo path the moved docs cite still resolves. Fix each finding the decomposition caused before completing.

### 8. Present Summary

Show a "Decomposition Complete" summary with four sections — Created Sub-Features (name, status, files, priority per sub-feature), Updated Files (parent spec/dependencies/tech-spec + manifest), Verification (checks that passed), Next Steps. Full template: [templates.md](references/templates.md) "Decomposition Summary".

## Quick Reference

### Sub-Feature Signals

| Signal | Indication |
|--------|-----------|
| "Phase 2" sections | Separate phase = sub-feature |
| "Out of Scope" items | Future sub-features |
| "Deferred" implementation | Draft sub-feature |
| Multiple data models | Each model = potential sub-feature |
| Distinct API endpoint groups | Endpoint groups = sub-features |
| "Optional" functionality | Soft-dependency sub-feature |
| Separate user story groups | Different capabilities |
| Different implementation statuses | Mixed completion levels |

### File Requirements by Status

| Status | Required | Optional |
|--------|----------|----------|
| `draft` | spec.md, dependencies.md | - |
| `in-progress` | spec.md, dependencies.md, tech-spec.md | scenarios.md |
| `complete` | spec.md, dependencies.md, tech-spec.md | scenarios.md |

### Directory Structure

Sub-features are **peer directories** under parent:

```
${aiDir}/features/{feature}/
├── spec.md                    # Streamlined, links to sub-features
├── dependencies.md            # Adds sub-features section
├── tech-spec.md               # Adds sub-feature mapping
├── scenarios.md               # May be split
├── {sub-feature-1}/           # Sub-feature directory
│   ├── spec.md
│   ├── tech-spec.md           # Only if implemented
│   ├── dependencies.md
│   └── scenarios.md           # If parent had scenarios
├── {sub-feature-2}/
│   ├── spec.md
│   └── dependencies.md
...
```

### Common Pitfalls

| Issue | Solution |
|-------|----------|
| Duplicate content | Parent should keep only cross-cutting concerns |
| Missing dependencies | Each sub-feature must depend on parent at minimum |
| Wrong status | Only set `complete` if fully implemented with tests |
| Creating tech-spec for draft | Draft sub-features should NOT have tech-spec.md |
| Broken links | Always use relative paths: `./sub/spec.md` not `sub/spec.md` |
| Forgetting index.yaml | Sub-features MUST be added to index.yaml |

## Verification Checklist

After decomposition:

- [ ] All sub-features have spec.md + dependencies.md
- [ ] Complete/in-progress sub-features have tech-spec.md
- [ ] Parent spec.md has Sub-Features table
- [ ] Parent dependencies.md has Sub-Features section
- [ ] Parent tech-spec.md has Sub-Feature Mapping (if tech-spec exists)
- [ ] Feature-level index.yaml created at `${aiDir}/features/{feature}/index.yaml`
- [ ] `subfeatures: true` added to parent feature in main `${aiDir}/features/index.yaml`
- [ ] No duplicate content between parent and sub-features
- [ ] All links between files work
- [ ] `audit.mjs --only={feature}` and `dead-paths.mjs --only={feature}` report nothing the decomposition caused
- [ ] Scenarios split appropriately (if scenarios.md existed)
- [ ] Parent manifest entry has `subfeatures: true`; spec.md `status:` left unchanged
- [ ] Sub-feature dependencies properly set in feature-level index.yaml
