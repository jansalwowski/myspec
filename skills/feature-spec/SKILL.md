---
name: "feature-spec"
description: "Use when starting a new feature. Creates spec.md and dependencies.md in ${aiDir}/features/, optionally scenarios.md and seed.json (`scenarios` / `seed-data` arguments revisit an existing spec). Keywords: new feature, requirements, user stories, acceptance criteria, test scenarios, seed data. Do NOT use for tech design (feature-tech-spec)."
tags: [feature, specification, planning, documentation]
---

# Feature Spec

## Arguments

- `/myspec:feature-spec {feature}` — the full workflow below.
- `/myspec:feature-spec {feature} scenarios` or `… seed-data` — a revisit of an existing feature. Parse this before anything else: when the second argument is one of these, `${aiDir}/features/{feature}/spec.md` must already exist (if it does not, stop and say so — the full workflow creates it); skip to Step 6, do only the named part, and never re-create or rewrite spec.md, dependencies.md or the manifest entry. Then Step 7 for the new file only.
- `--review` / `--no-review` — answers Step 1's auto-review question in advance.

## Workflow

1. **Gather Information**
   - Ask the user about the feature concept
   - Identify dependencies from `${aiDir}/features/index.yaml`
   - Check for related existing features
   - Ask whether to review the spec as soon as it is written, in the same `AskUserQuestion` call as the concept questions when it has room (a call takes at most 4 questions; otherwise ask it in its own call), unless `--review` / `--no-review` already answered it. Not every spec needs a review before the user reads it, so the user decides per run:
     ```
     question: "Run the spec review automatically once the draft is written?"
     header:   "Auto-review"
     options:
       - "Yes, review before showing me (Recommended)" → Step 5 runs feature-spec-review in a subagent, you see the reviewed draft
       - "No, show me the draft first"                  → Step 5 presents the draft; review stays a separate step
     ```
     Under autopilot ([`_shared/autopilot.md`](../_shared/autopilot.md)) take the recommended option. When the request already says to review the draft before showing it, take "Yes". When the user only asked for the draft without questions, take "No" and say so in one line: they plan to read it first.

2. **Create Spec Document**
   Create `${aiDir}/features/{feature-name}/spec.md` with:

```yaml
---
title: "{Feature Title}"
status: draft
phase: 1
priority: P{0|1|2|3}
spec_version: 1
created: {TODAY}
last_updated: {TODAY}
---
```

Required sections:
- **Overview**: 2-3 sentence summary
- **Goals**: Bullet list of what this achieves
- **User Stories / Requirements**: Numbered, testable requirements
- **Acceptance Criteria**: Testable "done" conditions
- **Out of Scope**: What this does NOT cover
- **Open Questions**: Unresolved decisions

3. **Create Dependencies Document**
   Create `${aiDir}/features/{feature-name}/dependencies.md`:
   - Feature Dependencies (what this depends on)
   - Dependent Features (what depends on this)
   - External Dependencies (npm packages, APIs)
   - Rationale for non-obvious dependencies

4. **Update Feature Manifest**
   Add entry to `${aiDir}/features/index.yaml`:
```yaml
- name: {feature-name}
  title: "{Feature Title}"
  status: draft
  phase: 1
  priority: P{0|1|2|3}
  depends-on: [{dependencies}]
```

5. **Present for Review**
   - **Auto-review off:** show the created documents and ask for approval.
   - **Auto-review on:** invoke `/myspec:feature-spec-review {feature} --from-author` before showing anything. Its reviewer subagent gets only the file paths, never this conversation. Its gates replace this step's approval: the user sees the findings with `[auto-fix]` fixes applied, decides the `[requires confirmation]` fixes, and answers whether to mark the spec `approved`. Then continue here: Step 6 when the spec is now approved, otherwise Step 7, and the hand-off names the open findings to resolve before rerunning `/myspec:feature-spec-review`.

6. **Offer Scenarios and Seed Data** [OPTIONAL]
   Once the spec is approved, offer both; the user may take either, both or
   neither, and can come back later with the `scenarios` / `seed-data` argument
   (see Arguments). On the argument route, do only the named part, no offer.
   - `scenarios.md`: Gherkin scenarios, per [references/scenarios.md](references/scenarios.md)
   - `seed.json`: test data matching the model and the scenarios, per [references/seed-data.md](references/seed-data.md) (needs `scenarios.md`)

7. **Commit Decision**
   Prompt the user about committing the spec. **Why:** uncommitted spec files
   dangle on the current branch by the time `/myspec:feature-implement` runs.

   Detection (REQUIRED reference: [`skills/_shared/git-helpers.md`](../_shared/git-helpers.md)):
   - Resolve the default branch (main vs master)
   - Read current `HEAD` and working-tree cleanliness
   - Decide which option to mark `(Recommended)`

   Then call `AskUserQuestion` with:

   ```
   question: "The spec is uncommitted. Where should it go?"
   header:   "Commit spec"
   options:
     - "Commit to {HEAD}"           → stage spec.md, dependencies.md, index.yaml,
                                       plus scenarios.md / seed.json when written,
                                       on the current branch
     - "New branch feat/{name}"     → create feat/{name}, switch, then commit
     - "Leave uncommitted"          → skip; user will commit manually
   ```

   - Order options so the recommended one is first with `(Recommended)` appended.
   - Default commit message: `feat({name}): add spec and dependencies`
     — show the draft, accept-or-edit before committing.
   - If working tree has unrelated dirty changes: warn and stage only the spec
     files explicitly (no `git add -A`).
   - If user picks "New branch" and the branch already exists: offer checkout
     vs. a numeric suffix (`feat/{name}-2`).
   - On the argument route (spec already committed), the question names the
     file actually produced ("scenarios.md is uncommitted. Where should it
     go?"), the stage list is that file only, and the default message is
     `docs({name}): add scenarios` or `docs({name}): add seed data`.

## Rules
- Use kebab-case for feature directory name
- NO implementation details in spec (no file paths, class names)
- Use "must" for requirements, "may" for optional
- Ensure bidirectional dependency links are consistent

## Verification Checklist

- [ ] `${aiDir}/features/{feature}/spec.md` created with valid YAML frontmatter
- [ ] `status: draft` field present in frontmatter (`approved` only when the auto-review passed and the user said yes)
- [ ] Auto-review question asked or answered by argument (Step 1); when on, feature-spec-review ran with `--from-author`
- [ ] All required sections present: Overview, Goals, User Stories, Acceptance Criteria, Out of Scope, Open Questions
- [ ] `${aiDir}/features/{feature}/dependencies.md` created
- [ ] Entry added to `${aiDir}/features/index.yaml`
- [ ] No implementation details in spec (no file paths, class names, SQL, code)
- [ ] Run project documentation audit command if configured
- [ ] Scenarios and seed data offered (Step 6); any file written passes its reference checklist
- [ ] Commit decision presented to user (Step 7) and acted on; on the argument route it names and stages only the new file, and spec.md, dependencies.md and the manifest entry are untouched

## Integration

**Next** [REQUIRED — owns the draft → approved transition]: `/myspec:feature-spec-review` — validate spec before proceeding to technical design. When the auto-review already approved the spec, offer its next step instead: `/myspec:cross-spec-validation` (Recommended) or `/myspec:feature-tech-spec`
**Next (large features)** [OPTIONAL]: `/myspec:feature-decompose` — split into sub-features before feature-spec-review
