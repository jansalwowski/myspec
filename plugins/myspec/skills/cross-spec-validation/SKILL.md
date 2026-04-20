---
name: cross-spec-validation
description: Use when a new or modified feature spec may contradict, supersede, or break assumptions in existing feature specs. Keywords: cross-spec, contradiction, spec conflict, supersede, breaking change, API contract, schema conflict, behavioral assumption. Do NOT use for single-spec review (use feature-spec-review) or code-level drift (use feature-spec-sync).
tags: [feature-workflow, validation, cross-cutting, specification]
---

# Cross-Spec Validation

Detect contradictions, broken contracts, and superseded assumptions between a target feature spec and all related feature specs. Reads specs only — no code exploration.

## Prerequisites

- Target feature must have `spec.md` in `${aiDir}/features/{feature}/`
- Target feature should have passed `/myspec:feature-spec-review` or `/myspec:feature-tech-spec-review`

## Workflow

### 1. Load Target Feature

- Read `${aiDir}/features/{feature}/spec.md`
- Read `${aiDir}/features/{feature}/dependencies.md` (if exists)
- Read `${aiDir}/features/{feature}/tech-spec.md` (if exists)
- Extract key concepts: modified behaviors, new fields, changed APIs, gating changes, computation shifts

### 2. Build Related Feature Set

Two discovery methods — use both:

**A. Dependency Graph (from index.yaml)**

- Read `${aiDir}/features/index.yaml`
- Find features where target appears in `depends-on`
- Find features listed in target's `depends-on`
- Include transitive dependencies one level deep (features that depend on target's dependents)

**B. Keyword Scan (catch undeclared relationships)**

- Extract domain keywords from target spec (model names, field names, API paths, behavioral terms)
- Grep all `${aiDir}/features/*/spec.md` and `${aiDir}/features/*/tech-spec.md` for those keywords
- Add any feature with 2+ keyword matches to the related set

Combine both methods. Deduplicate. This is the **blast radius**.

If the related set is empty (no dependencies AND no keyword matches), report "No related features found — cross-spec validation clean" and skip to step 8.

### 3. Analyze Each Related Feature

For each related feature, read its `spec.md` and `tech-spec.md`, then check all 5 contradiction dimensions:

| Dimension | What to Check | Example |
|-----------|--------------|---------|
| **API Contract** | Response format changes, new/removed fields, type changes, endpoint behavior | Target adds `alignmentScore` to task response — do consumers expect it? |
| **Behavioral Assumption** | Logic that moves (client→server, sync→async), computation ownership, data flow changes | Target moves alignment calc server-side — existing spec assumes client-side |
| **Schema/Model** | New columns, removed fields, type changes, renamed fields, new required relations | Target adds `secondary_element` to tasks — existing specs assume single element |
| **Gating/Access** | Feature flag changes, subscription tier requirements, middleware changes | Target gates scoring behind Plus — existing spec assumes all users get alignment |
| **Display/UX** | UI assumptions about data format, component expectations, layout contracts | Target introduces 5 tiers — existing spec shows binary aligned/not-aligned badge |

### 4. Classify Findings

| Severity | Definition | Action Required |
|----------|------------|-----------------|
| **Critical** | Direct contradiction — two specs require mutually exclusive behavior | Must resolve before feature-plan |
| **High** | Broken assumption — related spec assumes behavior that target changes | Should add "superseded by" note |
| **Medium** | Implicit dependency — related spec doesn't mention target's domain but could be affected | Review and confirm no conflict |
| **Low** | Terminology drift — same concept named differently across specs | Document for consistency |

### 5. Present Contradiction Report

If no contradictions found across any dimension, report clean result and skip to step 8 (no confirmation needed for zero findings).

Output grouped by severity:

```markdown
# Cross-Spec Validation: {target-feature}

## Blast Radius
Features checked: {list with discovery method: dep-graph / keyword-scan / both}

## Contradictions Found

| # | Severity | Related Feature | Dimension | Finding | Target Spec Line | Related Spec Line |
|---|----------|----------------|-----------|---------|-------------------|-------------------|
| 1 | Critical | tasks | Schema | tasks spec assumes single element; target adds secondary_element | spec.md:16 | tasks/spec.md:42 |
| 2 | High | element-suggestion | Behavioral | element-suggestion returns one element; target requires up to two | spec.md:18 | element-suggestion/spec.md:31 |

## Recommended Actions

### Critical: {finding title}
**Conflict**: {description}
**Resolution options**:
1. Update {related-feature}/spec.md to reflect new behavior
2. Add constraint to target spec to maintain backward compatibility
3. {other option if applicable}

### High: {finding title}
**Superseded assumption**: {what changed}
**Proposed note** for {related-feature}/spec.md:
> ⚠️ Superseded by {target-feature} (spec_version {N}): {what changed}
```

### 6. Wait for Confirmation

Present three action options:
- **Apply notes**: Add "superseded by" notes to affected specs (non-destructive)
- **Fix specific**: User picks which contradictions to resolve
- **Report only**: No changes, user addresses manually

Do NOT modify any spec without explicit approval.

### 7. Execute Approved Changes

For "superseded by" notes:
- Add note at the relevant section in the related spec (near the contradicted requirement)
- Use this format: `> ⚠️ Superseded by {feature} (v{N}, {date}): {what changed}`
- Do NOT rewrite existing requirements — only annotate

For spec updates:
- Show diff before applying
- Increment `spec_version` in modified specs
- Update `last_updated` date

### 8. Summary

- List all changes made (files, sections)
- List unresolved contradictions
- Recommend next step: `/myspec:feature-tech-spec` or `/myspec:feature-plan` depending on entry point. If unresolved Critical/High contradictions remain — address those first.

## Keyword Extraction Patterns

Extract these from target spec for keyword scanning:

```
- Model/table names: nouns from spec headers and data model references
- Field names: attributes mentioned in requirements or schema sections
- API paths: endpoint patterns from spec or tech-spec
- Feature names: mentioned in requirements or user stories
- Behavioral terms: "client-side", "server-side", "cached", "real-time", "gated"
```

Adapt patterns to target spec content — these are examples, not an exhaustive list.

## Rules

- Never modify specs without explicit user approval (steps 6-7 are gated)
- Never rewrite existing requirements — only annotate with "superseded by" notes
- Always use both discovery methods (dependency graph + keyword scan) — do not skip one
- Always include specific line numbers in findings — vague references are not actionable
- If zero related features found, report clean and exit — do not fabricate findings

## Integration

**Called after:** `/myspec:feature-spec-review` or `/myspec:feature-update`
**Called before:** `/myspec:feature-tech-spec` or `/myspec:feature-plan`
**Does NOT replace:** `/myspec:feature-spec-review` (single-spec quality) or `/myspec:feature-spec-sync` (code drift)

## Verification Checklist

- [ ] Target spec.md was fully read and key concepts extracted
- [ ] Related features found via BOTH dependency graph AND keyword scan
- [ ] All 5 contradiction dimensions checked for each related feature
- [ ] Findings include specific line numbers from both target and related specs
- [ ] Severity classification applied to each finding
- [ ] "Superseded by" notes proposed for High+ findings
- [ ] No changes made without user confirmation
- [ ] Summary lists unresolved contradictions (if any)
