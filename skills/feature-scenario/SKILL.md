---
name: "feature-scenario"
description: "Use when creating test scenarios for a feature. Generates Gherkin-format scenarios.md with happy paths, edge cases, error states. Requires spec.md. Do NOT use for unit tests."
tags: [testing, scenarios, gherkin, specification]
---

# Generate Test Scenarios

Create comprehensive test scenarios for a feature in Gherkin format.

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

Create `${aiDir}/features/{feature}/scenarios.md` using the document skeleton in [references/template.md](references/template.md) (sections: Happy Path, Edge Cases, Error States, E2E Test Specifications).

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
### Scenario: User creates guide with valid data

**Given** user is logged in as contributor
**And** user is on guide creation page
**When** user enters title "Europe Guide"
**And** user enters slug "europe"
**And** user clicks "Create"
**Then** guide is created with status "draft"
**And** user is redirected to guide edit page
**And** success toast shows "Guide created"
```

### Bad Scenario
```markdown
### Scenario: Create guide
User creates a guide and it works.
```

## Checklist

- [ ] All user stories have scenarios
- [ ] All acceptance criteria are testable
- [ ] Edge cases identified and documented
- [ ] Error states with recovery paths
- [ ] Gherkin syntax is valid
- [ ] Scenarios are specific and measurable
