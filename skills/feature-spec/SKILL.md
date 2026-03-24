---
description: "Use when starting a new feature. Creates spec.md, dependencies.md in the features directory. Handles requirements, user stories, acceptance criteria. Do NOT use for implementation or tech specs."
---

# Create Feature Specification

Create a new feature specification following the project's documentation-first workflow.

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

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
   - External Dependencies (packages, APIs)
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

## Rules
- Use kebab-case for feature directory name
- NO implementation details in spec (no file paths, class names)
- Use "must" for requirements, "may" for optional
- Ensure bidirectional dependency links are consistent
