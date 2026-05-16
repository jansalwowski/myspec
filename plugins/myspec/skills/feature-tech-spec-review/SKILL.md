---
name: feature-tech-spec-review
description: "Use when reviewing tech-spec.md for implementability, spec alignment, and pattern conformance. Keywords: review tech-spec, validate technical design, check implementation plan, critique tech-spec, tech-spec analysis, technical review. Checks spec alignment, feasibility, completeness, pattern conformance, step granularity, dependency ordering, testability, YAGNI, and scope. Do NOT use for spec.md review (use feature-spec-review), implementation review, or code review."
tags: [feature-workflow, tech-spec, validation, critical-thinking, review]
---

# Feature Tech-Spec Review

## Workflow

1. **Load Context**
   - Read `${aiDir}/features/{feature}/tech-spec.md`
   - Read `${aiDir}/features/{feature}/spec.md`
   - Read `${aiDir}/features/{feature}/dependencies.md`
   - Read `${aiDir}/features/index.yaml` to verify feature status
   - Read `.claude/rules/` convention files if they exist (backend, frontend, database)
   - If sub-feature: also read parent tech-spec.md

2. **Analyze Structure**
   - Verify required sections exist: Architecture, Reuse audit, Implementation Steps, Edge Cases, File Inventory
   - Check optional sections present if relevant: Key Interfaces/Types, Database Changes, GraphQL Schema, API Endpoints, Decisions
   - **Reuse-audit gate** (skip only if `.myspec.json` has `reuseAudit.enabled: false`). Flag and **refuse approval** (do not recommend `/myspec:feature-plan`) when the `### Reuse audit` section is:
     - missing, OR
     - an empty table (header + separator only, zero data rows), OR
     - a blanket-skip audit (every row `skip`) with one or more rows lacking a `Reason`, OR
     - has any `skip` row with an empty / dash-only `Reason`, OR
     - has any row whose `Decision` is not exactly `reuse` or `skip`.
   - A blanket-skip audit where every row has a substantive `Reason` is allowed but warrants a High finding asking the author to re-confirm nothing is reusable.
   - Validate frontmatter has `title`, `status`, `based_on_spec_version`, `created`, `last_updated`
   - Verify `based_on_spec_version` matches current `spec_version` in spec.md

3. **Apply Review Dimensions** (Check tech-spec.md against all 9 dimensions below)
   - Spec Alignment: Every spec.md requirement has an implementation path; no orphan tech-spec items without spec backing
   - Feasibility: Implementation steps achievable with the project's tech stack (from `.myspec.json` or CLAUDE.md)
   - Completeness: Missing sections, empty checklists, no file inventory, no edge cases, TBD/TODO present
   - Pattern Conformance: Follows codebase patterns per backend.md, frontend.md, database.md
   - Step Granularity: Steps not too coarse (multi-day, multi-concern) or too fine (single-line changes)
   - Dependency Ordering: Steps in logical order; dependencies created before consumers
   - Testability: Each step verifiable, test files present in file inventory
   - YAGNI / Over-Engineering: No unnecessary abstractions, premature optimization, "future-proof" scope
   - Scope / Size Assessment: Judgment-based split detection (see Scope Assessment section)

4. **Cross-Validate Spec Alignment**
   - Check: Every requirement in spec.md has at least one implementation step
   - Check: Every acceptance criterion in spec.md is traceable to a file in the inventory or a step
   - Check: No implementation step introduces functionality not in spec.md (scope creep)
   - Check: `based_on_spec_version` matches spec.md `spec_version` — mismatch is Critical

5. **Check Pattern Conformance**
   - Check: Implementation follows patterns defined in `${aiDir}/conventions/` and `.claude/rules/`
   - Check: File paths match expected project organization (per conventions docs)
   - Check: Naming conventions followed (per project coding standards)
   - Check: Database models include required audit fields (per project database conventions, if defined)
   - Check: Service/component patterns match project conventions (per project rules, if defined)

6. **Present Findings**
   - Output table: Severity | Dimension | Issue | File | Line(s) | Finding
   - Group by severity: Critical → High → Medium → Low
   - Include specific line numbers for each issue

7. **Classify and Apply Fixes**
   - **Small issues** (typos, missing sections, unclear wording, missing edge cases, frontmatter fixes): apply immediately without asking
   - **Big issues** (strategy changes, splitting into sub-features, removing/changing steps, interface changes, conceptual problems): propose solution and WAIT for confirmation
   - Tag proposals: `[auto-fix]` or `[requires confirmation]`
   - Use diff format: `- old text` / `+ new text`

