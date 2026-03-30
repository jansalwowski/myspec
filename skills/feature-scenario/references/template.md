# scenarios.md Template

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
