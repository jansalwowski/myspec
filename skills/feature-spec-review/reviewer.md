# Feature Spec Review: Reviewer Steps

Steps 1–6 of `feature-spec-review`. The reviewer subagent runs them. The main session runs them only when it cannot dispatch the reviewer. Steps 7–9 are in `SKILL.md`.

## Steps

1. **Load Context**
   - Read `${aiDir}/features/{feature}/spec.md`
   - Read `${aiDir}/features/{feature}/dependencies.md`
   - Read `${aiDir}/features/index.yaml` to verify feature status and dependencies
   - Read related feature specs listed in dependencies.md

2. **Analyze Structure**
   - Check spec.md and dependencies.md against [`_shared/spec-template.md`](../_shared/spec-template.md): frontmatter fields, every required section, `REQ-001` requirement IDs, `- [ ] AC-1:` acceptance criteria, the dependencies.md headings
   - Check for empty or stub sections

3. **Apply Review Dimensions**: check spec.md against each of the 8 [Review Dimensions](#review-dimensions) and run the [Detection Patterns](#detection-patterns).

4. **Cross-Validate Dependencies**: apply every [Cross-File Validation Rule](#cross-file-validation-rules).

5. **Present Findings**: one table per the [Output Format](#output-format), grouped Critical → High → Medium → Low, with line numbers. Rate each finding by the [Severity Classification](#severity-classification).

6. **Propose Fixes**: for each finding, a concrete rewrite or addition in diff format (`- old text` / `+ new text`) with its rationale, tagged per [review-output.md](../_shared/review-output.md#tagging-and-application-rules).

## Review Dimensions

| Dimension | Detection Patterns | What to Check |
|-----------|-------------------|---------------|
| **Completeness** | `TBD`, `TODO`, `???`, `etc.`, empty sections | Missing user stories, gaps in requirements, undefined edge cases, incomplete enumerations |
| **Consistency** | Contradictory requirements, conflicting priorities | Same concept described differently, requirements that contradict each other, misaligned acceptance criteria |
| **Clarity** | `might`, `could`, `possibly`; `should` without `must` | Vague language, unmeasurable criteria, ambiguous terms, unclear priorities. RFC-style `may` marking an explicitly optional requirement is correct usage (feature-spec mandates it) — flag `may` only when it leaves a *required* behavior undecided |
| **Scope** | Empty "Out of Scope", "nice to have" in requirements | Scope creep indicators, features contradicting "Out of Scope", undefined boundaries |
| **Testability** | Acceptance criteria not in the `- [ ] AC-1:` form, subjective criteria | Unmeasurable criteria, untestable requirements, no clear pass/fail conditions |
| **Dependencies** | Feature names mentioned in spec.md | Dependencies not in dependencies.md, circular dependencies, missing features in index.yaml |
| **Assumptions** | `assumes`, `expects`, `given that`, implicit prerequisites | Hidden assumptions, unstated preconditions, undocumented system state requirements |
| **YAGNI** | `future`, `extensible`, `scalable`, `flexible` | Over-engineering, features without clear user value, premature optimization, "just in case" requirements |

## Detection Patterns

Run these checks against spec.md content:

```typescript
// Vague language (Clarity) — `may` excluded: it is the mandated marker for
// optional requirements; flag it only when it hedges a required behavior
/\b(might|could|possibly|perhaps|probably)\b/gi

// Incomplete enumeration (Completeness)
/\b(etc\.|and so on|and more|among others)\b/gi

// Unclear priority (Clarity)
/\bshould\b/gi  // Flag if not paired with "must"

// Unresolved decisions (Completeness)
/\b(TBD|TODO|FIXME|\?\?\?)\b/gi

// Potential scope creep (Scope)
// Check: Is "Out of Scope" section empty or generic?
```

Technical content is `feature-spec-cleanup`'s job, not a dimension here. If spec.md holds a code block or SQL, add one Low row that recommends `/myspec:feature-spec-cleanup`, and no other finding for it.

## Severity Classification

| Severity | Definition | Must Fix Before |
|----------|------------|-----------------|
| **Critical** | Blocks progression - contradictions, missing core requirements, broken dependencies | tech-spec |
| **High** | Must fix before tech-spec - unclear acceptance criteria, dependency issues | tech-spec |
| **Medium** | Should fix - vague language, missing edge cases, testability concerns | implementation |
| **Low** | Nice to have - wording improvements, documentation polish | feature-complete |

## Cross-File Validation Rules

### spec.md → dependencies.md
Headings are the ones in [`_shared/spec-template.md`](../_shared/spec-template.md#dependenciesmd).

- Every feature name mentioned in spec.md Requirements/User Stories must appear in dependencies.md "Feature Dependencies"
- If spec.md says "Out of Scope: Feature X", Feature X should NOT be in dependencies.md

### dependencies.md → index.yaml
- Every feature under "Feature Dependencies" must exist in ${aiDir}/features/index.yaml and be in this feature's `depends-on` list
- Every feature under "Dependent Features" must exist in ${aiDir}/features/index.yaml

### dependencies.md Bidirectional Check
- If Feature A lists Feature B under "Feature Dependencies", then Feature B should list Feature A under "Dependent Features"
- Circular dependencies are an error: A depends on B, B depends on A

### Feature Status Compatibility
- Draft features cannot depend on other draft features
- In-progress features should not depend on draft features (warning, not error)
- Complete features can depend on any status

## Output Format

**REQUIRED:** Follow [../\_shared/review-output.md](../_shared/review-output.md) for the findings table, fix-proposal shape, and tagging rules. Example row for this skill:

```markdown
| Critical | Consistency | Contradictory requirements | spec.md | 45-47, 89 | REQ-003 requires admin approval, but AC-7 allows auto-approval |
```
