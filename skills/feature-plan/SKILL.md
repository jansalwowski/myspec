---
name: feature-plan
tags: [feature, planning, implementation, parallel]
description: "Use when a feature has an approved spec.md and tech-spec.md and needs an execution-ready plan with parallel task groups and milestone checkpoints. Do NOT use without an approved tech-spec, or for a plan already in progress."
---

# Feature Plan

**Announce at start:** "I'm using the feature-plan skill to create the implementation plan for {feature}."

**Autopilot:** when the user opted in, answer this skill's gates per [`_shared/autopilot.md`](../_shared/autopilot.md).

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
2. Read `${aiDir}/features/{feature}/spec.md` — note requirement IDs, acceptance criteria, edge cases
3. **Sync the base**, so snippets match the code implementers will see. `$INTEGRATION` is the branch feature work merges into: the topology file's `branches.integration`, else the default branch ([`_shared/git-helpers.md`](../_shared/git-helpers.md)). Set `BASE=origin/$INTEGRATION` and run `git fetch origin "$INTEGRATION"` (no remote configured: `BASE=$INTEGRATION`, skip the fetch; fetch exits non-zero: stop and report). Then `git merge-base --is-ancestor "$BASE" HEAD`:
   - exit 0 — HEAD already contains it
   - exit 1 — HEAD lags: `git merge --no-edit "$BASE"`; if the merge exits non-zero, `git merge --abort` and stop for the user
   - any other exit (bad ref) — stop and report; never plan against an unverified base

   After the sync, record `git rev-parse HEAD` (full 40-char SHA) as the plan header's `planned_against`: it is the tree Step 4 reads snippets from, so a branch's own earlier commits are not later mistaken for drift. `feature-implement` warns when a `Modify:` file changed after it.
4. Read existing code referenced in tech-spec (patterns to follow, files to modify) from the synced tree

While reading, collect every project-wide exact value (version floors, size/perf limits, naming rules, invariants) — these become the plan's Global Constraints section in Step 3.

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
- Group tasks in parallel only when each is large enough to amortise a worktree merge and review; small tasks run faster in sequence

**Phase grouping rule:** every phase pays a full barrier suite and a phase review, however small it is. Grouping is the default: put consecutive sequential tasks in one phase when each is small (one module) or they touch disjoint layers. Start a new phase only after a task that publishes a contract later tasks are written against — an API response shape, an interface another layer consumes — because a rejected contract means redoing every consumer. A dependency inside the phase (a service over the migration beside it, a component using the hook beside it) does not split it: one rejection redoes one small neighbor.

**Milestone ordering rule:**
- Group tasks into **milestones** — each milestone is a vertical slice delivering one coherent piece of functionality.
- Classify every task within a milestone as `backend` or `frontend`:
  - Classify every task within a milestone by project layer (e.g., backend/frontend, server/client, data/presentation — use the project's own conventions).
- If the project has a layered architecture, order lower-level layers (data, services, APIs) before higher-level layers (UI, presentation) within each milestone.
- Across milestones: Milestone 2's backend may follow Milestone 1's frontend — that is the whole point.
- If a feature is small enough to fit in a single milestone, use one milestone. Do not force multiple milestones artificially.

### Step 3: Expand to Execution Tasks

**REQUIRED:** read [references/plan-templates.md](references/plan-templates.md) before writing any task — it carries the front-matter, Execution Order, task, and barrier templates. Convert each tech-spec implementation step into a full task using that format.

**What the tech-spec provides:** High-level step description, file inventory, interfaces
**What the plan adds:** Exact TDD steps, test code, the phase-review verification command, commit messages, parallel group tags

**Task right-sizing (the step → task mapping is not 1:1):**
A task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's gate. Fold setup, configuration, scaffolding, and docs steps into the task whose deliverable needs them; split only where a reviewer could meaningfully reject one task while approving its neighbor. The inverse holds too: several trivial same-shape changes (rename sweeps, config plumbing) are ONE task listing every file + change, not N micro-tasks — N reviewer gates on one mechanical sweep is overhead, not protection.

**Prototype before prescribing (REQUIRED for algorithms and relied-on library calls):**
A call the plan never ran reaches implementers as a mandate, and its defect surfaces a fix loop later. When a task's Step 2 holds an algorithm or a third-party call whose behavior it relies on, run that code first in a scratch directory outside the tree on realistic inputs (the spec's edge cases, real data shapes), and put the command and observed result on the task's `**Prototype:**` line. For a new module, run the planned test against the planned code once: it fails without Step 2 and passes with it. A result that contradicts the tech-spec is a tech-spec defect: say so and stop.

