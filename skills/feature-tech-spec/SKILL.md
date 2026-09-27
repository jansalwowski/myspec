---
name: "feature-tech-spec"
description: "Use when an approved feature needs its implementation designed. Creates tech-spec.md with architecture and implementation steps. Requires an approved spec.md."
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
verification_mode: visual   # optional: visual | api | data | mixed | none
---
```

tech-spec.md describes the design as it stands: architecture, interfaces, contracts, decisions in force, edge cases, files. It is never a task log. Progress lives in `implementation-plan.md` and history in `CHANGELOG.md`; a tech-spec that tracks either grows with every iteration and drifts from the code.

`verification_mode` names the medium a milestone's behavior is proven in — a browser, an endpoint, a query — so `feature-plan` can write checkpoint probes a separate executor runs at each milestone. Omit it and nothing changes. Set it (anything but `none`) and the conditional `### Test Hooks` section below becomes required.

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
Short ordered outline, one line per step, numbered, no checkboxes. `feature-plan` expands each step into tasks. `feature-plan`'s Spec Coverage and `feature-tech-spec-review`'s Requirement Coverage cite steps by number.
1. Step with dependency notes
2. Step (depends on 1)
3. ...

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

### Test Hooks (required when `verification_mode` is set and not `none`)
The only handles a checkpoint probe may reference. Keep the four line labels exactly — `feature-tech-spec-review` and `feature-plan` read them by name.
- **Target:** how to serve what the probes hit — the project's own serve command on scratch config and the URL or entry point it exposes (`[scratch serve command]` → `[base URL or entry point]`; name an address the project's everyday dev server does not use)
- **Contract surface:** stable, refactor-tolerant handles — `visual`: the UI test tool's stable element identifiers and state attributes on the public surface (on the web `data-testid="report-row"`, `data-state="loading"`; in a native or terminal UI its accessibility identifiers or widget keys); `api`: request/response shapes; `data`: schema expectations. Never style classes, internal element structure, or private state.
- **Real inputs** (optional): a real corpus the feature's engine must handle, and the invariant it must hold (`fixtures/corpus/*.pdf` — rendered output byte-identical to base). Named here, every milestone touching that path gets a real-input probe.
- **Scratch environment** (required when `verification_mode` is `visual` or `mixed`, when *Real inputs* is named, or when any probe will mutate data): the concrete database, bucket (every bucket variable), and queue overrides the probes run under. The checklist they must satisfy is [`_shared/scratch-isolation.md`](../_shared/scratch-isolation.md).

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
- [ ] Implementation Steps is a numbered outline with no `[ ]`/`[x]` checkboxes
- [ ] File Inventory table covers all files to be created/modified
- [ ] `### Reuse audit` section present with >= 1 row; every `skip` row has a Reason (unless `reuseAudit.enabled: false`)
- [ ] Key Interfaces / Types section defines new types introduced
- [ ] Database Changes section present (or explicitly marked "None")
- [ ] If `verification_mode` is set and not `none`: `### Test Hooks` has Target and Contract surface (plus Scratch environment when the mode is `visual` / `mixed`, *Real inputs* is named, or a probe mutates data), with no style-class or internal-structure handles
- [ ] Run verification checks from `.claude/verification.json` — all pass

## Integration

**Called by:** `/myspec:feature-spec-review` or `/myspec:cross-spec-validation` (after spec is approved and optionally cross-validated)
**Next:** `/myspec:feature-plan` — REQUIRED: create execution-ready implementation plan from this tech-spec
