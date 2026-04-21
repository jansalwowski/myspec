---
name: "feature-tech-spec"
description: "Use when designing implementation for an approved feature. Creates tech-spec.md with architecture and implementation steps. Requires approved spec.md. Do NOT use for features still in planning."
tags: [technical, specification, architecture, implementation]
---

# Feature Tech-Spec

## Prerequisites
- `${aiDir}/features/{feature}/spec.md` must exist with `status: approved`

## Instructions

1. **Read the Product Spec**
   - Read `${aiDir}/features/{feature}/spec.md`
   - Note the current `spec_version`
   - Understand all requirements and acceptance criteria

2. **Research Existing Patterns**
   - Examine similar implementations in the codebase
   - Check related features for consistency
   - Review database schema for related entities

3. **Create Tech Spec Document**
   Create `${aiDir}/features/{feature}/tech-spec.md`:

```yaml
---
title: "{Feature Title} -- Technical Specification"
status: draft
based_on_spec_version: {spec_version from spec.md}
created: {TODAY}
last_updated: {TODAY}
---
```

Required sections:

### Architecture
- How this fits into the system
- Key components and their responsibilities
- Data flow diagram (if complex)

### Key Interfaces / Types
```typescript
// New interfaces this feature introduces
interface EntityInput { ... }
interface EntityOutput { ... }
```

### Implementation Steps
Ordered task list:
1. [ ] Task with dependency notes
2. [ ] Task (depends on 1)
3. [ ] ...

### Database Changes
```
// New models, tables, or field additions (use project's schema language)
Entity {
  id        ...
  // ...
}
```

### API Schema (if applicable)
```
// New API types, GraphQL schema, REST endpoints, etc.
type Entity {
  id: ID!
  # ...
}
```

### API Endpoints (if applicable)
| Method | Path | Purpose |
|--------|------|---------|
| POST | /api/... | Description |

### Decisions
Document key architectural decisions as ADRs:
- **Decision**: What was decided
- **Context**: Why this decision was needed
- **Alternatives**: What was considered
- **Consequences**: Trade-offs

### Edge Cases
- Case 1: How handled
- Case 2: How handled

### File Inventory
| File | Action | Purpose |
|------|--------|---------|
| `path/to/file.ts` | Create | Description |
| `path/to/existing.ts` | Modify | What changes |

4. **Validate Alignment**
   - Ensure `based_on_spec_version` matches `spec.md`'s `spec_version`
   - All acceptance criteria have implementation paths
   - All requirements are addressed

5. **Present for Review**
   Show the tech spec and ask for approval before implementation.

## Verification Checklist

- [ ] `${aiDir}/features/{feature}/tech-spec.md` created with valid YAML frontmatter
- [ ] `based_on_spec_version` matches `spec_version` in spec.md
- [ ] Every acceptance criterion from spec.md has at least one implementation step
- [ ] All implementation steps have dependency notes where applicable
- [ ] File Inventory table covers all files to be created/modified
- [ ] Key Interfaces / Types section defines new types introduced
- [ ] Database Changes section present (or explicitly marked "None")
- [ ] Run verification checks from `.claude/verification.json` — all pass

## Integration

**Called by:** `/myspec:feature-spec-review` or `/myspec:cross-spec-validation` (after spec is approved and optionally cross-validated)
**Next:** `/myspec:feature-plan` — REQUIRED: create execution-ready implementation plan from this tech-spec
