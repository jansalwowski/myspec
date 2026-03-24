---
description: "Use when creating test scenarios for a feature. Generates Gherkin-format scenarios.md with happy paths, edge cases, error states. Requires approved spec.md. Do NOT use for unit tests."
---

# Generate Test Scenarios

Create comprehensive test scenarios for a feature in Gherkin format.

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Prerequisites

- `${aiDir}/features/{feature}/spec.md` exists
- Feature requirements are clear

## Instructions

### Step 1: Read Feature Spec

1. Read `${aiDir}/features/{feature}/spec.md`
2. Identify all user stories
3. Extract acceptance criteria
4. Note business rules

### Step 2: Create scenarios.md

Create `${aiDir}/features/{feature}/scenarios.md`:

```markdown
# {Feature Name} - Scenarios

## Happy Path

### Scenario: [Primary user flow]

**Given** preconditions
**When** user action
**Then** expected outcome

Steps:
1. User does X
2. System shows Y
3. User clicks Z
4. System responds with W

**Expected Result**: Final state description

---

## Edge Cases

### Scenario: [Edge case name]

**Given** preconditions
**When** unusual action
**Then** graceful handling

---

## Error States

### Scenario: [Error condition]

**Given** preconditions
**When** error trigger
**Then** error handling

**Error Message**: "User-facing error text"
**Recovery**: How user can recover

---

## E2E Test Specifications

### Test: [test-name]

\`\`\`gherkin
Feature: {Feature name}
  Scenario: {Test scenario}
    Given precondition
    When action
    Then assertion
\`\`\`
```

### Step 3: Cover All Paths

Ensure scenarios cover:

**Happy Path**
- Primary user flow
- Alternative valid flows
- Success states

**Edge Cases**
- Empty inputs
- Maximum values
- Concurrent actions
- Boundary conditions

**Error States**
- Validation failures
- Permission denied
- Not found
- Network errors
- Server errors

### Step 4: Validate Completeness

For each user story in spec.md:
- [ ] Happy path scenario exists
- [ ] At least one edge case
- [ ] Error scenarios documented

For each business rule:
- [ ] Scenario verifies rule enforcement
- [ ] Scenario verifies rule violation handling

## Scenario Quality Guidelines

### Good Scenario
```markdown
### Scenario: User creates record with valid data

**Given** user is logged in as contributor
**And** user is on record creation page
**When** user enters title "Example Record"
**And** user enters slug "example"
**And** user clicks "Create"
**Then** record is created with status "draft"
**And** user is redirected to record edit page
**And** success toast shows "Record created"
```

### Bad Scenario
```markdown
### Scenario: Create record
User creates a record and it works.
```

## Checklist

- [ ] All user stories have scenarios
- [ ] All acceptance criteria are testable
- [ ] Edge cases identified and documented
- [ ] Error states with recovery paths
- [ ] Gherkin syntax is valid
- [ ] Scenarios are specific and measurable