**Global Constraints (REQUIRED, once per plan):**
Populate the plan's `## Global Constraints` section with the project-wide exacts collected in Step 1 — version floors, size/perf limits, naming rules, invariants — copied verbatim from `spec.md` / `tech-spec.md` with source refs. Every task's requirements implicitly include this section; per-task text must not re-derive or paraphrase these values — re-derivation is how they drift.

**Spec contract — verbatim quotes (REQUIRED per task):**
For every task, populate the `**Spec contract:**` block with verbatim quotes from `spec.md` and/or `tech-spec.md` covering this task's behavior. Paste the sentence; do NOT paraphrase. The implementer subagent does NOT read `spec.md` or `tech-spec.md` — it receives the task text and nothing else. Any requirement that does not make the spec → task translation is invisible to it. If you find yourself rewording spec language, the original wording IS the contract — quote it. If a task has no spec/tech-spec passage that constrains it, ask whether the task should exist. Quote sentences, not sections: a longer contract several tasks share (a schema, an API shape) is cited by path and heading — `tech-spec.md` → `### API Schema` — once per task, and `feature-implement` pastes it into each dispatch; re-pasting it into every task is how plans pass a thousand lines.

**Touch only (REQUIRED for tasks with `Modify:` files):**
For every task whose Files block contains a `Modify:` entry, populate the `**Touch only:**` line specifying which lines/sections the task is allowed to alter. This pairs with the phase reviewer's diff-scope rule — without it, reviewers flag adjacent pre-existing tech debt as regressions and implementers waste retries on out-of-scope fixes.

**Interfaces — Consumes/Produces (REQUIRED per task):**
Populate the `**Interfaces:**` block with exact signatures — names, parameter and return types from the tech-spec — for what this task consumes from earlier tasks and produces for later ones. A task's implementer sees only their own task text; this block is how they learn the names and types neighboring tasks use, and it is what makes parallel groups safe. A signature that differs between producer and consumer tasks is a plan bug — fix it before presenting.

