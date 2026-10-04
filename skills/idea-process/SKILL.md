---
name: "idea-process"
description: "Use when an approved idea should graduate into feature documentation in ${aiDir}/features/. Requires the idea listed in PRIORITY-LISTING.md with dependencies satisfied. Keywords: promote idea, graduate idea, convert idea. Do NOT use for triage (idea-intake)."
tags: [ideas, feature, specification, processing]
---

# Idea Process

Converts an approved idea from `${aiDir}/ideas/` into `${aiDir}/features/` documentation (spec.md, dependencies.md, scenarios.md, seed.json).

## Prerequisites

Read these documents before starting:

1. `${aiDir}/features/README.md` - Feature documentation structure
2. `${aiDir}/ideas/PRIORITY-LISTING.md` - Current status and dependencies

## Workflow

### Step 1: Select Idea from Listing

1. Open `${aiDir}/ideas/PRIORITY-LISTING.md`
2. Find the highest priority idea with status `[ ]` (not started)
3. If no `[ ]` ideas exist: inform the user — no ideas are ready for processing
4. Verify dependencies are satisfied (all dependencies should be `[x]` or existing features)
5. If dependencies are not satisfied: list unmet dependencies and stop
6. Mark the idea as `[~]` (in progress)

### Step 2: Initial Analysis

1. Read the idea file completely
2. Identify the core problem being solved
3. Note any existing features this relates to
4. List unknowns and ambiguities

### Step 3: Ask Clarifying Questions

Always ask, even when the idea seems clear — every idea has details that need clarification, and a spec written from an unexamined idea encodes the wrong assumptions.

Apply these question categories:

**Scope Questions**
- What is explicitly IN scope?
- What is explicitly OUT of scope?
- What's the MVP vs nice-to-have?

**User Experience Questions**
- Who are the primary users?
- Where does this appear in the UI?
- What feedback does the user receive?

**Data Model Questions**
- What entities need to be created?
- What are the relationships to existing entities?
- What validation rules apply?

Present the questions, then wait for responses before proceeding — answers shape the spec sections in Steps 5–7.

### Step 4: Create Feature Directory

After receiving answers:

```
${aiDir}/features/{feature-name}/
├── spec.md        (required)
├── dependencies.md (required)
├── scenarios.md   (required)
└── seed.json      (required)
```

### Step 5: Write spec.md

Read template from `references/templates.md` — Section "spec.md Template".

### Step 6: Write dependencies.md

Read template from `references/templates.md` — Section "dependencies.md Template".

### Step 7: Write scenarios.md and seed.json

Write both, without offering (Step 4 marks them required; only a standalone `feature-spec` makes them optional). Follow the two reference procedures feature-spec owns, with the clarified answers and the spec's Data Model as input: scenarios per [feature-spec/references/scenarios.md](../feature-spec/references/scenarios.md), then seed data per [feature-spec/references/seed-data.md](../feature-spec/references/seed-data.md). Do not re-derive the procedure here.

### Step 8: Update Feature Index

Add the new feature to `${aiDir}/features/index.yaml` with `status: draft` (docs now exist — `planned` is only for manifest entries without docs; see the Status State Machine in `.claude/rules/workflow.md`).

### Step 9: Move to Processed

1. Move the original idea file to `${aiDir}/ideas/processed/`
2. Update `${aiDir}/ideas/PRIORITY-LISTING.md`:
   - Change status from `[~]` to `[x]`
   - Update Quick Stats section

## Verification Checklist

### Specification
- [ ] Overview clearly explains the problem and solution
- [ ] User stories cover all user types
- [ ] Data model is complete with types
- [ ] Business rules are explicit

### Scenarios and Seed Data
- [ ] scenarios.md and seed.json pass the checklists in feature-spec's references

### Cross-References
- [ ] Added to `${aiDir}/features/index.yaml` with `status: draft`
- [ ] References to dependent features are correct
