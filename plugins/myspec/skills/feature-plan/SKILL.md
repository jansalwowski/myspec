---
name: feature-plan
tags: [feature-workflow, planning, implementation, parallel]
description: >
  Use when a feature in ${aiDir}/features/ has approved spec.md and tech-spec.md and needs an
  execution-ready implementation plan with parallel task groups and milestone checkpoints.
  Do NOT use for features without an approved tech-spec, projects outside ${aiDir}/features/
  (use writing-plans instead), or plans already in progress.
---

# Feature Plan

**Announce at start:** "I'm using the feature-plan skill to create the implementation plan for {feature}."

## When to Use

Check these gates in order:

1. **Have `tech-spec.md`?** → No: run `/myspec:feature-tech-spec` first. Stop.
2. **Tech-spec approved (or user confirms draft)?** → No: get approval first. Stop.
3. **Feature in `${aiDir}/features/`?** → No: create a spec first with `/myspec:feature-spec`. Stop.

All gates pass → proceed to Workflow Step 1.

## Prerequisites

- `${aiDir}/features/{feature}/spec.md` exists with `status: approved`
- `${aiDir}/features/{feature}/tech-spec.md` exists with `status: approved` or `status: draft` (user confirms ready)
- For sub-features: `${aiDir}/features/{parent}/{subfeature}/tech-spec.md`

## Workflow

### Step 1: Read Context

1. Read `${aiDir}/features/{feature}/tech-spec.md` — note implementation steps, file inventory, interfaces
2. Read `${aiDir}/features/{feature}/spec.md` — note acceptance criteria, edge cases
3. Read existing code referenced in tech-spec (patterns to follow, files to modify)

### Step 2: Build Dependency Graph

For each implementation step in the tech-spec:
1. List files it creates or modifies
2. List which other steps it depends on (shared types, imports, config)
3. Mark steps that have no dependencies on each other as **parallelizable**

**Parallelism rules:**
- Two tasks are parallel-safe if they create/modify completely disjoint file sets
- A task that creates a shared type/config is a **barrier** — all tasks depending on it must wait
- Tasks modifying the same file are NEVER parallel
- When in doubt, make it sequential

