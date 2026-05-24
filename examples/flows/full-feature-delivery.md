# Flow — full feature delivery (idea → ship)

Walks the entire myspec pipeline for one feature: **Scheduled Exports** for a fictional SaaS reporting app. Shows every handoff, what each skill produces, and where the human approval gates are.

## The feature

> Users want to schedule recurring exports (daily / weekly) of their reports as CSV, delivered via email.

Roughly two milestones of work, touches the data layer, a background job system, and the settings UI. Big enough to exercise parallel groups, small enough to ship in one PR series.

## At a glance

| Step | Skill | Produces | Approval gate |
|------|-------|----------|---------------|
| 1 | `/myspec:brainstorm` | Refined problem statement | — |
| 2 | (manual) | `ideas/scheduled-exports.md` | — |
| 3 | `/myspec:idea-intake` | Entry in `ideas/PRIORITY-LISTING.md` | priority, deps |
| 4 | `/myspec:idea-process` | `features/scheduled-exports/spec.md` + scaffolding | spec answers |
| 5 | `/myspec:feature-spec-review` | Validated spec, `status: approved` | yes / changes |
| 6 | `/myspec:cross-spec-validation` | Conflict report vs. sibling features | resolve conflicts |
| 7 | `/myspec:feature-tech-spec` | `tech-spec.md` with file inventory | yes / changes |
| 8 | `/myspec:feature-tech-spec-review` | Tech-spec marked approved | yes |
| 9 | `/myspec:feature-plan` | `implementation-plan.md` with milestones + parallel groups | yes |
| 10 | `/myspec:feature-implement` | Code + tests committed; phase reviews | per-milestone checkpoint |
| 11 | `/myspec:feature-implement-review` | `conformance-report.md`; independent trace of code vs. spec/plan | route findings |
| 12 | `/myspec:feature-verify` | Health report (drift check) | — |
| 13 | `/myspec:feature-complete` | Status flipped, plan archived, branch merged | merge confirmation |

---

## 1. Brainstorm — sharpen the idea

```
/myspec:brainstorm scheduled exports for reports
```

**Divergent phase**: the agent fans out — push email vs. Slack vs. webhook? CSV vs. Parquet? Daily-only vs. cron? Should past runs be visible?

**Convergent phase**: the agent challenges — *"Email-only adds an SMTP dependency you don't have. Is that a deal-breaker for v1?"* — and surfaces three approaches:

1. Email-only, daily/weekly cadence, no run history (smallest scope).
2. Email + a "Recent Exports" UI showing the last 10 runs.
3. Pluggable destinations (email now, webhook later) with full run history.

User picks **option 2**. The agent writes a one-paragraph synthesis and asks what to do with it.

**User**: *"Drop it into the ideas pipeline."*

The agent writes `ideas/scheduled-exports.md` containing the synthesized problem, scope, and the rejected alternatives.

---

## 2. Idea intake — get on the queue

```
/myspec:idea-intake scheduled-exports
```

The agent reads `ideas/scheduled-exports.md` and `ideas/PRIORITY-LISTING.md`, then asks:

> Priority — HIGH or MEDIUM? Customer-driven request, or backlog cleanup?
>
> Dependencies — does this require the email infrastructure that's tracked in `notification-system`?

**User**: *"HIGH, customer asked. And yes — depends on `notification-system`."*

The agent updates `ideas/PRIORITY-LISTING.md`:

```markdown
## HIGH

- [ ] **scheduled-exports** — Recurring CSV exports of reports via email.
  - Depends on: `notification-system` (✓ shipped 2026-03-12)
```

---

## 3. Idea process — convert to a real spec

```
/myspec:idea-process
```

Picks the highest-priority `[ ]` idea (scheduled-exports), marks it `[~]`, and starts the clarifying-question phase. *(This step is non-skippable — the skill enforces it.)*

The agent works through the question categories:

- **Scope**: "Do users see the cron syntax, or only friendly presets (daily 9am, weekly Mondays)?"
- **UX**: "Where does this live — inside each report's settings, or a dedicated 'Schedules' page?"
- **Data**: "Should a paused schedule still appear in the list, or be archived?"
- **Errors**: "What happens if email send fails — retry, alert, both?"

After the user answers, the skill creates the feature scaffolding:

```
ai/features/scheduled-exports/
├── spec.md          # status: draft, spec_version: 1
├── dependencies.md  # links to notification-system
├── scenarios.md     # Gherkin scenarios from clarifications
└── seed.json        # sample schedule fixtures
```

It also adds an entry to `ai/features/index.yaml`:

```yaml
- name: scheduled-exports
  title: "Scheduled Exports"
  status: draft
  phase: 1
  priority: P1
  depends-on: [notification-system]
```

---

## 4. Spec review — first approval gate

```
/myspec:feature-spec-review scheduled-exports
```

The agent reads `spec.md` against the review checklist: every requirement testable, no implementation leakage, acceptance criteria match user stories, out-of-scope explicit. It finds two issues:

1. **REQ-3** ("system supports any cron expression") contradicts the scope decision to expose only presets.
2. **AC-5** mentions `crontab.parse()` — that's an implementation detail; should be reworded.

The agent shows a diff of the proposed fixes. **User approves.** The skill writes the changes and flips frontmatter:

```yaml
status: approved
last_updated: 2026-04-30
```

---

## 5. Cross-spec validation — catch conflicts early

```
/myspec:cross-spec-validation scheduled-exports
```

The agent loads neighbouring specs (`notification-system`, `report-templates`, `user-settings`) and checks for contract breaks. Finds one:

> **Conflict**: `scheduled-exports/spec.md` requirement REQ-7 says "exports use the user's report-template settings". But `report-templates/spec.md` AC-9 says "templates are session-scoped and don't persist". A scheduled export running tomorrow can't read today's template.

The user resolves by adding a "saved templates" requirement to `report-templates` (deferred, tracked in ideas/) and rewording REQ-7 to say "exports use the report's default columns". The agent rewrites and flips spec_version → 2.

---

## 6. Tech-spec — design the implementation

```
/myspec:feature-tech-spec scheduled-exports
```

The agent reads the approved spec, examines existing patterns (the notification-system migrations, the cron job runner used elsewhere), and drafts `tech-spec.md`:

- **Architecture**: a `ScheduleRunner` job invoked by the existing cron infra; a `ScheduleRepository` for CRUD; a `ScheduleSettings` panel in the UI.
- **Key types**: `Schedule`, `ScheduleCadence`, `ExportRun`.
- **Database changes**: new `schedules` table, new `export_runs` table.
- **API endpoints**: `POST /api/schedules`, `GET /api/schedules`, `DELETE /api/schedules/:id`, `GET /api/schedules/:id/runs`.
- **Implementation steps**: 14 ordered tasks with dependency notes.
- **File inventory**: 11 new files, 4 modified.
- **Decisions**: 3 ADRs — chose Postgres `pg_cron` over an in-app scheduler (dependency already exists); chose presets over cron expressions (matches spec); chose to render a "Next run at" timestamp client-side from cadence (no backend round-trip).
- **Edge cases**: paused schedules, deleted reports, retry policy on email failure.

`based_on_spec_version: 2` matches `spec.md`. **User approves the tech-spec** after one revision (asks for the run-history retention to be 90 days, not 30, to match the audit requirement from `notification-system`).

---

## 7. Tech-spec review — second approval gate

```
/myspec:feature-tech-spec-review scheduled-exports
```

Verifies every acceptance criterion has at least one implementation step, every step has a file path matching the inventory, every interface is defined. Passes. Status flipped to `approved`.

---

## 8. Plan — execution-ready breakdown

```
/myspec:feature-plan scheduled-exports
```

The agent groups the 14 tech-spec steps into milestones and parallel groups, lands at:

```markdown
## Execution Order

### Milestone 1: Core CRUD + cron infrastructure (single user can create a schedule that runs)

| Phase | Mode | Tasks | Depends On |
|-------|------|-------|------------|
| 1 | sequential | T1: migration: schedules + export_runs tables | — |
| 2 | parallel:repos | T2: ScheduleRepository, T3: ExportRunRepository | 1 |
| 3 | sequential (barrier) | T4: shared types/interfaces in src/schedules/types.ts | 2 |
| 4 | parallel:services | T5: ScheduleRunner job, T6: API handlers | 3 |
| 5 | sequential (barrier) | T7: integration test: end-to-end schedule run | 4 |

### Milestone 2: Settings UI + notifications

| Phase | Mode | Tasks | Depends On |
|-------|------|-------|------------|
| 6 | parallel:ui | T8: SchedulesList component, T9: ScheduleForm component, T10: RunHistoryTable | Milestone 1 |
| 7 | sequential (barrier) | T11: SchedulesPage wires components | 6 |
| 8 | sequential | T12: integrate notification-system email template | 7 |
| 9 | parallel:tests | T13: e2e happy-path test, T14: e2e failure-retry test | 8 |
```

