---
description: "Use when converting an approved idea to feature documentation. Creates spec.md, scenarios.md, seed.json in features directory. Requires idea in PRIORITY-LISTING.md. Do NOT use for intake."
tags: [ideas, feature, specification, processing]
---

# Idea Process

Convert an idea from the ideas directory into structured feature documentation.

## Path Resolution
1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Prerequisites

Before processing any idea, read these documents:

1. `${aiDir}/features/README.md` - Feature documentation structure
2. `${aiDir}/ideas/PRIORITY-LISTING.md` - Current status and dependencies
3. Read project overview documentation if available

## Instructions

### Step 1: Select Idea from Listing

1. Open `${aiDir}/ideas/PRIORITY-LISTING.md`
2. Find the highest priority idea with status `[ ]` (not started)
3. Verify dependencies are satisfied (all dependencies should be `[x]` or existing features)
4. Mark the idea as `[~]` (in progress)

### Step 2: Initial Analysis

1. Read the idea file completely
2. Identify the core problem being solved
3. Note any existing features this relates to
4. List unknowns and ambiguities

### Step 3: Ask Clarifying Questions

> **CRITICAL: NEVER SKIP THIS STEP**
>
> Even if the idea seems clear, there are always details that need clarification.

Use these question categories:

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

**Present questions to the user and WAIT for responses before proceeding.**

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

Use the template from `${aiDir}/ideas/PROCESSING-INSTRUCTIONS.md`:

```markdown
# Feature Name [PLANNED]

## Overview
One paragraph explaining what this feature does and why.

## User Stories
### As a [user type]
- I want to [action]
- So that [benefit]

## UI/UX
### [Component/Page Name]
**Location**: Where in the app
**Trigger**: What causes this to display

## Data Model
### EntityName
| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|

## Business Rules
1. Rule one description
2. Rule two description

## Integration Points
- **Feature X**: How this interacts

## Out of Scope
- Thing not included
```

### Step 6: Write dependencies.md

```markdown
# {Feature Name} -- Dependencies

## Feature Dependencies
- List of features this depends on

## Dependent Features
- Features that depend on this

## External Dependencies
- Packages, APIs, etc.
```

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

## Quality Checklist

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