**Milestone ordering rule:**
- Group tasks into **milestones** — each milestone is a vertical slice delivering one coherent piece of functionality.
- Classify every task within a milestone as `backend` or `frontend`:
  - Classify every task within a milestone by project layer (e.g., backend/frontend, server/client, data/presentation — use the project's own conventions).
- If the project has a layered architecture, order lower-level layers (data, services, APIs) before higher-level layers (UI, presentation) within each milestone.
- Across milestones: Milestone 2's backend may follow Milestone 1's frontend — that is the whole point.
- If a feature is small enough to fit in a single milestone, use one milestone. Do not force multiple milestones artificially.

### Step 3: Expand to Execution Tasks

Convert each tech-spec implementation step into a full task using the format in [references/plan-templates.md](references/plan-templates.md).

**What the tech-spec provides:** High-level step description, file inventory, interfaces
**What the plan adds:** Exact TDD steps, test code, run commands, commit messages, parallel group tags

### Step 4: Review Loop (large plans only)

For plans with **10+ tasks or 3+ milestones**, review in chunks before finalizing:

1. After completing each milestone's tasks, self-review that chunk:
   - Every tech-spec step has a corresponding task
   - Parallel groups have zero file overlap
   - TDD steps have run commands
   - No scope creep beyond tech-spec
2. If issues found: fix and re-review that chunk
3. If review loop exceeds 3 iterations on one chunk, present issues to user for guidance

Skip this step for smaller plans (single milestone, < 10 tasks).

### Step 5: Save Plan

Save to the path shown in [## Plan Document Format](#plan-document-format).

### Step 6: Present and Hand Off

Present the plan. On approval, hand off to `/myspec:feature-implement`.

### Step 7: Commit Decision (BLOCKING before feature-implement)

The plan must be committed before `/myspec:feature-implement` runs. Otherwise
the spec + plan files dangle on the current branch and either confuse worktree
creation or get left behind when implement spawns its own worktree.

Detection (REQUIRED reference: [`skills/_shared/git-helpers.md`](../_shared/git-helpers.md)):
- Resolve the default branch (main vs master)
- Read current `HEAD` and working-tree cleanliness
- Decide which option to mark `(Recommended)`

Call `AskUserQuestion` with:

```
question: "Plan is ready. Commit before /feature-implement to avoid dangling files."
header:   "Commit plan"
options:
  - "Commit to {HEAD}"           → commit implementation-plan.md (+ any updated
                                    spec/tech-spec) on the current branch
  - "New branch feat/{name}"     → only when HEAD is the default branch;
                                    create feat/{name}, switch, commit
```

- Order options so the recommended one is first with `(Recommended)` appended.
- "Leave uncommitted" is **not** offered — it is the failure mode this prompt
  exists to prevent. If the user genuinely needs it, they can use the
  AskUserQuestion "Other" escape hatch.
- Default commit message: `feat({name}): add implementation plan` (or
  `feat({name}): add spec, tech-spec, and implementation plan` if those files
  are also uncommitted in the same change). Show, accept-or-edit, commit.
- Stage only the feature's files (no `git add -A`).

## Plan Document Format

Save to `${aiDir}/features/{feature}/implementation-plan.md`.
For sub-features: `${aiDir}/features/{parent}/{subfeature}/implementation-plan.md`.

For the full header, execution order table, task, and barrier templates, see [references/plan-templates.md](references/plan-templates.md).

## Parallel Group Detection

When analyzing tech-spec implementation steps, look for these patterns:

**Likely parallel:**
- Multiple extractors/parsers for different data types (each reads different source, writes different output)
- Independent UI components that don't share state
- Backend services for unrelated entities
- Test suites for independent modules

**Likely sequential (barriers):**
- Shared config/types that multiple tasks import
- Database migrations (must run in order)
- Pipeline orchestrators that call other modules
- Integration tests that depend on multiple components

**Tag format:** `[parallel:descriptiveName]` — the name groups related parallel tasks.

## Milestone Design Guidelines

Each milestone should be:

**Self-contained:** After completing Milestone 1, the branch should be in a working (if incomplete) state.

**Vertically sliced:** Each milestone includes its own backend, frontend, and tests. Do not create an "all backend" milestone followed by an "all frontend" milestone.

**Right-sized:** Target 3-7 phases and 3-10 tasks. If a milestone exceeds 10 tasks, consider splitting it.

**Ordered by dependency:** Milestone 2 depends on Milestone 1 in most cases.

**Examples of good milestone boundaries:**
- Milestone 1: Core CRUD (schema + service + basic UI + tests)
- Milestone 2: Search & filtering (search service + search UI + tests)
- Milestone 3: Bulk operations (bulk service + bulk UI + tests)

**Single-milestone features:** Features with fewer than ~8 tasks should use a single milestone. The checkpoint still applies at the end.

## Scope Check

Before expanding tasks, verify scope:
- If the tech-spec covers multiple independent subsystems, suggest breaking it into separate sub-features — each with its own plan. Each plan should produce working, testable software independently.
- Use `/myspec:feature-decompose` if the feature hasn't been split yet.

## File Structure Principles

Before assigning files to tasks:
- Each file should have one clear responsibility
- Files that change together should live together (split by responsibility, not technical layer)
- Prefer smaller, focused files over large files that do too much
- In existing codebases, follow established patterns — don't unilaterally restructure

## Task Expansion Rules

1. **Exact file paths** — from tech-spec file inventory
2. **Complete code** — not "add validation", but the actual validation code
3. **TDD sequence** — write test → run (fail) → implement → run (pass) → commit
4. **Run commands** — exact verification commands with expected output (from `.claude/verification.json`)
5. **Commit messages** — conventional commits: `feat({feature}): description`
6. **Context for subagents** — each task must be self-contained; reference tech-spec interfaces inline
7. **No duplication** — reference tech-spec for architecture/decisions, don't copy them

## Integration

**Called by:** `/myspec:feature-tech-spec` OPTIONAL (after tech-spec is approved)
**Next:** `/myspec:feature-implement` — REQUIRED: hand off after plan is approved

## Handoff to feature-implement

When handing off to `/myspec:feature-implement`:

**Sequential tasks:** Standard flow — one implementer subagent at a time.

**Parallel groups:** Controller dispatches multiple implementer subagents simultaneously, each with `isolation: "worktree"`. Each gets:
- Its task text (self-contained)
- Shared context (interfaces from tech-spec, config from barrier task)
- Constraint: do not modify files outside your task's file list

**After parallel group completes (phase boundary):**
- All subagents report back
- Merge barrier: integrate worktrees, run verification commands
- Phase review: single reviewer checks spec compliance, quality, tests, and docs for all tasks
- Proceed to next phase

**Model selection for parallel tasks:**
- Most parallel tasks are mechanical (isolated, clear spec) → use fast model
- Barrier/merge tasks need integration judgment → use standard model

**Milestone checkpoints:** After each milestone, `feature-implement` pauses and asks the user:
- `continue` — proceed to next milestone in the same session
- `stop` — commit all changes, exit (resume with `/myspec:feature-implement` later)
- `fresh` — commit all changes, exit with instructions to spawn a fresh agent

**Task status in plan file** (managed by `feature-implement`, not by the author):
- `[ ]` — todo (all tasks start as todo when the plan is generated)
- `[~]` — in progress (set when agent starts dispatching a task)
- `[x]` — done (set after task passes phase review)

## Verification Checklist

Before presenting the plan:

- [ ] Every tech-spec implementation step has a corresponding task
- [ ] Every task has exact file paths matching tech-spec file inventory
- [ ] Every task has TDD steps with run commands
- [ ] Parallel groups have zero file overlap (check file lists)
- [ ] Barriers exist after every parallel group
- [ ] Execution order table matches task dependencies
- [ ] All acceptance criteria from spec.md are covered by at least one task
- [ ] Tasks reference tech-spec interfaces (not duplicated inline unless needed for subagent context)
- [ ] Within each milestone, lower-level layers (data, services) precede higher-level layers (UI, presentation) per project conventions
- [ ] Phase numbers are globally unique across all milestones
- [ ] Cross-milestone dependencies use `Milestone N` in the Depends On column (not individual phase numbers from other milestones)
- [ ] Each milestone is a coherent vertical slice
- [ ] Commit decision presented to user (Step 7); plan committed before handoff

## Red Flags

**Never:**
- Create tasks for work not in the tech-spec (scope creep)
- Mark tasks as parallel when they share files
- Skip the barrier/merge step after parallel groups
- Duplicate tech-spec architecture in the plan (reference it)
- Expand into more than ~20 tasks (if tech-spec has more steps, group related ones)
