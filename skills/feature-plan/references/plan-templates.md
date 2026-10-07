# Plan Document Templates

Canonical implementation-plan template: one implementer subagent per task, reviewed at phase boundaries.

## Plan Header

Every implementation-plan.md starts with this frontmatter. Downstream consumers depend on it: `feature-complete` kebab-cases `title` for the archive filename, and `feature-verify` compares `last_updated` against tech-spec.md to detect stale plans.

```yaml
---
title: "{Feature Title} -- Implementation Plan"
feature: {feature-dir-name}
based_on_spec_version: {spec_version from spec.md}
spec: ${aiDir}/features/{feature}/spec.md
tech_spec: ${aiDir}/features/{feature}/tech-spec.md
planned_against: {full 40-char SHA of HEAD after the Step 1 sync}
created: {TODAY}
last_updated: {TODAY}
---
```

`spec` / `tech_spec` are explicit pointers, not decoration: the plan argues from those two documents, so they travel with it — anyone executing or reviewing the plan reads both alongside it.

`planned_against` is the commit every snippet was read from: HEAD once the integration branch is merged in, so the feature branch's own commits are part of the baseline. `feature-implement` diffs each `Modify:` file from it to the integration branch tip (`<sha>...origin/<integration>`, three dots, so only integration-branch changes since the sync count) and warns on a change; re-sync and re-record it whenever the plan is revised against newer code.

Update `last_updated` whenever the plan is edited (including checkbox updates by `feature-implement`).

## Global Constraints

Directly after the header, before the Execution Order table:

```markdown
## Global Constraints

> Every task's requirements implicitly include this section.

- `tech-spec.md` §Constraints: "Node >= 20.11; no new runtime dependencies"
- `spec.md` NFR-2: "List endpoints return at most 50 items per page"
- `tech-spec.md` §Naming: "All schedule tables are prefixed `sched_`"
```

Project-wide exact values — version floors, size/perf limits, naming rules, invariants — one line each, copied **verbatim** from spec.md / tech-spec.md with a source reference. Per-task text must never re-derive or paraphrase these values; that is how they drift. Task-scoped behavior stays in each task's Spec contract block.

## Spec Coverage

