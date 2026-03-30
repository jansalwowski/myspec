# spec-review Examples

## Good Spec Characteristics

### ✅ Clear, Measurable Acceptance Criteria

```markdown
## Acceptance Criteria

- [ ] AC-001: User can create a guide with title (1-255 chars) and slug (validated format)
- [ ] AC-002: System displays error "Title required" when title is empty on submit
- [ ] AC-003: Guide appears in user's guide list within 2 seconds of creation
- [ ] AC-004: Guide status is set to "draft" on creation
```

**Why good**: Specific constraints, measurable outcomes, clear error messages, defined timings.

### ✅ Explicit Scope Boundaries

```markdown
## Out of Scope

- Guide collaboration (multiple authors) - **blocked by**: user-permissions feature
- Real-time editing - **deferred to**: v2.0 (performance considerations)
- Guide templates - **separate feature**: guide-templates
- Version history - **separate feature**: guide-versioning
```

**Why good**: Specific exclusions with reasons, links to blocking/related features.

### ✅ Complete User Stories

```markdown
## User Stories

**US-001: Create Guide**
- As a logged-in user
- I want to create a new guide with a title and optional description
- So that I can start organizing location information
- Preconditions: User is authenticated, email verified
- Postconditions: Guide exists in database with status=draft, user is guide owner

**US-002: View My Guides**
- As a logged-in user
- I want to see a list of my created guides
- So that I can find and edit my work
- Preconditions: User is authenticated
- Postconditions: User sees all guides where created_by = user.id, sorted by updated_at DESC
```

**Why good**: Clear actor, goal, benefit, preconditions, and postconditions.

---

## Bad Spec Characteristics

### ❌ Vague Acceptance Criteria

```markdown
## Acceptance Criteria

- [ ] User can create guides
- [ ] Guides should be validated
- [ ] System might show errors if something goes wrong
- [ ] Performance should be good
```

**Problems**:
- "can create guides" - what fields? what validation?
- "should be validated" - what rules? when?
- "might show errors" - when? which errors?
- "should be good" - unmeasurable

### ❌ Generic Scope

```markdown
## Out of Scope

- Advanced features
- Future enhancements
- Nice-to-have improvements
```

**Problems**: No specific features named, no reasoning, can't validate scope creep.

### ❌ Incomplete User Stories

```markdown
## User Stories

- Users want to create guides
- Users need to edit guides
- Users should be able to delete guides
```

**Problems**: No actor definition, no benefit stated, no preconditions/postconditions, no acceptance criteria linkage.

### ❌ Hidden Assumptions

```markdown
## Requirements

REQ-001: Guide creation saves to database
REQ-002: User can edit guide title
```

**Problems**:
- Assumes user is authenticated (not stated)
- Assumes user owns the guide (not validated)
- Assumes database schema exists (not in dependencies)

### ❌ Scope Creep

```markdown
## Requirements

REQ-001: Create guides
REQ-002: Edit guides
REQ-003: Real-time collaboration
REQ-004: AI-powered suggestions
REQ-005: Export to PDF, DOCX, Markdown
REQ-006: Integration with Google Drive, Dropbox, OneDrive
```

**Problem**: Started with CRUD, ballooned to 5 integrations. No "Out of Scope" section to contain it.

---

## Common Review Findings

### Finding: Contradiction

**Issue**: REQ-003 requires admin approval, but AC-007 allows auto-approval.

**Fix**:
```diff
- REQ-003: All submissions must be approved by an admin
+ REQ-003: All submissions must be approved by an admin, except for verified users (see REQ-012)
+ REQ-012: Verified users (account age > 30 days AND reputation > 100) have submissions auto-approved
```

### Finding: Missing Dependency

**Issue**: Spec mentions "notification system" but it's not in dependencies.md.

**Fix**: Add to dependencies.md:
```yaml
depends_on:
  - name: notifications
    reason: Send email when guide is approved/rejected
    required_capabilities:
      - Email delivery
      - Template rendering
```

### Finding: Vague Language

**Issue**: "User may receive email" - unclear when this happens.

**Fix**:
```diff
- User may receive email when guide is approved
+ User receives email within 5 minutes when guide status changes to "approved"
```

### Finding: Untestable Criteria

**Issue**: "System should have good performance" - unmeasurable.

**Fix**:
```diff
- [ ] System should have good performance
+ [ ] Guide list loads in < 200ms for users with < 100 guides
+ [ ] Guide creation completes in < 500ms (p95)
```

### Finding: YAGNI Violation

**Issue**: Requirement for "extensible plugin system for future integrations".

**Fix**:
```diff
- REQ-008: Implement extensible plugin system for future integrations
(Move to Out of Scope)

## Out of Scope
+ Plugin system - No current requirement for third-party extensions. Revisit in v2.0 if integration patterns emerge.
```

---

## Workflow Integration

```
/feature-spec guide-creation
→ spec.md created
→ /spec-review guide-creation
→ findings: 3 Critical, 5 High, 2 Medium
→ apply fixes
→ /spec-review guide-creation (re-run)
→ findings: 0 Critical, 0 High, 1 Medium
→ /tech-spec guide-creation (proceed to implementation)
```

The skill ensures spec.md is solid **before** tech-spec starts, preventing implementation churn from unclear requirements.
