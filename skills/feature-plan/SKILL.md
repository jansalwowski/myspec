---
name: feature-plan
tags: [feature, planning, implementation, parallel]
description: "Use when a feature has an approved spec.md and tech-spec.md and needs an execution-ready plan with parallel task groups and milestone checkpoints. Do NOT use without an approved tech-spec, or for a plan already in progress."
---

# Feature Plan

**Announce at start:** "I'm using the feature-plan skill to create the implementation plan for {feature}."

**Autopilot:** when the user opted in, answer this skill's gates per [`_shared/autopilot.md`](../_shared/autopilot.md).

**Plugin lib:** `${CLAUDE_PLUGIN_ROOT}/lib` — the plugin's helper scripts. Files this skill sends you to write it as `<plugin lib>`: use this resolved path in its place. The Bash tool does not export the variable, so never type it in a command.

## When to Use

Check these gates in order. Read each document's `status:` frontmatter before writing anything; a gate that says Stop means no plan file is written and nothing is handed off. A sub-feature's documents live in `${aiDir}/features/{parent}/{subfeature}/`.

1. **Feature in `${aiDir}/features/`?** → No: create a spec first with `/myspec:feature-spec`. Stop.
2. **Have `tech-spec.md`?** → No: run `/myspec:feature-tech-spec` first. Stop.
3. **`spec.md` is `status: approved`?** → No: say the spec is not approved, route to `/myspec:feature-spec-review` (it sets the status), and stop. There is no override: the tech-spec and the plan both build on the approved requirements.
4. **`tech-spec.md` is `status: approved`?** → `draft`: ask with `AskUserQuestion` whether to plan from the draft, with two options and neither marked `(Recommended)`: "Plan from the draft tech-spec" and "Stop — review it first (`/myspec:feature-tech-spec-review`)". Proceed only on an explicit "Plan from the draft" answer given in this session. The request to write a plan is not that answer. With no answer, or no way to ask (non-interactive run), say the tech-spec is not approved and stop. Autopilot does not answer this gate ([`_shared/autopilot.md`](../_shared/autopilot.md): no recommended option).

All gates pass → proceed to Workflow Step 1.

## Workflow

### Step 1: Read Context

1. Read `${aiDir}/features/{feature}/tech-spec.md` — note implementation steps, file inventory, interfaces
2. Read `${aiDir}/features/{feature}/spec.md` — note requirement IDs, acceptance criteria, edge cases
3. **Sync the base**, so snippets match the code implementers will see. `$INTEGRATION` is the branch feature work merges into: the topology file's `branches.integration`, else the default branch ([`_shared/git-helpers.md`](../_shared/git-helpers.md)). Resolve the ref with `BASE=$("${CLAUDE_PLUGIN_ROOT}/lib/plan-freshness.sh" base "$INTEGRATION")`: it fetches and prints `origin/$INTEGRATION`, or `$INTEGRATION` when there is no remote. Exit 2 (fetch failed, or the branch does not exist): stop and report. Then `git merge-base --is-ancestor "$BASE" HEAD`:
   - exit 0 — HEAD already contains it
   - exit 1 — HEAD lags: `git merge --no-edit "$BASE"`; if the merge exits non-zero, `git merge --abort` and stop for the user
   - any other exit (bad ref) — stop and report; never plan against an unverified base

   After the sync, record `git rev-parse HEAD` (full 40-char SHA) as the plan header's `planned_against`: it is the tree Step 4 reads snippets from, so a branch's own earlier commits are not later mistaken for drift. `feature-implement` warns when a `Modify:` file changed after it. Also write `auto_parallel_phases: true`, which lets independent phases run concurrently, so the Execution Order table's `Depends On` must name every real dependency.
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

