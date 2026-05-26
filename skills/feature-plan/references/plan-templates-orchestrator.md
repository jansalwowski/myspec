# Plan Document Templates — Orchestrator Mode

Use when the user selects orchestrator mode at Step 0 of `feature-plan`. Normal mode: [`plan-templates.md`](./plan-templates.md). Task Details shape stays structurally aligned so plans can flip between modes without rewriting per-task content.

## Why no Planner role?

Task templates already mandate atomic content: exact file paths, complete code, self-contained subagent context. A Planner agent re-deriving these is tautological. Plan IS the brief. Workers consume task text directly. Chain has three role agents: Worker, SpecReviewer, QualityReviewer.

## Front-matter

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

`orchestration: agent-chain` is what `feature-implement` detects to switch dispatch modes. `roles` values are tier names (`cheap`, `mid`, `premium`) — controller maps tier → concrete model. Three keys only; `planner` has no effect.

### Per-task tier override

When a task is heavier than the milestone default (complex AST work, multi-system integration, intricate algorithm), add `**Tier override:** worker=<tier>` with a one-line reason:

```markdown
### Task 7: TypeScript program + module resolver

**Tier override:** worker=mid
(reason: ts.Compiler API setup, ~80 LoC, alias-resolution edge cases)
```

Rules:
- Only `worker` is overridable per-task. Reviewer tiers stay global.
- Resolution order: `task.tier_override.worker` → `roles.worker` → built-in `cheap`.
- Sparingly. > ~30% of tasks needing override means `roles.worker` is wrong — bump the global instead.

## Task Status

Same `[ ]` / `[~]` / `[x]` semantics as normal mode (see `plan-templates.md`). `[~]` set when Worker starts; `[x]` set after both reviewers PASS.

## Milestone Section

```markdown
### Milestone N: [Descriptive Name]

| Phase | Tasks | Mode | Depends On |
|-------|-------|------|------------|
| 1 | Task 1: [Backend task] | sequential | — |
| 2 | Task 2: [Frontend task] | sequential | Phase 1 |
| 3 | Task 3: [Tests] | sequential | Phase 2 |

**Chain:**
- Workers — tier `${roles.worker}` — one per task, parallel where Mode allows. Writes only — no shell, no git.
- SpecReviewer — tier `${roles.spec_reviewer}` — gates QualityReviewer. Verdicts: `PASS`, `FAIL-SPEC`, `ESCALATE`.
- QualityReviewer — tier `${roles.quality_reviewer}` — runs verification (test, lint, type-check), gates Commit. Verdicts: `PASS`, `FAIL-QUALITY`.
- Commit — controller stages Worker's reported file list and commits with the task's message. One commit per task.
- Checkpoint — controller runs milestone-level verification.

**Notes for controller:**
- Retry cap: 3 per failure kind per milestone.
- `FAIL-SPEC` / `FAIL-QUALITY` → re-dispatch failing Worker(s) with reviewer verdict appended.
- `ESCALATE` → pause immediately; plan ↔ spec mismatch needs human fix (`/myspec:feature-update` or re-run `/myspec:feature-plan`).
```

Phase numbers stay globally unique. Cross-milestone deps use `Milestone N` in `Depends On`.

## Task Details

Same Files / Depends on / Spec contract / Touch only shape as normal mode — see `plan-templates.md`. Orchestrator-specific addition: **step ownership annotation**.

Each step inside a task block is owned by exactly one chain role. Worker has no shell → cannot run tests, lint, or git. Plan must reflect that:

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
- Worker steps write files. Reviewer steps run verification. Controller steps run git mutations. No step mixes roles.
- Worker dispatch envelope strips Reviewer/Controller steps from `{{TASK_TEXT}}` — they exist for the human reviewing the plan, not the Worker.
- Exactly one Commit step per task, always last, always Controller, always exact `git commit -m "..."`.

## Mode interaction with Step 5

Orchestrator mode does NOT skip the final holistic review. Chain-level reviews are per-milestone; holistic is end-of-feature. See `orchestrator-dispatcher.md` → "Interaction with Step 5".
