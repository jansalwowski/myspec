---
name: "feature-spec"
description: "Use when starting a new feature. Creates spec.md, dependencies.md in ${aiDir}/features/. Handles requirements, user stories, acceptance criteria. Do NOT use for implementation or tech specs."
tags: [feature, specification, planning, documentation]
---

# Feature Spec

## Instructions

1. **Gather Information**
   - Ask the user about the feature concept
   - Identify dependencies from `${aiDir}/features/index.yaml`
   - Check for related existing features

2. **Create Spec Document**
   Create `${aiDir}/features/{feature-name}/spec.md` with:

```yaml
---
title: "{Feature Title}"
status: draft
phase: 1
priority: P{0|1|2}
spec_version: 1
created: {TODAY}
last_updated: {TODAY}
---
```

Required sections:
- **Overview**: 2-3 sentence summary
- **Goals**: Bullet list of what this achieves
- **User Stories / Requirements**: Numbered, testable requirements
- **Acceptance Criteria**: Testable "done" conditions
- **Out of Scope**: What this does NOT cover
- **Open Questions**: Unresolved decisions

3. **Create Dependencies Document**
   Create `${aiDir}/features/{feature-name}/dependencies.md`:
   - Feature Dependencies (what this depends on)
   - Dependent Features (what depends on this)
   - External Dependencies (npm packages, APIs)
   - Rationale for non-obvious dependencies

4. **Update Feature Manifest**
   Add entry to `${aiDir}/features/index.yaml`:
```yaml
- name: {feature-name}
  title: "{Feature Title}"
  status: draft
  phase: 1
  priority: P{0|1|2}
  depends-on: [{dependencies}]
```

5. **Present for Review**
   Show the created documents and ask for approval.

6. **Commit Decision**
   Prompt the user about committing the spec. **Why:** uncommitted spec files
   dangle on the current branch by the time `/myspec:feature-implement` runs.

   Detection (REQUIRED reference: [`skills/_shared/git-helpers.md`](../_shared/git-helpers.md)):
   - Resolve the default branch (main vs master)
   - Read current `HEAD` and working-tree cleanliness
   - Decide which option to mark `(Recommended)`

   Then call `AskUserQuestion` with:

   ```
   question: "The spec is uncommitted. Where should it go?"
   header:   "Commit spec"
   options:
     - "Commit to {HEAD}"           → stage spec.md, dependencies.md, index.yaml
                                       on the current branch
     - "New branch feat/{name}"     → create feat/{name}, switch, then commit
     - "Leave uncommitted"          → skip; user will commit manually
   ```

   - Order options so the recommended one is first with `(Recommended)` appended.
   - Default commit message: `feat({name}): add spec and dependencies`
     — show the draft, accept-or-edit before committing.
   - If working tree has unrelated dirty changes: warn and stage only the spec
     files explicitly (no `git add -A`).
   - If user picks "New branch" and the branch already exists: offer checkout
     vs. a numeric suffix (`feat/{name}-2`).

## Rules
- Use kebab-case for feature directory name
- NO implementation details in spec (no file paths, class names)
- Use "must" for requirements, "may" for optional
- Ensure bidirectional dependency links are consistent

## Verification Checklist

- [ ] `${aiDir}/features/{feature}/spec.md` created with valid YAML frontmatter
- [ ] `status: draft` field present in frontmatter
- [ ] All required sections present: Overview, Goals, User Stories, Acceptance Criteria, Out of Scope, Open Questions
- [ ] `${aiDir}/features/{feature}/dependencies.md` created
- [ ] Entry added to `${aiDir}/features/index.yaml`
- [ ] No implementation details in spec (no file paths, class names, SQL, code)
- [ ] Run project documentation audit command if configured
- [ ] Commit decision presented to user (Step 6) and acted on

## Integration

**Next:** `/myspec:feature-spec-review` — validate spec before proceeding to technical design
**Next (large features):** `/myspec:feature-decompose` — split into sub-features before feature-spec-review