**Milestone rule:** group tasks into milestones, each a vertical slice that delivers one coherent piece of functionality and leaves the branch working. Never an "all backend" milestone followed by an "all frontend" one.
- Within a milestone, classify each task by project layer (backend/frontend, server/client, data/presentation — the project's own conventions) and order lower layers (data, services, APIs) before higher ones (UI, presentation). Across milestones, Milestone 2's backend may follow Milestone 1's frontend — that is the whole point.
- Size: 3-7 phases and 3-10 tasks per milestone; past 10 tasks, split it. A feature under ~8 tasks is one milestone — never force more. Size a milestone as one session's work: `feature-implement` pauses at each checkpoint and recommends a fresh session past five tasks.

**Parallel candidates:** extractors or parsers for different data types, independent UI components that share no state, services for unrelated entities, test suites for independent modules. **Barriers:** shared config or types, database migrations, orchestrators that call other modules, integration tests over several components. Tag a group `[parallel:descriptiveName]`.

**Scope and files:** a tech-spec that covers several independent subsystems gets one plan per sub-feature (`/myspec:feature-decompose` if it is not split yet). Give each file one responsibility, keep files that change together together, and follow the codebase's existing structure — never restructure unasked.

### Step 3: Expand to Execution Tasks

**REQUIRED:** read [references/plan-templates.md](references/plan-templates.md) before writing any task — it carries the front-matter, Execution Order, task, and barrier templates. Convert each tech-spec implementation step into a full task using that format.

**What the tech-spec provides:** High-level step description, file inventory, interfaces
**What the plan adds:** Exact TDD steps, test code, the phase-review verification command, commit messages, parallel group tags

**Task right-sizing (the step → task mapping is not 1:1):**
A task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's gate. Fold setup, configuration, scaffolding, and docs steps into the task whose deliverable needs them; split only where a reviewer could meaningfully reject one task while approving its neighbor. The inverse holds too: several trivial same-shape changes (rename sweeps, config plumbing) are ONE task listing every file + change, not N micro-tasks — N reviewer gates on one mechanical sweep is overhead, not protection.

**Prototype before prescribing (REQUIRED for algorithms and relied-on library calls):**
A call the plan never ran reaches implementers as a mandate, and its defect surfaces a fix loop later. When a task's Step 2 holds an algorithm or a third-party call whose behavior it relies on, run that code first in a scratch directory outside the tree on realistic inputs (the spec's edge cases, real data shapes), and put the command and observed result on the task's `**Prototype:**` line. For a new module, run the planned test against the planned code once: it fails without Step 2 and passes with it. A result that contradicts the tech-spec is a tech-spec defect: say so and stop.

**Verification planning (REQUIRED when `tech-spec.md` sets `verification_mode` other than `none`, or its `### Test Hooks` names *Real inputs*):** read [references/verification-planning.md](references/verification-planning.md). It gives every milestone a `**Checkpoint probes:**` block, written now because a separate executor runs it, and a dry run of the derivation's core on the named real corpus, quoted on the `**Prototype:**` line. A `verification_mode` with no `### Test Hooks` section, or an input the rule cannot place, is a tech-spec defect: say so and stop.

**Global Constraints (REQUIRED, once per plan):**
Populate the plan's `## Global Constraints` section with the project-wide exacts collected in Step 1 — version floors, size/perf limits, naming rules, invariants — copied verbatim from `spec.md` / `tech-spec.md` with source refs. Every task's requirements implicitly include this section; per-task text must not re-derive or paraphrase these values — re-derivation is how they drift.

**Spec contract — verbatim quotes (REQUIRED per task):**
For every task, populate the `**Spec contract:**` block with verbatim quotes from `spec.md` and/or `tech-spec.md` covering this task's behavior. Paste the sentence; do NOT paraphrase. The implementer subagent does NOT read `spec.md` or `tech-spec.md` — it receives the task text and nothing else. Any requirement that does not make the spec → task translation is invisible to it. If you find yourself rewording spec language, the original wording IS the contract — quote it. If a task has no spec/tech-spec passage that constrains it, ask whether the task should exist. Quote sentences, not sections: a longer contract several tasks share (a schema, an API shape) is cited by path and heading — `tech-spec.md` → `### API Schema` — once per task, and `feature-implement` pastes it into each dispatch.

