---
name: feature-spec-review
description: >
  Use when reviewing a spec.md for quality before tech-spec design — completeness,
  internal consistency, testability, scope, dependency hygiene. Keywords: review spec,
  critique requirements, validate spec, check spec, spec analysis, requirements review.
  Do NOT use for tech-spec review (use feature-tech-spec-review) or implementation review.
tags: [feature-workflow, specification, validation, critical-thinking]
---

# Feature Spec Review

## Workflow

1. **Load Context**
   - Read `${aiDir}/features/{feature}/spec.md`
   - Read `${aiDir}/features/{feature}/dependencies.md`
   - Read `${aiDir}/features/index.yaml` to verify feature status and dependencies
   - Read related feature specs listed in dependencies.md

2. **Analyze Structure**
   - Verify required sections exist: Overview, Requirements, User Stories, Acceptance Criteria, Out of Scope
   - Check for empty or stub sections
   - Validate frontmatter has spec_version, status, priority

3. **Apply Review Dimensions** (Check spec.md against all 8 dimensions below)
   - Completeness: Missing user stories, requirement gaps, undefined edge cases
   - Consistency: Contradictions between sections, conflicting requirements
   - Clarity: Vague language, unmeasurable criteria, ambiguous terms
   - Scope: Creep indicators, "Out of Scope" violations, feature bloat
   - Testability: Unmeasurable acceptance criteria, untestable requirements
   - Dependencies: Undeclared in dependencies.md, circular deps, missing in index.yaml
   - Assumptions: Hidden assumptions, unstated preconditions
   - YAGNI: Over-engineering, features without clear user value

