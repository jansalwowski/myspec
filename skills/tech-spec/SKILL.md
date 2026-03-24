---
description: "Use when designing implementation for an approved feature. Creates tech-spec.md with architecture and implementation steps. Requires approved spec.md. Do NOT use for features still in planning."
---

# Create Technical Specification

Create a technical specification from an approved product spec.

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

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
```
// New interfaces this feature introduces
// Use your project's language conventions
```

### Implementation Steps
Ordered task list:
1. [ ] Task with dependency notes
2. [ ] Task (depends on 1)
3. [ ] ...

### Database Changes
```
// New models or field additions
// Use your project's schema format (migrations, ORM models, etc.)
```

### API Design
```
// API endpoints, schema definitions, or RPC interfaces
// Use your project's API format
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
| `path/to/file` | Create | Description |
| `path/to/existing` | Modify | What changes |

4. **Validate Alignment**
   - Ensure `based_on_spec_version` matches `spec.md`'s `spec_version`
   - All acceptance criteria have implementation paths
   - All requirements are addressed

5. **Present for Review**
   Show the tech spec and ask for approval before implementation.
