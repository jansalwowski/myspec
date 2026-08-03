# Idea Processing Instructions

> Guide for converting ideas from `${aiDir}/ideas/` into structured feature documentation in `${aiDir}/features/`.

---

## Prerequisites

Before processing any idea, read these documents:

1. `${aiDir}/features/index.yaml` - Feature manifest and status
2. `${aiDir}/INDEX.md` - Documentation map
3. `${aiDir}/ideas/PRIORITY-LISTING.md` - Current status and dependencies

---

## Workflow Steps

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
> Quality of the final documentation depends entirely on understanding gathered here.
> Ask questions, wait for answers, then proceed.

Use the question categories below to formulate 5-15 questions about the idea.

**Present questions to the user and WAIT for responses before proceeding.**

### Step 4: Create Feature Directory

After receiving answers to all questions, invoke `/myspec:feature-spec` to create:

```
${aiDir}/features/{feature-name}/
├── spec.md           (required)
├── dependencies.md   (required)
├── scenarios.md      (required)
└── seed/             (optional)
```

### Step 5: Write spec.md

Create the specification following the template in the Templates section below.

Include:
- Feature name with `[PLANNED]` status
- Overview paragraph
- User stories
- UI/UX requirements
- Data model
- Business rules
- Integration points with other features

### Step 6: Write scenarios.md

Document user flows and test scenarios:
- Happy path scenarios
- Edge cases
- Error states
- Given/When/Then format for testable scenarios

### Step 7: Update Feature Index

Add the new feature to `${aiDir}/features/index.yaml`.

### Step 8: Move to Processed

1. Move the original idea file to `${aiDir}/ideas/processed/`
2. Update `${aiDir}/ideas/PRIORITY-LISTING.md`:
   - Change status from `[~]` to `[x]`

---

## Question Categories

Use these categories to ensure comprehensive understanding before writing documentation.

### 1. Scope Questions

Define boundaries of the feature.

- What is explicitly IN scope?
- What is explicitly OUT of scope?
- Are there related features that should be separate?
- What's the MVP vs nice-to-have?
- Should this be one feature or split into multiple?

### 2. User Experience Questions

Understand how users interact with the feature.

- Who are the primary users? (anonymous, logged-in, admin)
- What triggers this feature? (button click, page load, scheduled)
- Where does this appear in the UI? (new page, modal, section)
- What feedback does the user receive? (success, error, loading states)
- Are there accessibility requirements?
- Should this work on mobile?

### 3. Data Model Questions

Clarify what data is stored and how.

- What entities need to be created?
- What fields does each entity have?
- What are the data types and constraints?
- Are there relationships to existing entities?
- What's required vs optional?
- Are there default values?
- What validation rules apply?

### 4. Technical Constraint Questions

Identify implementation boundaries.

- Are there performance requirements?
- What happens at scale? (1000s of items)
- Are there rate limits needed?
- What external services are involved?
- Are there caching requirements?
- What about offline/degraded mode?

### 5. Business Rule Questions

Understand the logic and policies.

- What permissions/roles are needed?
- Are there feature flags involved?
- What's the pricing model impact?
- Are there quotas or limits?
- What audit/logging is required?
- Are there compliance considerations?

### 6. Edge Case Questions

Anticipate unusual situations.

- What if input is empty/null?
- What if input is very large?
- What if multiple users act simultaneously?
- What if related data is deleted?
- What if external service fails?
- What happens with legacy data?

---

## Quality Checklist

Before marking an idea as processed, verify:

### Specification
- [ ] Feature name includes status tag `[PLANNED]`
- [ ] Overview clearly explains the problem and solution
- [ ] User stories cover all user types
- [ ] Data model is complete with types
- [ ] Business rules are explicit
- [ ] Integration points are documented

### Scenarios
- [ ] Happy path is fully documented
- [ ] At least 3 edge cases included
- [ ] Error states are covered
- [ ] Scenarios are testable (Given/When/Then)

### Cross-References
- [ ] Added to `${aiDir}/features/index.yaml`
- [ ] References to dependent features are correct
- [ ] No broken links

---

## Templates

### spec.md Template

```markdown
# Feature Name [PLANNED]

## Overview

One paragraph explaining what this feature does and why it exists.

## User Stories

### As a [user type]
- I want to [action]
- So that [benefit]

### As an admin
- I want to [action]
- So that [benefit]

## UI/UX

### [Component/Page Name]

**Location**: Where in the app this appears
**Trigger**: What causes this to display

| Element | Type | Behavior |
|---------|------|----------|
| ... | ... | ... |

## Data Model

### EntityName

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| id | UUID | Yes | auto | Primary key |
| ... | ... | ... | ... | ... |

### Relationships

- EntityA has many EntityB
- EntityB belongs to EntityA

## Business Rules

1. Rule one description
2. Rule two description

## Integration Points

- **Feature X**: How this feature interacts with X
- **Feature Y**: How this feature interacts with Y

## Out of Scope

- Thing explicitly not included
- Another thing not included

## Open Questions

- [ ] Question that needs answering later
```

### scenarios.md Template

```markdown
# Feature Name - Scenarios

## Happy Path

### Scenario: [Descriptive name]

**Given** preconditions
**When** user action
**Then** expected outcome

Steps:
1. User does X
2. System shows Y
3. User clicks Z
4. System responds with W

**Expected Result**: Final state description

## Edge Cases

### Scenario: [Edge case name]

**Given** preconditions
**When** unusual action
**Then** graceful handling

## Error States

### Scenario: [Error condition]

**Given** preconditions
**When** error trigger
**Then** error handling

**Error Message**: "User-facing error text"
**Recovery**: How user can recover
```

---

## Important Reminders

1. **Never skip questions** - Even "obvious" ideas have hidden complexity
2. **Wait for answers** - Don't proceed with assumptions
3. **Document decisions** - Note why choices were made
4. **Keep it concise** - AI agents will read these docs
5. **Cross-reference** - Link to related features
6. **Use status tags** - Always mark new features as `[PLANNED]`

---

## Troubleshooting

### Idea is too large
Split into multiple features. Create separate directories for each logical unit.

### Dependencies aren't ready
Mark as `[!]` blocked in PRIORITY-LISTING.md and process a different idea.

### Conflicting requirements
Document the conflict, ask for clarification, and note the decision made.

### Idea is unclear
Ask more questions. It's better to ask 20 questions than to document incorrect requirements.