**Touch only (REQUIRED for tasks with `Modify:` files):**
For every task whose Files block contains a `Modify:` entry, populate the `**Touch only:**` line specifying which lines/sections the task is allowed to alter. This pairs with the phase reviewer's diff-scope rule — without it, reviewers flag adjacent pre-existing tech debt as regressions and implementers waste retries on out-of-scope fixes.

**Interfaces — Consumes/Produces (REQUIRED per task):**
Populate the `**Interfaces:**` block with exact signatures — names, parameter and return types from the tech-spec — for what this task consumes from earlier tasks and produces for later ones. A task's implementer sees only their own task text; this block is how they learn the names and types neighboring tasks use, and it is what makes parallel groups safe. A signature that differs between producer and consumer tasks is a plan bug — fix it before presenting.

**Blast radius — every barrier green (REQUIRED):**
For every Produces item that changes a signature, adds a required field or enum value, removes or renames a symbol, or adds files to an existing directory, grep the codebase for its callers and consumers — including tests and loaders that read the directory by glob or `fs` rather than import, which changed-file test runs never select. When the change adds an entity or value (a country, enum member, code, record type), also grep tests and fixtures for its literal: a test that uses it as the absent or "unlisted" example breaks once it exists, or stays green only by coincidence. Put each hit in that task's Files (`Modify:`) and Touch only, or in a dedicated barrier step, so the barrier after it can pass typecheck and tests. A barrier that is red by design is a plan bug.

### Step 4: Review Loop (large plans only)

For plans with **10+ tasks or 3+ milestones**, review in chunks before finalizing:

1. After completing each milestone's tasks, self-review that chunk:
   - Every tech-spec step has a corresponding task
   - Parallel groups have zero file overlap
   - TDD steps carry a `Verify at phase review:` command
   - No scope creep beyond tech-spec
2. If issues found: fix and re-review that chunk
3. If review loop exceeds 3 iterations on one chunk, present issues to user for guidance

### Step 4.5: Spec Coverage Check (REQUIRED, all plans)

Step 3 guarantees every task quotes a spec passage, not that every spec passage reached a task. Nobody downstream sees that gap: the implementer reads only its task text and the phase reviewer only the diff against the plan.

Walk the two source documents, not the plan — reading the plan and asking "what does this cover" finds only what is already there:

1. List every requirement and every acceptance criterion in `spec.md`, and
   every implementation step in `tech-spec.md`, in source order. Requirements
   get their own rows even when an AC seems to restate them — a requirement no
   AC restates is exactly the one that drops out of an AC-only walk. Use the
   IDs `spec.md` assigns (`REQ-001`, `NFR-2`); if its requirements are numbered
   without a prefix, cite them as `R<n>`.
2. For each, name the task ID(s) that realize it. Match on the behavior the
   requirement describes, not on shared vocabulary — a task that touches the
   same file as an AC does not thereby cover it.
3. For each mapped row, name the test (file and case) that will prove it —
   usually the one the task's TDD step writes. A behavior no planned test
   asserts is a gap: add the test to the task.
4. Write the results to the plan's `## Spec Coverage` table (see
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

### Step 4.6: Plan Self-Check (REQUIRED, all plans)

Implementers paste the plan's snippets verbatim, and phase reviewers grade the diff against the plan. A defect the plan dictates therefore passes the implementer and costs a fix loop at phase review. Before saving, read the written plan against `spec.md` and `tech-spec.md` and run the four checks in [references/plan-self-check.md](references/plan-self-check.md): snippets vs their spec contract, steps that contradict each other, reader-visible strings, and probe lint. Fix each finding in the plan, record the result in the plan's `## Plan Self-Check` section, then walk that file's "Before presenting" checklist. A probe that depends on an earlier probe's writes is allowed if the probe line declares the dependency.

### Step 5: Save Plan

