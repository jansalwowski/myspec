---
name: "feature-decompose"
description: "Use when splitting a large feature into sub-features. Keywords: decompose, split feature, break down, modularize, sub-features. Analyzes spec.md/tech-spec.md, identifies distinct capabilities, creates sub-feature directories. Requires existing feature with spec.md. Example use: '/feature-decompose search' to split search into core, filters, trending. Do NOT use for new features, single-capability features, or initial feature creation."
tags: [feature, decompose, split, subfeatures, refactoring, modular]
---

# Feature Decomposition Skill

Splits a monolithic feature into modular sub-features following the browser-extension pattern.

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
- **Priority**: {P1|P2|P3}
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
- Update: Status to in-progress
```

**WAIT for user confirmation or modifications before proceeding.**

### 3. Create Sub-Feature Directories

For each confirmed sub-feature, create directory and files. See [templates.md](references/templates.md) for full templates:

- `${aiDir}/features/{feature}/{sub-feature}/spec.md` (always)
- `${aiDir}/features/{feature}/{sub-feature}/dependencies.md` (always)
- `${aiDir}/features/{feature}/{sub-feature}/tech-spec.md` (only if status=complete or in-progress)

### 4. Update Parent Files

**spec.md** - Add Sub-Features table after Overview, remove moved content:

```markdown
## Sub-Features

This feature is split into modular sub-features:

| Feature | Phase | Status | Description | Priority |
|---------|-------|--------|-------------|----------|
| [{SubFeature 1}](./{sub1}/spec.md) | 1 | ✅ Complete | [Description] | P1 |
| [{SubFeature 2}](./{sub2}/spec.md) | 2 | 🔄 In Progress | [Description] | P1 |
| [{SubFeature 3}](./{sub3}/spec.md) | 2 | ⬜ Draft | [Description] | P2 |

See individual sub-feature specs for details.
```

**dependencies.md** - Add Sub-Features section:

```markdown
## Sub-Features

This feature is decomposed into:

- **{sub-feature-1}**: [Description] → [dependencies.md](./{sub1}/dependencies.md)
- **{sub-feature-2}**: [Description] → [dependencies.md](./{sub2}/dependencies.md)

Dependencies for each sub-feature are tracked separately.
```

**tech-spec.md** (if exists) - Add Sub-Feature Mapping after Architecture:

```markdown
## Sub-Feature Mapping

| Sub-Feature | Implementation Files | Status |
|-------------|---------------------|---------|
| [{SubFeature 1}](./{sub1}/tech-spec.md) | [Key files] | Complete |
| [{SubFeature 2}](./{sub2}/spec.md) | [Key files] | Draft |

See individual sub-feature tech-specs for implementation details.
```

Update status in spec.md frontmatter to `in-progress` if was `draft`.

### 5. Create Feature-Level index.yaml

Create `${aiDir}/features/{feature}/index.yaml` with sub-features array:

```yaml
# Sub-feature manifest for {Feature Title}

sub-features:
  - name: {feature}/{sub-feature-1}
    title: "Sub-Feature 1 Title"
    status: complete
    phase: 1
    priority: P1
    depends-on: [{feature}]
    note: "Optional context"

  - name: {feature}/{sub-feature-2}
    title: "Sub-Feature 2 Title"
    status: draft
    phase: 1
    priority: P2
    depends-on: [{feature}, {feature}/{sub-feature-1}]
```

**Rules:**
- Each sub-feature depends on parent feature at minimum
- Sub-features can depend on other sub-features
- Include `note` field for important context

**Update main index.yaml:**
After creating feature-level index.yaml, add `subfeatures: true` to parent feature entry in main `${aiDir}/features/index.yaml`.

### 6. Split Scenarios (if applicable)

If `scenarios.md` exists, read it, analyze which scenarios belong to which sub-feature, create sub-feature scenarios, and update parent. See [templates.md](references/templates.md) for scenarios template.

### 7. Run Verification

Run verification checks from `.claude/verification.json`. Fix any issues before completing.

### 8. Present Summary

Show user:

```markdown
## Decomposition Complete

### Created Sub-Features

1. **{sub-feature-1}** ({status})
   - Files: spec.md, dependencies.md[, tech-spec.md]
   - Priority: {P1|P2|P3}

2. **{sub-feature-2}** ({status})
   - Files: spec.md, dependencies.md[, tech-spec.md]
   - Priority: {P1|P2|P3}

### Updated Files

- ✅ {feature}/spec.md - Added sub-features table, removed moved content
- ✅ {feature}/dependencies.md - Added sub-features section
- ✅ {feature}/tech-spec.md - Added sub-feature mapping
- ✅ ${aiDir}/features/index.yaml - Added sub-features array

### Verification

- ✅ All sub-features have required files
- ✅ No duplicate content
- ✅ All links work
- ✅ Verification checks pass

### Next Steps

1. Review sub-feature specs for accuracy
2. Adjust priorities if needed
3. Begin implementation with highest priority sub-feature
```

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
- [ ] Verification checks from `.claude/verification.json` pass — no errors
- [ ] Scenarios split appropriately (if scenarios.md existed)
- [ ] Parent status updated to in-progress (if was draft)
- [ ] Sub-feature dependencies properly set in feature-level index.yaml
