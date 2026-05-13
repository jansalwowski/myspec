# Plan Document Templates — Orchestrator Mode

Use this template when the user selects orchestrator mode at Step 0 of `feature-plan`. For normal mode, see [`plan-templates.md`](./plan-templates.md). Task Details shape is structurally identical so a plan can be flipped between modes without rewriting per-task content.

## Front-matter

Every orchestrator plan starts with this YAML block. `orchestration: agent-chain` is what `feature-implement` detects to switch dispatch modes.

```yaml
---
feature: <feature-name>
spec_version: <int>
orchestration: agent-chain
roles:
  planner: mid
  worker: cheap
  spec_reviewer: mid
  quality_reviewer: mid
---
```

`roles` values are tier names (`cheap`, `mid`, `premium`). The controller (main thread) maps tier → concrete model based on the runtime's available models. Skill text never names a concrete model.

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
- Planner — tier `${roles.planner}` — produces `${aiDir}/features/<feature>/briefs/m<n>.md`
- Workers — tier `${roles.worker}` — one per task, parallel where Mode allows
- SpecReviewer — tier `${roles.spec_reviewer}` — gates QualityReviewer
- QualityReviewer — tier `${roles.quality_reviewer}` — gates Checkpoint
- Checkpoint — controller runs verification, prompts unless `orchestrator-auto`

**Notes for controller:**
- Retry cap: 3 per failure kind per milestone (FAIL-SPEC, FAIL-QUALITY)
- FAIL-SPEC → loop to Planner; FAIL-QUALITY → loop to same Worker
- Briefs persist across retries (Planner appends `## Retry N` deltas)
```

Phase numbers stay globally unique across milestones. Cross-milestone dependencies use `Milestone N` in `Depends On`.

## Task Details

Structurally identical to normal-mode plan template — keep the same Files / Depends on / TDD steps / Run commands / Commit message shape so a feature can flip between modes without rewriting tasks. See `plan-templates.md` for the per-task block.

The only orchestrator-specific additions per milestone are the **Chain** and **Notes for controller** blocks above.

## Mode interaction with Step 5

Orchestrator mode does NOT skip the final holistic review. After the last Milestone Checkpoint, `feature-implement` still runs Final Verification and dispatches `holistic-reviewer-prompt.md` for the whole-feature diff. SpecReview + QualityReview are per-milestone; holistic is end-of-feature.