Save to `${aiDir}/features/{feature}/implementation-plan.md` (sub-features: `${aiDir}/features/{parent}/{subfeature}/implementation-plan.md`).

### Step 6: Present and Hand Off

Present the plan. If Step 4.5 recorded any `DEFERRED` row, list those requirements and their reasons here and get the user's decision before handing off — the plan is otherwise approved with a scope cut nobody named. On approval, hand off to `/myspec:feature-implement`.

### Step 7: Commit Decision (BLOCKING before feature-implement)

The plan must be committed before `/myspec:feature-implement` runs, or the spec and plan files dangle on the current branch and are left behind when implement makes its worktree.

Resolve the default branch, `HEAD` and working-tree state (REQUIRED reference: [`_shared/git-helpers.md`](../_shared/git-helpers.md)), then call `AskUserQuestion` — question "Plan is ready. Commit before /feature-implement to avoid dangling files.", header "Commit plan" — with the recommended option first and `(Recommended)` appended:

| Option | Does |
|--------|------|
| Commit to `{HEAD}` | Commits implementation-plan.md, plus any updated spec or tech-spec, on the current branch |
| New branch `feat/{name}` | Offered only when HEAD is the default branch: creates `feat/{name}`, switches, commits |

- "Leave uncommitted" is **not** offered — it is the failure this prompt exists to prevent. A user who needs it has AskUserQuestion's "Other".
- Default message: `feat({name}): add implementation plan` (or `feat({name}): add spec, tech-spec, and implementation plan` when those are uncommitted too). Show it, accept or edit, commit.
- Stage only the feature's files (no `git add -A`).

## Task Expansion Rules

1. **Exact file paths** — from tech-spec file inventory
2. **Complete code where it is risky** — algorithms, library calls, validation, anything a Prototype line covers: not "add validation", but the actual validation code. Mechanical parts (wiring, config plumbing, re-exports) get exact signatures and test names instead. Implementers paste snippets verbatim, so each must pass the project's lint rules (e.g. rethrow with `{ cause }`) and carry no module-level side effects (resolve paths, read files, or touch globals inside functions, not at import time)
3. **TDD sequence** — write test → run (fail) → implement → run (pass) → commit
4. **Run commands** — exact verification commands with expected output (from `.claude/verification.json`)
5. **Commit messages** — conventional commits: `feat({feature}): description`
6. **Context for subagents** — each task must be self-contained; its Interfaces block carries the exact signatures it consumes and produces
7. **No duplication** — reference tech-spec for architecture/decisions, don't copy them (exact values and signatures are the exception: Global Constraints and Interfaces copy them verbatim precisely so tasks never re-derive them)
8. **Checkboxes start `[ ]`** — `feature-implement` owns `[~]` and `[x]`; the author never sets them

## Red Flags

**Never:**
- Create tasks for work not in the tech-spec (scope creep)
- Mark tasks as parallel when they share files, or leave a parallel group without its barrier
- Expand into more than ~20 tasks (if tech-spec has more steps, group related ones)

## Verification Checklist

The full per-rule checklist is "Before presenting" in [references/plan-self-check.md](references/plan-self-check.md) (Step 4.6). Before handing off:

- [ ] Every gate in When to Use passed; a draft tech-spec was planned from only on the user's explicit answer
- [ ] `## Spec Coverage` has a row for every requirement, acceptance criterion and tech-spec step, each mapped to tasks and a test, or `DEFERRED` with a reason the user saw in Step 6
- [ ] `## Plan Self-Check` records the four Step 4.6 checks, and the "Before presenting" checklist was walked
- [ ] Header holds `planned_against` (HEAD after the Step 1 sync) and `auto_parallel_phases: true`
- [ ] The plan is committed (Step 7)

## Integration

**Called by:** `/myspec:feature-tech-spec` OPTIONAL (after tech-spec is approved)
**Next:** `/myspec:feature-implement` — REQUIRED: hand off after plan is approved
