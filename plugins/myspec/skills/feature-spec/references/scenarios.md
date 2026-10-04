# Test Scenarios (`scenarios.md`)

Gherkin scenarios for a feature whose `spec.md` exists. Not for unit tests.

## Procedure

1. Read `${aiDir}/features/{feature}/spec.md`: every user story, acceptance criterion and business rule.
2. Create `${aiDir}/features/{feature}/scenarios.md` from the template below.
3. Cover every path:
   - **Happy path**: primary flow, alternative valid flows, success states
   - **Edge cases**: empty inputs, maximum values, concurrent actions, boundary conditions
   - **Error states**: validation failures, permission denied, not found, network errors, server errors
4. Check completeness. Each user story has a happy-path scenario, at least one edge case and its error scenarios; each business rule has a scenario for enforcement and one for violation handling.

## Template

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

## Scenario quality

A good scenario is specific and measurable:

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

A bad one has no observable steps or outcome ("User creates a guide and it works.").

## Checklist

- [ ] All user stories have scenarios
- [ ] All acceptance criteria are testable
- [ ] Edge cases identified and documented
- [ ] Error states with recovery paths
- [ ] Gherkin syntax is valid
- [ ] Scenarios are specific and measurable
