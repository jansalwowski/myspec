---
name: "idea-process"
description: "Use when converting, promoting, or graduating an approved idea to feature documentation. Creates spec.md, dependencies.md, scenarios.md, seed.json in ${aiDir}/features/. Requires idea listed in PRIORITY-LISTING.md with satisfied dependencies. Do NOT use for idea intake or existing feature modifications."
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

Present the questions, then wait for responses before proceeding — answers shape the spec sections in Steps 5–8.

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

### Step 7: Write scenarios.md

Document user flows:
- Happy path scenarios
- Edge cases
- Error states
- Given/When/Then format

### Step 8: Write seed.json

Create test data that:
- Matches the data model
- Covers happy path cases
- Includes edge cases

### Step 9: Update Feature Index

Add the new feature to `${aiDir}/features/index.yaml`.

### Step 10: Move to Processed

1. Move the original idea file to `${aiDir}/ideas/processed/`
2. Update `${aiDir}/ideas/PRIORITY-LISTING.md`:
   - Change status from `[~]` to `[x]`
   - Update Quick Stats section

## Verification Checklist

### Specification
- [ ] Feature name includes status tag `[PLANNED]`
- [ ] Overview clearly explains the problem and solution
- [ ] User stories cover all user types
- [ ] Data model is complete with types
- [ ] Business rules are explicit

### Scenarios
- [ ] Happy path is fully documented
- [ ] At least 3 edge cases included
- [ ] Error states are covered

### Seed Data
- [ ] Valid JSON syntax
- [ ] Matches data model exactly
- [ ] Includes realistic values

### Cross-References
- [ ] Added to `${aiDir}/features/index.yaml`
- [ ] References to dependent features are correct
