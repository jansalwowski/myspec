---
title: "Feature Decompose Templates"
purpose: "Full templates for sub-feature files"
load_when: "using feature-decompose skill and creating sub-feature files"
---

# Feature Decompose Templates

Full templates for creating sub-feature files during feature decomposition.

All paths use `${aiDir}` — resolve from `.myspec.json` before use.

## Sub-Feature spec.md Template

```yaml
---
title: "{Parent} -- {SubFeature Title}"
status: draft | in-progress | complete
phase: 1 | 2 | 3
priority: P1 | P2 | P3
spec_version: 1
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
load_when: "implementing {parent} {sub-feature} functionality"
see_also:
  - ../spec.md
---

# {SubFeature Title}

> Sub-feature of [{Parent}](../spec.md)

## Overview

[2-3 sentence summary extracted from parent]

## Goals

- [Extracted goals specific to this sub-feature]

## Requirements

[Extracted requirements from parent spec]

## Acceptance Criteria

[Extracted criteria from parent spec]

## Dependencies

See [dependencies.md](./dependencies.md)

## Out of Scope

[Items not covered by this sub-feature]
```

## Sub-Feature dependencies.md Template

```yaml
---
title: "{Parent} {SubFeature} -- Dependencies"
purpose: "Cross-feature dependency tracking"
load_when: "planning {parent} {sub-feature} implementation"
updated: YYYY-MM-DD
feature: {parent}/{sub-feature}
---

# {SubFeature} Dependencies

> Sub-feature of [{Parent}](../spec.md)

## Upstream Dependencies (Required First)

- **{parent}**: Core {parent} feature must exist
- [Other dependencies extracted from parent]

## Downstream Dependents (Depends on This)

- [Features that depend on this sub-feature]

## Internal Sub-Feature Dependencies

- [Other sub-features this depends on, if any]

## Technical Dependencies

[Extracted technical deps from parent dependencies.md]
```

## Sub-Feature tech-spec.md Template

**Only create for `complete` or `in-progress` sub-features.**

```yaml
---
title: "{Parent} {SubFeature} -- Technical Specification"
status: draft | in-progress | complete
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

- [ ] [Extracted steps from parent tech-spec]

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
| [{SubFeature 1}](./{sub1}/spec.md) | 1 | Complete | [Description] | P1 |
| [{SubFeature 2}](./{sub2}/spec.md) | 2 | In Progress | [Description] | P1 |
| [{SubFeature 3}](./{sub3}/spec.md) | 2 | Draft | [Description] | P2 |

See individual sub-feature specs for details.
```

Remove sections moved to sub-features. Keep only cross-cutting concerns.

Update frontmatter:
```yaml
status: in-progress  # if was draft
```

### Parent dependencies.md Updates

Add this section:

```markdown
## Sub-Features

This feature is decomposed into:

- **{sub-feature-1}**: [Description] -> [dependencies.md](./{sub1}/dependencies.md)
- **{sub-feature-2}**: [Description] -> [dependencies.md](./{sub2}/dependencies.md)

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
