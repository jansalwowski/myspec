---
title: "Feature Decompose Templates"
purpose: "Full templates for sub-feature files"
load_when: "using feature-decompose skill and creating sub-feature files"
updated: 2025-01-19
---

# Feature Decompose Templates

Full templates for creating sub-feature files during feature decomposition.

## Sub-Feature spec.md Template

Frontmatter, sections, requirement IDs and acceptance-criteria format are the ones in [`_shared/spec-template.md`](../../_shared/spec-template.md#specmd), which `feature-spec-review` checks against. Fill each section with what moves from the parent spec. On top of the template:

- `title: "{Parent} -- {SubFeature Title}"`, `status:` `draft`, `approved` or `deprecated` (never `in-progress`, a manifest-only status), and `see_also: [../spec.md]` in the frontmatter
- `> Sub-feature of [{Parent}](../spec.md)` under the `# {SubFeature Title}` heading

## Sub-Feature dependencies.md Template

Frontmatter and headings are the ones in [`_shared/spec-template.md`](../../_shared/spec-template.md#dependenciesmd), with `title: "{Parent} {SubFeature} -- Dependencies"` and the `> Sub-feature of [{Parent}](../spec.md)` line. Fill them from the parent:

- **Feature Dependencies**: the parent `{parent}` first, then the sibling sub-features and other features this one needs
- **Dependent Features**: the features and sub-features that depend on this one
- **External Dependencies**: the parent's external dependencies that this sub-feature uses

## Sub-Feature tech-spec.md Template

**Only create for `complete` or `in-progress` sub-features.**

```yaml
---
title: "{Parent} {SubFeature} -- Technical Specification"
status: draft | approved | deprecated
based_on_spec_version: 1
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
load_when: "implementing {parent} {sub-feature}"
see_also:
  - ./spec.md
  - ../tech-spec.md
---

# {SubFeature} -- Technical Specification

> Sub-feature of [{Parent}](../spec.md)

## Architecture

[Extracted architecture details specific to this sub-feature]

## Implementation Steps

1. [Extracted steps from parent tech-spec, renumbered, no checkboxes]

## Key Interfaces

[Extracted interfaces/types for this sub-feature]

## File Inventory

### New Files
- [Files created for this sub-feature]

### Modified Files
- [Files modified for this sub-feature]

## Decisions

[Extracted decisions relevant to this sub-feature]

## Edge Cases

[Extracted edge cases for this sub-feature]
```

## Sub-Feature scenarios.md Template

**Only create if parent feature has scenarios.md.**

```yaml
---
title: "{Parent} {SubFeature} -- Test Scenarios"
purpose: "Gherkin test scenarios"
load_when: "writing tests for {parent} {sub-feature}"
updated: YYYY-MM-DD
see_also:
  - ./spec.md
  - ../scenarios.md
---

# {SubFeature} Test Scenarios

> Sub-feature of [{Parent}](../spec.md)

[Extracted scenarios from parent scenarios.md that apply to this sub-feature]
```

## Parent File Update Patterns

### Parent spec.md Updates

Add this section after Overview:

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

Remove sections moved to sub-features. Keep only cross-cutting concerns. Do not change the parent spec.md's `status:` — `in-progress` is a manifest-only status (see SKILL.md Step 4).

### Parent dependencies.md Updates

Add this section:

```markdown
## Sub-Features

This feature is decomposed into:

- **{sub-feature-1}**: [Description] → [dependencies.md](./{sub1}/dependencies.md)
- **{sub-feature-2}**: [Description] → [dependencies.md](./{sub2}/dependencies.md)

Dependencies for each sub-feature are tracked separately.
```

### Parent tech-spec.md Updates

Add this section after Architecture:

```markdown
## Sub-Feature Mapping

| Sub-Feature | Implementation Files | Status |
|-------------|---------------------|---------|
| [{SubFeature 1}](./{sub1}/tech-spec.md) | [Key files] | Complete |
| [{SubFeature 2}](./{sub2}/spec.md) | [Key files] | Draft |

See individual sub-feature tech-specs for implementation details.
```

Remove implementation details moved to sub-features. Keep only cross-cutting implementation concerns.

### Parent scenarios.md Updates

Add note at top:

```markdown
> This feature is decomposed into sub-features. See individual sub-feature scenario files for specific tests.

## Cross-Cutting Scenarios

[Keep only scenarios that span multiple sub-features]

## Sub-Feature Scenarios

- [{SubFeature 1}](./{sub1}/scenarios.md)
- [{SubFeature 2}](./{sub2}/scenarios.md)
```

## Feature-Level index.yaml Template

Create `${aiDir}/features/{feature}/index.yaml`:

```yaml
# Sub-feature manifest for {Feature Title}

sub-features:
  - name: {feature}/{sub-feature-1}
    title: "Sub-Feature 1 Title"
    status: complete
    phase: 1
    priority: P1
    depends-on: [{feature}]
    note: "Optional context about this sub-feature"

  - name: {feature}/{sub-feature-2}
    title: "Sub-Feature 2 Title"
    status: draft
    phase: 1
    priority: P2
    depends-on: [{feature}, {feature}/{sub-feature-1}]
    note: "Another optional note"
```

**Rules:**
- Each sub-feature depends on parent feature at minimum
- Sub-features can depend on other sub-features
- Include `note` field for important context

**Update main index.yaml:**
After creating feature-level index.yaml, add `subfeatures: true` to parent feature entry in main `${aiDir}/features/index.yaml`.

## Decomposition Summary

Shown to the user by SKILL.md Step 8:

```markdown
## Decomposition Complete

### Created Sub-Features

1. **{sub-feature-1}** ({status})
   - Files: spec.md, dependencies.md[, tech-spec.md]
   - Priority: {P0|P1|P2|P3}

2. **{sub-feature-2}** ({status})
   - Files: spec.md, dependencies.md[, tech-spec.md]
   - Priority: {P0|P1|P2|P3}

### Updated Files

- ✅ {feature}/spec.md - Added sub-features table, removed moved content
- ✅ {feature}/dependencies.md - Added sub-features section
- ✅ {feature}/tech-spec.md - Added sub-feature mapping
- ✅ ${aiDir}/features/{feature}/index.yaml - Created with the sub-features list
- ✅ ${aiDir}/features/index.yaml - Added `subfeatures: true` to the parent entry

### Verification

- ✅ All sub-features have required files
- ✅ No duplicate content
- ✅ All links work
- ✅ audit.mjs and dead-paths.mjs report nothing the decomposition caused

### Next Steps

1. Review sub-feature specs for accuracy
2. Adjust priorities if needed
3. Begin implementation with highest priority sub-feature
```