8. **Execute Changes**
   - Apply small fixes immediately
   - Apply confirmed big fixes
   - Update `last_updated` date in frontmatter
   - If `based_on_spec_version` was stale but spec is unchanged: update it

9. **Summary**
   - Show changes made (file paths, sections affected)
   - List remaining issues (if any were rejected)
   - Recommend next step: re-review, `/myspec:feature-plan`, or address open issues first

## Review Dimensions Reference

| Dimension | Detection Patterns | What to Check |
|-----------|-------------------|---------------|
| **Spec Alignment** | Compare spec.md requirements/ACs with tech-spec steps | Every requirement addressed, no orphan steps, version match |
| **Feasibility** | Unknown packages, non-existent APIs, impossible constraints | Steps achievable with the project's tech stack |
| **Completeness** | `TBD`, `TODO`, `???`, empty sections, missing file inventory | All required sections present, all steps have detail |
| **Pattern Conformance** | Service/GraphQL/validator/component patterns | Matches backend.md, frontend.md, database.md conventions |
| **Step Granularity** | Steps joining unrelated work with "and", single-line steps | Each step = single responsibility, ~1–4 hours |
| **Dependency Ordering** | Step N references types/files from Step N+M | Steps ordered so dependencies created before consumers |
| **Testability** | Steps without test files in inventory, no test strategy | Each step has verifiable output, test file in inventory |
| **YAGNI** | `future`, `extensible`, `scalable`, `flexible`, generic abstractions | No unused abstractions, no premature optimization |
| **Scope / Size** | Multiple independent capabilities, unrelated domains mixed | See Scope Assessment section |

## Scope Assessment

This dimension is **judgment-based**, not threshold-based. Do NOT count steps or lines. Look for these signals:

| Signal | Indicates Split Needed |
|--------|----------------------|
| Multiple independent capabilities that could ship separately | Yes |
| Unrelated domain areas mixed in one tech-spec | Yes |
| Steps with zero dependency on each other serving different user stories | Likely |
| Feature touches multiple unrelated areas of the codebase | Likely |
| "Phase 2" or "deferred" sections with substantial scope | Consider sub-feature |
| Single coherent capability with many steps | No — large is fine if cohesive |

When splitting is recommended:
- Propose concrete sub-feature boundaries with names
- Reference `/myspec:feature-decompose` skill for execution
- Flag as High severity (tech-spec is valid but should be restructured)

## Fix Policy

| Category | Examples | Action |
|----------|----------|--------|
| **Small (auto-fix)** | Typos, missing edge cases, frontmatter date fixes, adding missing sections with stub content, unclear wording, missing file inventory rows | Apply immediately |
| **Big (requires confirmation)** | Strategy changes, splitting into sub-features, removing or reordering steps, adding new capabilities, changing interfaces, conceptual issues | Propose and WAIT |

## Detection Patterns (Automated Checks)

```typescript
// Incomplete content (Completeness)
/\b(TBD|TODO|FIXME|\?\?\?|placeholder)\b/gi

// YAGNI indicators
/\b(future[- ]proof|extensible|scalable|flexible|generic|just in case)\b/gi

// Missing checklist items (Completeness)
// Check: Implementation Steps section has at least one `- [ ]` item

// Spec version mismatch (Spec Alignment)
// Compare: tech-spec frontmatter `based_on_spec_version` vs spec.md `spec_version`

// Missing file inventory (Completeness)
// Check: File Inventory section exists and has at least one row

// Reuse audit (Spec Alignment) — see the Reuse-audit gate in step 2 for severities
// Refuse approval (blocks feature-plan) if: section missing, OR table empty (0 data
//   rows), OR any row Decision not exactly {reuse, skip}, OR any `skip` row without a
//   non-dash Reason (this also covers a blanket-skip table with any Reason-less row).
// High finding (not a refusal): every row is `skip` but each has a substantive Reason —
//   ask the author to re-confirm nothing is reusable.
// Skip this check entirely if .myspec.json has reuseAudit.enabled === false

// Missing edge cases (Completeness)
// Check: Edge Cases section exists and has at least one item

// Vague steps (Step Granularity)
/\b(set up|configure|implement|add support for)\b/gi  // Flag if step has no specific files
```

## Output Format

### Findings Table

```markdown
| Severity | Dimension | Issue | File | Line(s) | Finding |
|----------|-----------|-------|------|---------|---------|
| Critical | Spec Alignment | Version mismatch | tech-spec.md | 4 | `based_on_spec_version: 1` but spec.md has `spec_version: 3` |
| High | Pattern Conformance | Missing audit fields | tech-spec.md | 67-72 | Model lacks required audit fields per project database conventions |
| Medium | Step Granularity | Step too coarse | tech-spec.md | 45 | "Step 3: Build entire frontend" — split into component tasks |
| Low | Completeness | Missing edge case | tech-spec.md | — | No edge case for empty search results |
```