4. **Cross-Validate Dependencies**
   - Check: Dependencies mentioned in spec.md exist in dependencies.md
   - Check: Dependencies in dependencies.md exist in index.yaml
   - Check: Bidirectional dependency links are consistent
   - Check: Feature status is compatible with dependent features (can't depend on draft)

5. **Present Findings**
   - Output table: Severity | Dimension | Issue | File | Line(s) | Finding
   - Group by severity: Critical → High → Medium → Low
   - Include specific line numbers for each issue

6. **Propose Fixes**
   - For each issue, show concrete rewrite or addition
   - Use diff format for clarity: `- old text` / `+ new text`
   - Explain rationale for each fix

7. **Wait for Confirmation**
   - Call `AskUserQuestion` so options are selectable — never render a plain bulleted list:
     ```
     question: "Which fixes should I apply?"
     header:   "Apply fixes"
     options:
       - "All"            → apply every proposed fix
       - "Critical+High"  → apply Critical and High severities only
       - "Individually"   → pick fixes one at a time
       - "None"           → leave spec unchanged
     ```
   - Order options so the recommended choice is first with `(Recommended)` appended.
   - Do NOT proceed without explicit approval.

8. **Execute Changes**
   - Apply approved fixes to spec.md and/or dependencies.md
   - Increment `spec_version` in spec.md frontmatter
   - Update `last_updated` date in frontmatter (that is the field's name — do not add an `updated` field)

9. **Summary & Next Step**
   - Show changes made (file paths, sections affected)
   - List remaining issues (if any)
   - If remaining Critical/High issues → recommend addressing those first
   - If spec is approved (no Critical/High remaining), call `AskUserQuestion`:
     ```
     question: "Spec is approved. What's next?"
     header:   "Next step"
     options:
       - "/myspec:cross-spec-validation"  → check against related specs for contradictions, broken contracts, or superseded assumptions
       - "/myspec:feature-tech-spec"      → skip cross-check, go straight to technical design
     ```
   - Mark `/myspec:cross-spec-validation` as `(Recommended)` — it is the default before tech-spec.
   - Wait for the user's choice before proceeding.

## Review Dimensions Reference

| Dimension | Detection Patterns | What to Check |
|-----------|-------------------|---------------|
| **Completeness** | `TBD`, `TODO`, `???`, `etc.`, empty sections | Missing user stories, gaps in requirements, undefined edge cases, incomplete enumerations |
| **Consistency** | Contradictory requirements, conflicting priorities | Same concept described differently, requirements that contradict each other, misaligned acceptance criteria |
| **Clarity** | `may`, `might`, `could`, `should` without `must` | Vague language, unmeasurable criteria, ambiguous terms, unclear priorities |
| **Scope** | Empty "Out of Scope", "nice to have" in requirements | Scope creep indicators, features contradicting "Out of Scope", undefined boundaries |
| **Testability** | Acceptance criteria without `[ ]`, subjective criteria | Unmeasurable criteria, untestable requirements, no clear pass/fail conditions |
| **Dependencies** | Feature names mentioned in spec.md | Dependencies not in dependencies.md, circular dependencies, missing features in index.yaml |
| **Assumptions** | `assumes`, `expects`, `given that`, implicit prerequisites | Hidden assumptions, unstated preconditions, undocumented system state requirements |
| **YAGNI** | `future`, `extensible`, `scalable`, `flexible` | Over-engineering, features without clear user value, premature optimization, "just in case" requirements |

## Detection Patterns (Automated Checks)

Run these checks against spec.md content:

```typescript
// Vague language (Clarity)
/\b(may|might|could|possibly|perhaps|probably)\b/gi

// Incomplete enumeration (Completeness)
/\b(etc\.|and so on|and more|among others)\b/gi

// Unclear priority (Clarity)
/\bshould\b/gi  // Flag if not paired with "must"

// Unresolved decisions (Completeness)
/\b(TBD|TODO|FIXME|\?\?\?)\b/gi

// Missing structure (Completeness)
// Check: Are requirements numbered? (REQ-001 pattern)

// Potential scope creep (Scope)
// Check: Is "Out of Scope" section empty or generic?

// Not checkable (Testability)
// Check: Do acceptance criteria use `[ ]` checkbox format?

// Technical leak (spec-cleanup territory)
/\b(SELECT|INSERT|UPDATE|DELETE|interface|type|class|function|const|export)\b/g
```

## Output Format

### Findings Table

```markdown
| Severity | Dimension | Issue | File | Line(s) | Finding |
|----------|-----------|-------|------|---------|---------|
| Critical | Consistency | Contradictory requirements | spec.md | 45-47, 89 | REQ-003 requires admin approval, but AC-007 allows auto-approval |
| High | Dependencies | Undeclared dependency | spec.md | 67 | Mentions "notification system" but not in dependencies.md |
| Medium | Clarity | Vague language | spec.md | 123 | "User may receive email" - unclear when this happens |
| Low | Completeness | Generic statement | spec.md | 200 | "Out of Scope: Future features" - too vague |
```

### Fix Proposals

```markdown
## Fix 1: Resolve contradictory requirements (Critical)

**File**: spec.md:45-47,89

**Issue**: REQ-003 requires admin approval, but AC-007 allows auto-approval.

**Current**:
- REQ-003: All submissions must be approved by an admin
- AC-007: System auto-approves submissions from verified users

**Proposed**:
- REQ-003: All submissions must be approved by an admin, except for verified users (see REQ-012)
+ REQ-012: Verified users (account age > 30 days AND reputation > 100) have submissions auto-approved
- AC-007: System auto-approves submissions from verified users as defined in REQ-012

**Rationale**: Clarifies the exception case and creates a traceable requirement for verified users.
```

## Severity Classification

| Severity | Definition | Must Fix Before |
|----------|------------|-----------------|
| **Critical** | Blocks progression - contradictions, missing core requirements, broken dependencies | tech-spec |
| **High** | Must fix before tech-spec - unclear acceptance criteria, dependency issues | tech-spec |
| **Medium** | Should fix - vague language, missing edge cases, testability concerns | implementation |
| **Low** | Nice to have - wording improvements, documentation polish | feature-complete |

## Cross-File Validation Rules

### spec.md → dependencies.md
- Every feature name mentioned in spec.md Requirements/User Stories must appear in dependencies.md "depends_on" section
- If spec.md says "Out of Scope: Feature X", Feature X should NOT be in dependencies.md

### dependencies.md → index.yaml
- Every feature in dependencies.md "depends_on" must exist in ${aiDir}/features/index.yaml
- Every feature in dependencies.md "enables" must exist in ${aiDir}/features/index.yaml

### dependencies.md Bidirectional Check
- If Feature A depends on Feature B, then Feature B should list Feature A in "enables"
- Circular dependencies are an error: A depends on B, B depends on A

### Feature Status Compatibility
- Draft features cannot depend on other draft features
- In-progress features should not depend on draft features (warning, not error)
- Complete features can depend on any status

## Verification Checklist

After running the skill:

- [ ] All 8 review dimensions were checked against spec.md
- [ ] dependencies.md was cross-validated with spec.md
- [ ] dependencies.md was cross-validated with index.yaml
- [ ] Bidirectional dependency links were verified
- [ ] Issues are categorized by severity (Critical/High/Medium/Low)
- [ ] Each finding includes file name and line numbers
- [ ] Fixes are proposed as concrete rewrites (diff format)
- [ ] User confirmation was requested before changes
- [ ] If changes were made: spec_version was incremented
- [ ] If changes were made: `last_updated` was set to today
- [ ] Summary shows files changed and remaining issues
- [ ] Skill did NOT flag technical content (spec-cleanup's job)

## Example Usage

```
User: /spec-review guide-versioning
```

**Expected behavior**:
1. Load ${aiDir}/features/guide-versioning/spec.md, dependencies.md, and index.yaml
2. Check all 8 dimensions against spec.md
3. Validate dependencies.md ↔ spec.md ↔ index.yaml alignment
4. Present findings table with severity, dimension, file, line numbers
5. Propose concrete fixes for each issue
6. Wait for user to approve fixes
7. Apply approved fixes and increment spec_version
8. Show summary of changes made

## Integration

**Called by:** `/myspec:feature-spec` (after spec is created and user approves review)
**Suggests:** `/myspec:cross-spec-validation` — validate against related specs *(user chooses)*
**Next:** `/myspec:feature-tech-spec` — create technical design once spec is approved