Written by Step 4.5 after every task exists, directly before the closing `## Plan Self-Check` section (Step 4.6, format in [plan-self-check.md](plan-self-check.md#recording-the-result)):

```markdown
## Spec Coverage

| Source | Requirement (verbatim) | Tasks | Test |
|--------|------------------------|-------|------|
| spec.md REQ-003 | "Imports reject files over 10 MB before parsing" | T3 | `tests/import/limits.test` › rejects an 11 MB file before the parser runs |
| spec.md AC-1 | "Import fails with a message naming the regen command" | T4 | `tests/import/errors.test` › message names the regen command |
| spec.md AC-2 | "Existing callers keep working with the field omitted" | T2, T7 | `tests/api/compat.test` › request without the field; `tests/cli/compat.test` › legacy flags |
| tech-spec.md step 17 | "Collect syntax errors before type errors" | T11 | `tests/check/order.test` › syntax errors listed first |
| spec.md AC-6 | "Usage is reported to the billing dashboard" | DEFERRED — out of scope per tech-spec §Non-Goals; billing lands in feature `usage-metering` | — |
```

One row per requirement ID and per acceptance criterion in `spec.md`, and per implementation step in `tech-spec.md` — no source line is absent from the table. The requirement column is the source's own wording, quoted, so a reader can check the mapping without opening the spec. The Tasks column holds task IDs (several where a requirement spans tasks; the same task may appear in several rows) or the single word `DEFERRED` followed by an em dash and the reason.

The Test column names the test file and the case that will prove the row's behavior — the test the task's TDD step writes, or an existing test the task extends. Several tests are separated by `;`. A deferred row gets `—`. The phase reviewer checks each named test exists and fails without the behavior, so a vague cell ("unit tests") is a gap the same as an empty one. A plan written before the column existed is still valid: `feature-implement` then skips the per-requirement test check.

The table lives in the plan, not beside it: the plan is what `feature-implement` and `feature-complete` read, and a coverage file kept separately drifts from the tasks it describes.

## Task Status

All task steps use checkbox syntax. Plans are generated with `[ ]` (todo). `feature-implement` updates them during execution:

| Status | Meaning | Set by |
|--------|---------|--------|
| `[ ]` | Todo — not started | `feature-plan` (initial state) |
| `[~]` | In progress — agent is working on this | `feature-implement` (when starting task) |
| `[x]` | Done — completed and verified | `feature-implement` (after phase review passes) |

Resume behavior: A new agent reads the plan, skips `[x]` tasks, re-executes `[~]` tasks from scratch, and starts `[ ]` tasks normally.

## Milestone Section

```markdown
### Milestone N: [Descriptive Name]

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: [Data task], Task 2: [Small service task] | sequential | — |
| 2 | Task 3: [Frontend task that builds on the approved service] | sequential | Phase 1 |

**Checkpoint probes:**
- Target: `[command that serves the milestone on scratch config]` → `[URL or entry point]`
- Ports: `[the project's probes.portSource value, and the port names the Target and probes use from it]`
- Scratch env: `[every database, bucket, and queue override, e.g. DATABASE_URL=…/reports_scratch]`
- Scratch setup: `[the commands that bring the scratch database to this milestone's schema and data — the project's migrate command, then its seed command]`
- P1 [visual]: `[literal assertion in the project's UI test tool on a Contract-surface handle, e.g. test ID report-row count is 3]`
- P2 [api]: `[literal request in the project's HTTP client against the Target address, e.g. list reports and count the items]` → `3`
- P3 [real-input]: `[engine command] fixtures/corpus/*.pdf | sha256sum` → same as base
- D1 [demo]: open `/dev/reports`; create a report; open its detail view — screenshot each step
```

Notes:
- A sequential phase may list several tasks; they run in listed order and share one barrier suite and one phase review (Step 2's phase grouping rule)
- Phase numbers must be globally unique across the entire plan (Milestone 2 starts at the next available phase number)
- First phase of Milestone 2+ uses `Milestone N` in Depends On (not a phase number from the previous milestone)
- Single-milestone plans omit the `### Milestone N:` heading — the Execution Order table stands alone
- `**Checkpoint probes:**` is required on every milestone when tech-spec.md sets `verification_mode` to anything but `none`, and absent otherwise. At the milestone checkpoint `feature-implement` hands this block, verbatim and alone, to a separate probe executor — so each probe is a literal command or assertion in the medium's own language with its expected value, never a description ("check the list renders"). Probes reference only the tech-spec's `### Test Hooks` *Contract surface*; Target and Scratch env are copied from its *Target* and *Scratch environment* lines, and Scratch setup from its migrate and seed commands. Write Scratch setup out on every milestone whose probes read the database, never "as Milestone 1": a later milestone's migrations and fixtures exist only after its own setup runs. When the project's `probes.scratchEnvScript` already migrates and seeds, Scratch setup names that script. The line is optional; a block without it runs as before, and a probe addresses the target by the Target line's address, never a different host or port. When `"${CLAUDE_PLUGIN_ROOT}/lib/myspec-config.sh" get probes.portSource` prints a value, the project keeps per-checkout port slots there: add a Ports line naming that source and the slot names, and write every port in Target and the probes as `$<slot name>`, never a literal port another checkout may hold. Unset (`null`), omit the Ports line and address the Target as before. Tags: `[visual]` / `[api]` / `[data]` pick the medium; `[real-input]` runs the *Real inputs* corpus through the real engine (required on a milestone touching that path); `[demo]` serves the milestone on scratch data for the user to click through (recommended for `visual` / `mixed`). A single-milestone plan puts the block after its Execution Order table

## Sequential Task

```markdown
### Task N: [Component Name]

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` §X.Y: "<exact sentence from spec covering this task's behavior>"
- `tech-spec.md` step Z: "<exact sentence from tech-spec covering this task's interface/impl detail>"
- `tech-spec.md` → `### <Section>` (cited, not pasted: a shared schema or API shape longer than a few lines — feature-implement pastes the section into the dispatch)
- (Add one bullet per spec/tech-spec passage that constrains this task. If the task is implementing AC #N, quote AC #N verbatim. If wording diverges from spec, the spec wording wins.)

**Files:**
- Create: `exact/path/to/file.ts`
- Modify: `exact/path/to/existing.ts`
- Test: `exact/path/to/file.test.ts`

**Touch only (required when Files contains Modify):** the specific lines/sections this task adds or changes. Do NOT scan, audit, or modify pre-existing content even if you notice issues — pre-existing tech debt is out of scope. Reviewers will reject diffs that touch unrelated lines.

**Interfaces:**
- Consumes: `createSchedule(input: ScheduleInput): Promise<Schedule>` — from Task N-1
- Produces: `listSchedules(userId: string): Promise<Schedule[]>` — Task N+2 relies on this
- (Exact signatures — names, parameter and return types — from the tech-spec. A task's implementer sees only their own task text; this block is how they learn the names and types neighboring tasks use. `Consumes: nothing` / `Produces: nothing` is valid.)

**Depends on:** Task N-1

**Prototype (required when Step 2 holds an algorithm or a relied-on library call):** `<scratch command>` → `<observed result>`; for a new module, "planned test fails without Step 2, passes with it"

**Verify at phase review:** `<test command from .claude/verification.json, scoped to exact/path/to/file.test.ts>`
(Scoped to this task's tests, never the full suite: the implementer runs it before reporting,
and the phase reviewer runs every task's command once the phase is complete. Name the command
here so neither has to infer it.)

- [ ] **Step 1: Write the failing test**
  [test code]

- [ ] **Step 2: Implement**
  [complete code for risky logic; exact signatures for mechanical parts]

- [ ] **Step 3: Commit**
  `git commit -m "feat({feature}): add component-name"`
```

## Parallel Task

```markdown
### Task N: [Component Name] [parallel:groupName]

**Spec contract (verbatim quotes — do NOT paraphrase):**
- `spec.md` §X.Y: "<exact sentence>"
- `tech-spec.md` step Z: "<exact sentence>"

**Files:**
- Create: `exact/path/to/file.ts`
- Test: `exact/path/to/file.test.ts`

**Touch only (required when Files contains Modify):** the specific lines/sections this task adds or changes. Pre-existing tech debt is out of scope.

**Interfaces:**
- Consumes: `<exact signature>` — from Task M (barrier)
- Produces: `<exact signature>` — Task P relies on this

**Depends on:** Task M (barrier)
**Parallel with:** Tasks N+1, N+2, N+3

> **Isolation:** This task runs in its own worktree. Do not reference files created by sibling parallel tasks.

- [ ] **Step 1: Write the failing test**
  [test code]
...
```

## Parallel Group Barrier

```markdown
## Barrier: Merge parallel:groupName

> After all tasks in `parallel:groupName` complete and pass review, merge worktrees back to the working branch before proceeding.

- [ ] Merge Task N worktree
- [ ] Merge Task N+1 worktree
- [ ] Merge Task N+2 worktree
- [ ] Read `.claude/verification.json` and run each required check — all pass
- [ ] Resolve any integration conflicts
- [ ] Commit merge: `git commit -m "feat({feature}): integrate {groupName}"`
```
