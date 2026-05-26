# Plan Document Templates — Orchestrator Mode

Use this template when the user selects orchestrator mode at Step 0 of `feature-plan`. For normal mode, see [`plan-templates.md`](./plan-templates.md). Task Details shape is structurally identical so a plan can be flipped between modes without rewriting per-task content.

## Why no Planner role?

`feature-plan` task templates already mandate atomic tasks: exact file paths, complete code (not "add validation" but the actual validation code), TDD sequence with run commands, self-contained subagent context. Inserting a Planner agent to re-derive these is tautological. The plan IS the brief. Workers consume task text directly.

Chain has three role agents only: Worker, SpecReviewer, QualityReviewer.

## Front-matter

Every orchestrator plan starts with this YAML block. `orchestration: agent-chain` is what `feature-implement` detects to switch dispatch modes.

```yaml
---
feature: <feature-name>
spec_version: <int>
orchestration: agent-chain
roles:
  worker: cheap
  spec_reviewer: mid
  quality_reviewer: mid
---
```

`roles` values are tier names (`cheap`, `mid`, `premium`). The controller (main thread) maps tier → concrete model based on the runtime's available models. Skill text never names a concrete model. Three keys only — `worker`, `spec_reviewer`, `quality_reviewer`. Adding a `planner` key has no effect.

### Per-task tier override

Individual tasks can override the global Worker tier when the task is heavier than the default (complex AST manipulation, multi-system integration, intricate algorithm). Add a `**Tier override:**` line inside the task block:

```markdown
### Task 7: TypeScript program + module resolver

**Tier override:** worker=mid
(reason: ts.Compiler API setup, ~80 LoC, alias-resolution edge cases)

**Spec contract (verbatim quotes):**
...
```

Rules:
- Only `worker` can be overridden per-task. SpecReviewer + QualityReviewer tiers stay global (consistent review bar across the milestone).
- Use sparingly. The cost model assumes most tasks run at the global default; overriding > ~30% of tasks means the global tier is wrong and `roles.worker` should be bumped instead.
- Always include a one-line reason in parentheses on the same or next line. The reason exists for the user reviewing the plan, not for the controller.
- Resolution order in the controller: `task.tier_override.worker` (if present) → `roles.worker` → built-in default (`cheap`).
- Reviewer tasks do not have task-local overrides — they are per-milestone agents, not per-task.

## Task Status

Same checkbox semantics as normal mode:

| Status | Meaning | Set by |
|--------|---------|--------|
| `[ ]` | Todo — not started | `feature-plan` (initial state) |
| `[~]` | In progress — Worker is on it | `feature-implement` (when dispatching Worker) |
| `[x]` | Done — Worker DONE + SpecReview PASS + QualityReview PASS | `feature-implement` (after both reviewers pass) |

## Milestone Section

```markdown
### Milestone N: [Descriptive Name]

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: [Backend task] | sequential | — |
| 2 | Task 2: [Frontend task] | sequential | Phase 1 |
| 3 | Task 3: [Tests] | sequential | Phase 2 |

**Chain:**
- Workers — tier `${roles.worker}` — one per task, parallel where Mode allows. Receive full inline task text. Writes only — no shell, no git.
- SpecReviewer — tier `${roles.spec_reviewer}` — gates QualityReviewer. Verdicts: `PASS`, `FAIL-SPEC`, `ESCALATE`.
- QualityReviewer — tier `${roles.quality_reviewer}` — runs verification commands (test, lint, type-check) and gates Commit. Verdicts: `PASS`, `FAIL-QUALITY`.
- Commit — controller stages the Worker's reported file list and commits with the message from the task block. One commit per task, after both reviewers pass.
- Checkpoint — controller runs milestone-level verification, prompts unless `orchestrator-auto`.

**Notes for controller:**
- Retry cap: 3 per failure kind per milestone (`FAIL-SPEC`, `FAIL-QUALITY`).
- `FAIL-SPEC` → re-dispatch the same Worker(s) with reviewer verdict appended.
- `FAIL-QUALITY` → re-dispatch the same Worker(s) with reviewer verdict appended.
- `ESCALATE` → pause immediately; plan ↔ spec mismatch needs human fix via `/myspec:feature-update` or re-run `/myspec:feature-plan`.
- No briefs/ directory is created. Workers consume task text directly.
```

Phase numbers stay globally unique across milestones. Cross-milestone dependencies use `Milestone N` in `Depends On`.

## Task Details

Structurally similar to normal-mode plan template (same Files / Depends on / Spec contract / Touch only shape so a feature can flip between modes without rewriting tasks). See `plan-templates.md` for the per-task block shape.

**Orchestrator-specific step ownership.** In orchestrator mode each step inside a task block is owned by exactly one chain role. The Worker has no shell — it cannot run tests, lint, or git. The plan must reflect that. Annotate every step with its owner:

```markdown
- [ ] **Step 1 (Worker): Write the failing test**
  [test code]

- [ ] **Step 2 (Reviewer): Run test — expect FAIL**
  Test command from `.claude/verification.json` (`test` check)

- [ ] **Step 3 (Worker): Implement**
  [implementation code]

- [ ] **Step 4 (Reviewer): Run test — expect PASS**
  Same test command. Reviewer folds non-zero exits into FAIL-QUALITY bullets.

- [ ] **Step 5 (Controller): Commit**
  `git commit -m "feat({feature}): add component-name"`
```

Rules:
- Only `Worker` steps may write files. Only `Reviewer` steps may run verification commands. Only `Controller` steps may run git mutations. No step mixes roles.
- The Worker dispatch envelope strips `Reviewer` and `Controller` steps from `{{TASK_TEXT}}` before substitution — they exist in the plan so the human reviewer sees the full picture, not so the Worker reads them.
- Single `Commit` step per task, always last, always Controller-owned, always exact `git commit -m "..."`.

The orchestrator-specific additions per milestone are:
- The **Chain** and **Notes for controller** blocks above (milestone level).
- The `(Worker|Reviewer|Controller)` owner annotation on every task step.

## Mode interaction with Step 5

Orchestrator mode does NOT skip the final holistic review. After the last Milestone Checkpoint, `feature-implement` still runs Final Verification and dispatches `holistic-reviewer-prompt.md` for the whole-feature diff. SpecReview + QualityReview are per-milestone; holistic is end-of-feature.
