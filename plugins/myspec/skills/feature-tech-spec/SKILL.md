---
name: "feature-tech-spec"
description: "Use when designing implementation for an approved feature. Creates tech-spec.md with architecture and implementation steps. Requires approved spec.md. Do NOT use for features still in planning."
tags: [technical, specification, architecture, implementation]
---

# Feature Tech-Spec

## Prerequisites
- `${aiDir}/features/{feature}/spec.md` must exist with `status: approved`

## Workflow

1. **Read the Product Spec**
   - Read `${aiDir}/features/{feature}/spec.md`
   - Note the current `spec_version`
   - Understand all requirements and acceptance criteria

2. **Research Existing Patterns**
   - Examine similar implementations in the codebase
   - Check related features for consistency
   - Review database schema for related entities
   - **Enumerate reuse candidates** (feeds the `### Reuse audit` section in step 3):
     - This is **required by default**. Skip ONLY if `.myspec.json` has `reuseAudit: { "enabled": false }`.
     - Read the topology file (`.myspec.json` → `topologyFile`, falling back to `backbone.yml` at the project root). If neither exists, enumerate surfaces by inspection instead of skipping.
     - Enumerate the project's shared surfaces:
       - Every top-level key under `packages:` — read its `path:` and `entry:` (or the package's `src/index.ts`) for exported primitives.
       - Each app's `src.lib` and `src.lib/validators` paths, if present.
       - Each app's `src.composables` path, if present (read its barrel/index file if one exists).
       - If a surface key is absent from the topology file, skip that surface (do not fail).
     - For each surface, list the primitives relevant to this feature's scope. These become the rows of the reuse-audit table.

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

### Reuse audit

Required (default-on; omit only when `.myspec.json` sets `reuseAudit.enabled: false`). Comes before Key Interfaces because interface decisions depend on what is reused. Populate from the step-2 enumeration. At least one row.

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| BaseDialog | packages/uikit | reuse | matches modal need in REQ-12 |
| useFormState | apps/web/src/composables | skip | needs multi-step state outside its scope |

Rules (mechanically enforced by the `require-reuse-audit` hook; also checked by `feature-tech-spec-review`):
- `Decision` is exactly `reuse` or `skip` — one token, no prose.
- `Reason` is mandatory for every `skip` row; optional for `reuse`.
- Do not proceed to "Validate Alignment" with an empty audit.

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
- [ ] `### Reuse audit` section present with >= 1 row; every `skip` row has a Reason (unless `reuseAudit.enabled: false`)
- [ ] Key Interfaces / Types section defines new types introduced
- [ ] Database Changes section present (or explicitly marked "None")
- [ ] Run verification checks from `.claude/verification.json` — all pass

## Integration

**Called by:** `/myspec:feature-spec-review` or `/myspec:cross-spec-validation` (after spec is approved and optionally cross-validated)
**Next:** `/myspec:feature-plan` — REQUIRED: create execution-ready implementation plan from this tech-spec