### Fix Proposals

```markdown
## Fix 1: Add missing audit fields (High) [auto-fix]

**File**: tech-spec.md:67-72
**Issue**: Model missing required audit fields per project database conventions.

- model SearchQuery {
-   id    String @id @default(cuid())
-   query String
- }
+ model SearchQuery {
+   id        String   @id @default(cuid())
+   query     String
+   createdAt DateTime @default(now())
+   createdBy String
+   updatedAt DateTime @updatedAt
+ }

**Rationale**: All models require audit fields per project database conventions.
```

```markdown
## Fix 2: Split into sub-features (High) [requires confirmation]

**Issue**: Tech-spec covers both query logging AND analytics dashboard — independent capabilities that could ship separately.

**Proposed split** (via `/myspec:feature-decompose`):
1. `search/query-logging` — SearchQuery model, logging service, middleware hook
2. `search/analytics` — Dashboard page, aggregation queries, charts (depends on query-logging)

**Rationale**: Query logging is useful and shippable without the dashboard. Dashboard depends on logging data but not vice versa.

**ACTION REQUIRED**: Confirm or reject this split before proceeding.
```

## Severity Classification

| Severity | Definition | Must Fix Before |
|----------|------------|-----------------|
| **Critical** | Blocks implementation — spec version mismatch, missing core implementation path, contradictory steps | `/myspec:feature-plan` |
| **High** | Must fix — missing patterns, wrong conventions, scope issues, missing test strategy, split recommended | `/myspec:feature-plan` |
| **Medium** | Should fix — missing edge cases, vague steps, incomplete file inventory | implementation |
| **Low** | Nice to have — wording improvements, additional detail, documentation polish | feature-complete |

## Cross-File Validation Rules

### tech-spec.md → spec.md
- Every requirement in spec.md must have at least one implementation step
- Every acceptance criterion must be traceable to a file in the inventory or a step
- `based_on_spec_version` must match spec.md `spec_version`

### tech-spec.md → dependencies.md
- Cross-feature dependencies mentioned in tech-spec must appear in dependencies.md
- If tech-spec imports from another feature's code, that feature must be in dependencies.md

### tech-spec.md → codebase patterns
- File paths follow naming and organization conventions defined in `.claude/rules/` or `${aiDir}/conventions/`
- Models include required audit fields per project database conventions (if defined)

## Verification Checklist

After running the skill:

- [ ] All 9 review dimensions checked against tech-spec.md
- [ ] Reuse-audit gate applied: section present, >= 1 row, valid Decision/Reason (or `reuseAudit.enabled: false`)
- [ ] `based_on_spec_version` matches spec.md `spec_version`
- [ ] Every spec.md requirement has an implementation path in tech-spec
- [ ] File inventory paths follow project conventions (per `.claude/rules/` or `${aiDir}/conventions/`)
- [ ] Models include required audit fields (if project defines them)
- [ ] Service/component patterns match project conventions
- [ ] Implementation steps are in dependency order
- [ ] Each step has reasonable granularity (single responsibility)
- [ ] Edge Cases section is non-empty
- [ ] Issues categorized by severity (Critical/High/Medium/Low)
- [ ] Each finding includes file name and line numbers
- [ ] Small fixes applied automatically without asking
- [ ] Big fixes proposed with `[requires confirmation]` tag and awaited
- [ ] `last_updated` set to today after changes
- [ ] Summary shows files changed and remaining issues

## Example Usage

```
User: /tech-spec-review tags
```

**Expected behavior**:
1. Load ${aiDir}/features/tags/tech-spec.md, spec.md, dependencies.md, and index.yaml
2. Load backend.md, frontend.md, database.md for pattern reference
3. Check all 9 dimensions against tech-spec.md
4. Cross-validate spec alignment (requirements → steps, ACs → file inventory)
5. Validate pattern conformance against codebase conventions
6. Present findings table with severity, dimension, file, line numbers
7. Auto-apply small fixes; propose big fixes with rationale
8. Wait for user to confirm big fixes
9. Apply confirmed fixes, update `last_updated`
10. Show summary and recommend next step

## Integration

**Called by:** `/myspec:feature-tech-spec` (after tech-spec is created and user wants review)
**Next:** `/myspec:feature-plan` — create execution-ready implementation plan once tech-spec passes review
