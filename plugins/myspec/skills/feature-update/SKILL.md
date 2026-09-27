---
name: "feature-update"
description: "Use when an already-implemented feature needs changed requirements — edits spec.md and tech-spec.md in place instead of recreating them. Keywords: modify feature, change feature, extend feature, spec_version bump. Do NOT use for new features (feature-spec)."
tags: [feature, specification, modification, workflow]
---

# Feature Update

Modify an existing feature's spec and technical design to reflect new or changed requirements.

**Core principle:** Edit, don't recreate. Only the affected sections change — existing content stays intact. Within an affected section, replace what the change supersedes rather than annotating it: tech-spec.md stays current-state, and the delta goes to `CHANGELOG.md`.

**Announce at start:** "I'm using the feature-update skill to modify the {feature} feature."

## Prerequisites

- `${aiDir}/features/{feature}/spec.md` must exist
- `${aiDir}/features/{feature}/tech-spec.md` must exist

## Workflow

### Step 1: Read Current State

Load all existing context:
- Read `${aiDir}/features/{feature}/spec.md` — note current `spec_version`, requirements, acceptance criteria
- Read `${aiDir}/features/{feature}/tech-spec.md` — note current `based_on_spec_version`, implementation steps, file inventory
- If `${aiDir}/features/{feature}/CHANGELOG.md` exists, read it — understand what was previously implemented
- If `${aiDir}/features/{feature}/plans/` exists, check the most recent archived plan — understand what the last iteration built

### Step 2: Understand the Change

Ask the user what is changing. Gather:
- What new behavior or requirement is being added?
- What existing behavior is being changed or removed?
- Are there constraints (performance, compatibility, scope)?

### Step 3: Update `spec.md`

Edit only the sections affected by the change. Do not touch unrelated sections.

Changes to make:
- **Add** new requirements to the User Stories / Requirements section
- **Modify** existing requirements if behavior is changing
- **Remove** requirements if behavior is being dropped (or mark as out of scope)
- **Update** Acceptance Criteria to match the new expected behavior
- **Update** Out of Scope if relevant
- **Increment** `spec_version` by 1 in the frontmatter
- **Update** `last_updated` to today
- **Update** `status` back to `draft` if previously `approved` (change requires re-approval)

### Step 4: Update `tech-spec.md`

Edit only the sections affected by the change. tech-spec.md describes the design in force, so a superseded decision, step, or passage is rewritten or deleted — never kept with a "superseded" note. Stacked versions are how a tech-spec grows into a log that contradicts the code.

Changes to make:
- **Update** Architecture section if the approach changes
- **Replace** Implementation Steps with the numbered outline for this version's work only, no checkboxes. The previous outline is preserved in the archived plan under `plans/`, and `feature-plan` maps every listed step to a task, so shipped steps left in place get planned again
- **Update** Key Interfaces / Types for new or changed types
- **Update** Database Changes if schema changes are needed
- **Update** API Schema if the API surface changes
- **Update** File Inventory — add new files, update actions on changed files, mark files this change removes as `Delete` (`feature-complete` drops the row once the file is gone)
- **Replace** a Decisions entry the change overturns with the decision now in force; **add** a new entry (ADR format) for a new architectural choice
- **Update** `based_on_spec_version` to match the new `spec_version` from spec.md
- **Update** `last_updated` to today
- **Update** `status` to `draft` (requires review before implementation)

Record the delta in `${aiDir}/features/{feature}/CHANGELOG.md` — it is where the replaced content stays findable. If the file is missing, create it with the header `feature-complete` uses (`| Date | Plan | Summary | Status |`). Prepend:
`| {date} | spec v{new spec_version} | {requirements added/changed/removed; decisions and steps replaced, naming what they replaced} | updated |`

### Step 5: Present Diff Summary

Do NOT show the full documents. Show only:
- Which sections in spec.md changed, and what changed in them (1-2 lines each)
- Which sections in tech-spec.md changed, and what changed in them (1-2 lines each)
- The new `spec_version` value
- The `CHANGELOG.md` row

Call `AskUserQuestion` so the choice is selectable:

```
question: "Do the proposed changes look correct?"
header:   "Confirm update"
options:
  - "Apply"   → write the changes and continue to Step 6
  - "Revise"  → describe what to adjust
  - "Cancel"  → discard the proposed changes
```

### Step 6: Re-approve & Hand Off

Step 3 reset both docs to `status: draft`, and `/myspec:feature-plan`'s prerequisites require an approved spec — routing there without re-approval deadlocks. Resolve status first:

- **Small update** (wording, clarified criteria, no new scope): ask "Changes are minor — re-approve spec.md and tech-spec.md directly?" On yes, set `status: approved` in both.
- **Substantive update** (new requirements, changed scope or interfaces): recommend `/myspec:feature-spec-review` (and `/myspec:feature-tech-spec-review` if tech-spec changed) — they own the `draft → approved` transition.

Then call `AskUserQuestion`:

```
question: "Update applied. What's next?"
header:   "Next step"
options:
  - "/myspec:cross-spec-validation"  → check updated spec against related specs for contradictions or broken assumptions
  - "/myspec:feature-spec-review"    → re-review the updated spec (required for substantive changes before planning)
  - "/myspec:feature-plan"           → straight to implementation planning (requires re-approved docs)
```

Mark `/myspec:cross-spec-validation` as `(Recommended)` — updates often break other specs.
Wait for the user's choice before proceeding.

Note: `/myspec:feature-plan` will create a new `implementation-plan.md`. The previous plan (if any) has already been archived to `plans/` by `/myspec:feature-complete`. If there is still an active `implementation-plan.md` from an incomplete previous run, alert the user before proceeding.

## Rules

- Never rewrite sections that aren't affected by the change
- Replace superseded content in tech-spec.md; never annotate it "superseded" and keep both
- Never reset requirements that are still valid
- Always increment `spec_version` — even for small changes
- Keep `based_on_spec_version` in sync with `spec_version` after every update
- No implementation details in spec.md (no file paths, class names, SQL)

## Verification Checklist

- [ ] `spec_version` incremented in spec.md frontmatter
- [ ] `based_on_spec_version` in tech-spec.md matches new `spec_version`
- [ ] `last_updated` updated in both files
- [ ] `status: draft` set in both files at Step 3; re-approval resolved in Step 6 (direct for small updates, via review skills for substantive ones)
- [ ] Only affected sections were modified (no unrelated changes)
- [ ] New acceptance criteria added for any new requirements
- [ ] File Inventory in tech-spec.md updated for new/changed files
- [ ] Implementation Steps holds only this version's work; no `superseded` markers or checkboxes left in tech-spec.md
- [ ] `CHANGELOG.md` has an `updated` row naming what was replaced
- [ ] Run project documentation audit command if configured

## Integration

**Replaces:** Manually editing spec.md and tech-spec.md for existing feature modifications
**Suggests:** `/myspec:cross-spec-validation` — validate updated spec against related specs *(user chooses)*
**Next:** `/myspec:feature-plan` — create execution-ready implementation plan for the changes
**Related:** `/myspec:feature-spec-review`, `/myspec:feature-tech-spec-review` — optionally review updated docs before planning
