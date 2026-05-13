# Orchestrator Dispatcher (Orchestrator Mode)

Used by `feature-implement` when the plan's front-matter contains `orchestration: agent-chain`. Replaces the normal-mode Phase Review loop with a 5-step chain per milestone. Milestone Checkpoint and Step 5 holistic review are unchanged.

## Run-mode prompt

At Step 1 (after parsing the plan and detecting `orchestration: agent-chain`), prompt the user:

```
Plan was authored in orchestrator mode. Run modes:
  [1] orchestrator (matches plan, recommended)
  [2] orchestrator-auto (no checkpoint prompts on green verification)
  [3] normal-fallback (treat as single-executor; skip role chain)

Disclaimer: orchestrator-auto runs end-to-end without per-milestone prompts.
It only pauses on FAIL-SPEC ≥ 3, FAIL-QUALITY ≥ 3, or verification command failure.
Use only for plans you have already reviewed.
```

Show the disclaimer every invocation. Selection drives the controller loop below.

## Per-milestone chain

For each milestone (walked in declaration order):

### 1. Planner
- Dispatch ONE agent using `references/role-prompts/planner-prompt.md`.
- Tier: from `roles.planner` in plan front-matter (default `mid`).
- Output: `${aiDir}/features/<feature>/briefs/m<n>.md`.
- On retry: planner appends a `## Retry N` block, does not rewrite.

### 2. Worker(s)
- For each task in the milestone, dispatch ONE agent using `references/role-prompts/worker-prompt.md`.
- Tier: from `roles.worker` (default `cheap`).
- Parallel groups: dispatch all group tasks in one message with `isolation: "worktree"`, exactly as `SKILL.md:147–153` describes for normal mode.
- Sequential tasks: dispatch one at a time.
- Each worker reads only its section of the brief.

### 3. SpecReview (gate)
- Dispatch ONE agent using `references/role-prompts/spec-reviewer-prompt.md`.
- Tier: from `roles.spec_reviewer` (default `mid`).
- Verdict: `PASS` → step 4; `FAIL-SPEC` → loop to step 1 with the verdict appended to the brief. Cap: 3 retries; 4th failure pauses and surfaces the full trail.

### 4. QualityReview (gate)
- Gated on SpecReview PASS only.
- Dispatch ONE agent using `references/role-prompts/quality-reviewer-prompt.md`.
- Tier: from `roles.quality_reviewer` (default `mid`).
- Verdict: `PASS` → step 5; `FAIL-QUALITY` → loop to step 2 (same Worker, Planner NOT re-invoked). Cap: 3 retries; 4th failure pauses and surfaces the full trail.

### 5. Checkpoint
- Controller runs verification commands from the plan and `.claude/verification.json`.
- Interactive in `orchestrator`: `continue | stop | fresh` (same shape as normal mode).
- `orchestrator-auto`: auto-continue on all-green. Verification failure always pauses regardless of mode.

## Loop cap

3 retries per kind (`FAIL-SPEC`, `FAIL-QUALITY`) per milestone. On the 4th failure, pause with full trail: briefs (all retry deltas), Worker diffs, every reviewer verdict.

## Tier vocabulary

Skill text never names a concrete model. Use tier names with example hints:

| Tier | Role default | Hint phrasing |
|------|--------------|---------------|
| `cheap` | Worker | "fast/cheap model — e.g. Haiku-tier, GPT-5-mini-tier, or your runtime's small model" |
| `mid` | Planner, SpecReviewer, QualityReviewer | "mid-tier model — e.g. Sonnet-tier, GPT-5-tier" |
| `premium` | (not used in chain; holistic reviewer only) | "premium model — e.g. Opus-tier" |

Plan front-matter `roles:` block exposes the mapping so users can override per feature.

## Brief lifecycle

`${aiDir}/features/<feature>/briefs/m<n>.md` is a scratch artifact.

- **During run**: created by Planner, appended on FAIL-SPEC retries.
- **On `stop` / `fresh` at any checkpoint**: kept on disk so a resume can reuse the trail.
- **After final milestone**: when verification is green AND the user accepts the last checkpoint (or `/myspec:feature-complete` runs), delete the entire `${aiDir}/features/<feature>/briefs/` directory.

Briefs are not history. The plan is the durable record.

## Interaction with Step 5 (holistic review)

Orchestrator mode does NOT skip Step 5. After the final milestone's Checkpoint passes, `feature-implement` still:

1. Runs Final Verification.
2. Dispatches the holistic reviewer at `../holistic-reviewer-prompt.md` for the full `BASE_SHA..HEAD` diff.
3. Hands off to `/myspec:feature-complete`.

Chain-level SpecReview + QualityReview are per-milestone scoped. Holistic is end-of-feature scoped. They do not overlap.

## Auto-mode safety rails

- `orchestrator-auto` is valid only when plan front-matter has `orchestration: agent-chain`. Normal plans never run unattended.
- Disclaimer shown every invocation (not only first).
- Verification command failure always pauses.
- 4th retry of any kind always pauses.

## Smoke verification (manual)

1. Create a throwaway feature with one milestone and one trivial task.
2. Set all four `roles:` tiers to the same model (so behavior is observable without cost).
3. Run `/myspec:feature-implement`. Pick orchestrator mode.
4. Confirm:
   - `${aiDir}/features/<feature>/briefs/m1.md` exists after Planner.
   - Worker diff applied (one or more commits).
   - SpecReviewer verdict and QualityReviewer verdict appear in transcript.
   - Milestone Checkpoint reached.
   - On green verification + user accepts last checkpoint, `briefs/` is deleted.