Each task expands into TDD steps with exact code, file paths, run commands, and conventional-commit messages. The plan has 14 tasks across 9 phases / 2 milestones — within the 20-task ceiling.

**User approves the plan.**

---

## 9. Implement — dispatch subagents

```
/myspec:feature-implement scheduled-exports
```

The agent walks the plan:

- **Phase 1**: dispatches one subagent for the migration. Mark `[~]` → wait → phase review → `[x]`.
- **Phase 2 (parallel:repos)**: dispatches **two subagents in parallel**, each in its own worktree. T2 modifies only `src/schedules/repository.ts` + tests; T3 modifies only `src/schedules/run-repository.ts` + tests. Zero file overlap, so they run concurrently. Both report back, the controller merges worktrees, runs the verification commands.
- **Phase 3 (barrier)**: types file written, single agent.
- **Phase 4 (parallel:services)**: T5 (job) and T6 (API) in parallel.
- **Phase 5 (barrier)**: integration test ties everything together.
- **End of Milestone 1 — checkpoint.** The agent pauses:

  > Milestone 1 complete. All tasks `[x]`, phase reviews passed.
  >
  > Reply **continue** to start Milestone 2, **stop** to commit and exit, or **fresh** to spawn a fresh agent.

  **User**: `continue`.

- **Phase 6 (parallel:ui)**: three components in parallel (each owns its own file).
- **Phase 7 (barrier)**: page assembly.
- **Phase 8**: notification integration.
- **Phase 9 (parallel:tests)**: two e2e tests in parallel.
- **End of Milestone 2 — checkpoint.** All `[x]`. Done.

The plan file now has every task checked, with phase-review notes inline.

---

## 10. Verify — pre-merge health check

```
/myspec:feature-verify scheduled-exports
```

Read-only health check across all 8 categories. Output:

```
Feature Health: scheduled-exports
─────────────────────────────────
✓ spec.md — frontmatter complete, status approved, no leakage
✓ tech-spec.md — based_on_spec_version aligned, all steps checked
✓ implementation-plan.md — all tasks [x]
✓ file inventory — 11 created, 4 modified, all paths exist
⚠ scenarios.md — 1 Gherkin scenario references the dropped cron-expression UI

→ Fix with: /myspec:feature-spec-sync scheduled-exports
```

User runs the suggested sync, the stale scenario is updated, re-runs verify — all green.

---

## 11. Complete — flip status, archive, merge

```
/myspec:feature-complete scheduled-exports
```

Phase 1 — docs sync:

- Marks all tech-spec implementation steps `[x]`.
- Reconciles file inventory (T11 ended up adding two more files than planned — those get added).
- Captures one in-flight ADR ("ScheduleForm uses optimistic UI for cadence changes").
- Flips manifest entry: `status: complete`, `phase: 2`.
- Archives the plan: `implementation-plan.md` → `plans/2026-04-30-scheduled-exports-v1.md`.

Phase 2 — branch integration:

- Confirms tests pass on the feature branch.
- Asks whether to merge to `main` or open a PR.
- **User**: *"Open a PR."*
- Agent runs `gh pr create` with a generated title + body.

---

## What this flow demonstrates

- **Every approval gate is human-driven.** The agent never silently flips `draft → approved`, never starts coding without an approved plan.
- **The spec / tech-spec / plan layering is load-bearing.** Spec answers *what*, tech-spec answers *how*, plan answers *who-does-what-in-what-order*. Skipping a layer breaks the next one.
- **Parallel groups are real concurrency**, not just labels — `feature-implement` dispatches actual subagents with worktree isolation and merges at barriers.
- **Milestone checkpoints exist for a reason** — long features can run across multiple sessions; the checkpoint is where you switch agents without losing state.
- **`feature-verify` before `feature-complete`** catches the drift you didn't notice.