**Checkpoint probes (REQUIRED when tech-spec.md sets `verification_mode` other than `none`):**
Give every milestone a `**Checkpoint probes:**` block (format and tags in [references/plan-templates.md](references/plan-templates.md#milestone-section)). The probes are written now, before any code exists, because a separate executor runs them at the checkpoint and the controller may not substitute its own judgment: a probe authored after the fact by the agent that built the feature proves what that agent chose to look at. Each probe is literal and references only the tech-spec's `### Test Hooks` contract surface — a CSS class or internal DOM path is a plan bug. A `verification_mode` with no `### Test Hooks` section is a tech-spec gap: say so and stop. So is a writing probe — a `[demo]`, a `[real-input]`, a data mutation — when Test Hooks has no *Scratch environment* line: the executor cannot isolate it, and it comes back BLOCKED at every checkpoint. A milestone whose probes read the database gets its own Scratch setup line (migrate, then seed, for that milestone's schema), because the executor starts each checkpoint from what the scratch database already holds.

**Blast radius — every barrier green (REQUIRED):**
For every Produces item that changes a signature, adds a required field or enum value, removes or renames a symbol, or adds files to an existing directory, grep the codebase for its callers and consumers — including tests and loaders that read the directory by glob or `fs` rather than import, which changed-file test runs never select. Put each hit in that task's Files (`Modify:`) and Touch only, or in a dedicated barrier step, so the barrier after it can pass typecheck and tests. A barrier that is red by design is a plan bug.

### Step 4: Review Loop (large plans only)

For plans with **10+ tasks or 3+ milestones**, review in chunks before finalizing:

1. After completing each milestone's tasks, self-review that chunk:
   - Every tech-spec step has a corresponding task
   - Parallel groups have zero file overlap
   - TDD steps carry a `Verify at phase review:` command
   - No scope creep beyond tech-spec
2. If issues found: fix and re-review that chunk
3. If review loop exceeds 3 iterations on one chunk, present issues to user for guidance

Skip this step for smaller plans (single milestone, < 10 tasks).

### Step 4.5: Spec Coverage Check (REQUIRED, all plans)

Step 3 guarantees every task quotes a spec passage. It does not guarantee the
reverse — that every spec passage reached a task. That gap is invisible
downstream: the implementer subagent reads only its task text, and the phase
reviewer reads only the diff against the plan, so a requirement that never
became a task is a requirement nobody checks for the rest of the feature.

Walk the two source documents, not the plan — reading the plan and asking "what
does this cover" finds only what is already there:

1. List every requirement and every acceptance criterion in `spec.md`, and
   every implementation step in `tech-spec.md`, in source order. Requirements
   get their own rows even when an AC seems to restate them — a requirement no
   AC restates is exactly the one that drops out of an AC-only walk. Use the
   IDs `spec.md` assigns (`REQ-001`, `NFR-2`); if its requirements are numbered
   without a prefix, cite them as `R<n>`.
2. For each, name the task ID(s) that realize it. Match on the behavior the
   requirement describes, not on shared vocabulary — a task that touches the
   same file as an AC does not thereby cover it.
3. Write the results to the plan's `## Spec Coverage` table (see
   [references/plan-templates.md](references/plan-templates.md)).

**A requirement with no task is a blocking gap.** Resolve every one before
Step 5, by exactly one of:

- **Add or extend a task** so the requirement is realized, then re-quote it into
  that task's `**Spec contract:**` block. This is the default.
- **Mark it `DEFERRED` with a reason** in the Tasks column, and surface the list
  of deferrals to the user in Step 6 alongside the plan. A deferral is a scope
  decision, so it is the user's to make — never defer a requirement silently,
  and never defer one merely because it is awkward to plan.

Do not close a gap by rewording the requirement, by widening an existing task's
description to sound like it covers more, or by pointing at a task that only
partly realizes it. If a spec requirement cannot be turned into a task at all,
the tech-spec is missing a step — say so and stop, rather than planning around
it.

### Step 5: Save Plan

Save to the path shown in [## Plan Document Format](#plan-document-format).

### Step 6: Present and Hand Off

Present the plan. If Step 4.5 recorded any `DEFERRED` row, list those requirements and their reasons here and get the user's decision before handing off — the plan is otherwise approved with a scope cut nobody named. On approval, hand off to `/myspec:feature-implement`.

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
2. **Complete code where it is risky** — algorithms, library calls, validation, anything a Prototype line covers: not "add validation", but the actual validation code. Mechanical parts (wiring, config plumbing, re-exports) get exact signatures and test names instead. Implementers paste snippets verbatim, so each must pass the project's lint rules (e.g. rethrow with `{ cause }`) and carry no module-level side effects (resolve paths, read files, or touch globals inside functions, not at import time)
3. **TDD sequence** — write test → run (fail) → implement → run (pass) → commit
4. **Run commands** — exact verification commands with expected output (from `.claude/verification.json`)
5. **Commit messages** — conventional commits: `feat({feature}): description`
6. **Context for subagents** — each task must be self-contained; its Interfaces block carries the exact signatures it consumes and produces
7. **No duplication** — reference tech-spec for architecture/decisions, don't copy them (exact values and signatures are the exception: Global Constraints and Interfaces copy them verbatim precisely so tasks never re-derive them)

## Integration

**Called by:** `/myspec:feature-tech-spec` OPTIONAL (after tech-spec is approved)
**Next:** `/myspec:feature-implement` — REQUIRED: hand off after plan is approved

## Handoff to feature-implement

When handing off to `/myspec:feature-implement`:

**Sequential tasks:** Standard flow — one implementer subagent at a time.

**Parallel groups:** Controller dispatches multiple implementer subagents simultaneously, each in its own worktree created from the feature HEAD. Each gets:
- Its task text (self-contained — Spec contract and Interfaces travel inside it)
- Shared context (the plan's Global Constraints section, config from barrier task)
- Constraint: do not modify files outside your task's file list

**After parallel group completes (phase boundary):**
- All subagents report back
- Merge barrier: integrate worktrees, run verification commands
- Phase review: single reviewer checks spec compliance, quality, tests, and docs for all tasks
- Proceed to next phase

**Model selection for parallel tasks:**
- Most parallel tasks are mechanical (isolated, clear spec) → use fast model
- Barrier/merge tasks need integration judgment → use standard model

**Milestone checkpoints:** After each milestone except the final one (its completion flows into `feature-complete` directly), `feature-implement` pauses and asks the user:
- `continue` — proceed to next milestone in the same session
- `stop` — commit all changes, exit (resume with `/myspec:feature-implement` later)
- `fresh` — commit all changes, exit with instructions to spawn a fresh agent

Past five tasks, `fresh` is the recommended answer: a multi-milestone run in one session is
dispatch-latency-bound and the controller's context degrades across milestones. Size milestones
so one is a session's worth of work.

**Task status in plan file** (managed by `feature-implement`, not by the author):
- `[ ]` — todo (all tasks start as todo when the plan is generated)
- `[~]` — in progress (set when agent starts dispatching a task)
- `[x]` — done (set after task passes phase review)

## Verification Checklist

Before presenting the plan:

- [ ] `## Spec Coverage` holds one row per spec.md requirement ID, per spec.md acceptance criterion, and per tech-spec.md implementation step, each mapped to task IDs or explicitly `DEFERRED` with a reason (Step 4.5)
- [ ] Header `spec` / `tech_spec` keys point at the feature's `spec.md` and `tech-spec.md`; `planned_against` holds HEAD's SHA after the Step 1 sync
- [ ] `## Global Constraints` holds every project-wide exact (versions, limits, naming, invariants) verbatim with source refs; no task text re-derives one
- [ ] Task boundaries are right-sized — each task independently rejectable by a reviewer; trivial same-shape changes batched into one task
- [ ] Every task has exact file paths matching tech-spec file inventory
- [ ] Every task has TDD steps and a `**Verify at phase review:**` command scoped to the task's own tests
- [ ] Every algorithm or relied-on library call has a `**Prototype:**` line from a scratch run
- [ ] Parallel groups have zero file overlap (check file lists)
- [ ] Barriers exist after every parallel group
- [ ] Consecutive small sequential tasks share a phase; a new phase starts only after a task publishing a contract later tasks are written against
- [ ] Execution order table matches task dependencies
- [ ] Every `DEFERRED` row was surfaced to the user in Step 6, not decided unilaterally
- [ ] Every task has a populated **Spec contract** block with verbatim quotes (not paraphrased) from spec.md / tech-spec.md
- [ ] Every task whose Files contain `Modify:` has a populated **Touch only** line
- [ ] Every task has an Interfaces block (Consumes/Produces, exact signatures); names and types match verbatim between producer and consumer tasks
- [ ] Walked in execution order, every Consumes item matches an earlier task's Produces as written, and no task in between removed or renamed it (a retired field, symbol, or config key a later task still relies on)
- [ ] Every signature-, field-, enum-, symbol-, or directory-changing Produces item has its grepped callers and consumers in that task's Files/Touch only or a barrier step
- [ ] Within each milestone, lower-level layers (data, services) precede higher-level layers (UI, presentation) per project conventions
- [ ] Phase numbers are globally unique across all milestones
- [ ] Cross-milestone dependencies use `Milestone N` in the Depends On column (not individual phase numbers from other milestones)
- [ ] Each milestone is a coherent vertical slice
- [ ] If tech-spec.md sets `verification_mode` (not `none`): every milestone has a `**Checkpoint probes:**` block of literal probes with expected values, referencing only `### Test Hooks` handles; a `[real-input]` probe on every milestone touching a named real corpus; a *Scratch environment* line in Test Hooks whenever any probe writes
- [ ] Commit decision presented to user (Step 7); plan committed before handoff

## Red Flags

**Never:**
- Create tasks for work not in the tech-spec (scope creep)
- Mark tasks as parallel when they share files
- Skip the barrier/merge step after parallel groups
- Duplicate tech-spec architecture in the plan (reference it)
- Split one mechanical sweep into N micro-tasks — batch same-shape trivial changes into one task
- Expand into more than ~20 tasks (if tech-spec has more steps, group related ones)
- Close a Spec Coverage gap by rewording the requirement or by pointing at a task that only partly realizes it — add a task, or defer it in the open
