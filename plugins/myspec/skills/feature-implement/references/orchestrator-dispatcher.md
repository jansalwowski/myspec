# Orchestrator Dispatcher (Orchestrator Mode)

Used by `feature-implement` when the plan's front-matter contains `orchestration: agent-chain`. Replaces the normal-mode Phase Review loop with a 4-step chain per milestone. Milestone Checkpoint and Step 5 holistic review are unchanged.

## Why no Planner role?

`feature-plan` task templates already mandate atomic tasks: exact file paths, complete code (not "add validation" but the actual validation code), TDD sequence with run commands, self-contained subagent context. Inserting a Planner agent to re-derive these from spec/tech-spec is tautological — it spends tokens to rewrite what the plan already says, and adds drift surface (Planner may "improve" tasks and diverge from the approved plan).

The plan IS the brief. Workers consume task text directly.

## Run-mode prompt

At Step 1 of `feature-implement` (after detecting `orchestration: agent-chain` in plan front-matter), the BLOCKING `AskUserQuestion` gate defined in `SKILL.md` Step 1 captures the user's run-mode choice:

- `orchestrator` — pause at every Milestone Checkpoint.
- `orchestrator-auto` — auto-continue on green verification; pause on FAIL-SPEC ≥ 3, FAIL-QUALITY ≥ 3, ESCALATE, or verification failure.
- `normal-fallback` — single-executor; chain is skipped.

The disclaimer in SKILL.md is shown every invocation. Do not proceed on a default.

## Per-milestone chain (4 steps)

For each milestone (walked in declaration order):

### 1. Worker(s)
- Dispatch one agent per task using `references/role-prompts/worker-prompt.md`.
- Tier: from `roles.worker` in plan front-matter (default `cheap`).
- Parallel groups: dispatch all group tasks in one message with `isolation: "worktree"`, exactly as `SKILL.md:147–153` describes for normal mode.
- Sequential tasks: dispatch one at a time.
- Worker receives the full task text inline. Worker does NOT re-read the plan file.
- **Dispatch wrapper discipline (BLOCKING):** paste the worker-prompt template VERBATIM and substitute only `{{TASK_TEXT}}` (full task block from plan), `{{FILE_LIST}}` (task's declared file list), and `{{TASK_SHORT_NAME}}` (dispatch description). Do NOT add a "Job", "Brief", "Current state", "Verification", "Commit", or "Report Format" wrapper section around the task. Do NOT include working directory, branch name, brief file path, or session metadata. Every non-task sentence the controller adds dilutes the robot framing and produces yapping. Verification commands and commit messages already live inside the plan's task block — that is the controller's only payload.
- Worker output contract is two-line max: `OK <sha>` or `ERR <reason>`. Anything else is a contract violation — log it for the SpecReviewer and tighten the Worker prompt or task text.

### 2. SpecReview (gate)
- Dispatch ONE agent using `references/role-prompts/spec-reviewer-prompt.md`.
- Tier: from `roles.spec_reviewer` (default `mid`).
- **Dispatch wrapper discipline (BLOCKING):** paste the spec-reviewer template VERBATIM and substitute only `{{SPEC_RELEVANT_BLOCK}}`, `{{TECH_SPEC_RELEVANT_BLOCK}}`, `{{PLAN_MILESTONE_BLOCK}}`, and `{{MILESTONE_BASE_SHA}}`. Do NOT add "Job / Inputs / Verification / Report" wrapper sections. Reviewer output contract is one of three verdict blocks (`PASS` / `FAIL-SPEC` bullets / `ESCALATE` paragraph) with NO prose around them.
- Verdicts (exactly one):
  - **PASS** → step 3.
  - **FAIL-SPEC** → loop to step 1. Controller re-dispatches the failing Worker(s) with the SpecReviewer bullet list appended verbatim under a `## Reviewer verdict` header in the Worker prompt. Cap: 3 retries; 4th failure pauses and surfaces full trail.
  - **ESCALATE** → plan ↔ spec mismatch. Workers cannot fix. Controller pauses, surfaces SpecReviewer verdict block to user, and asks for plan fix (`/myspec:feature-update` or re-run `/myspec:feature-plan`) before resuming.

### 3. QualityReview (gate)
- Gated on SpecReview `PASS` only.
- Dispatch ONE agent using `references/role-prompts/quality-reviewer-prompt.md`.
- Tier: from `roles.quality_reviewer` (default `mid`).
- **Dispatch wrapper discipline (BLOCKING):** paste the quality-reviewer template VERBATIM and substitute only `{{MILESTONE_BASE_SHA}}`. Do NOT add "Job / Inputs / Checks / Report" wrapper sections. Reviewer output contract is one of two verdict blocks (`PASS` / `FAIL-QUALITY` bullets) with NO prose around them.
- Verdicts:
  - **PASS** → step 4.
  - **FAIL-QUALITY** → loop to step 1. Controller re-dispatches the same Worker(s) with the QualityReviewer bullet list appended verbatim under a `## Reviewer verdict` header. Cap: 3 retries; 4th failure pauses.

### 4. Checkpoint
- Controller runs verification commands from the plan and `.claude/verification.json`.
- Interactive in `orchestrator`: `continue | stop | fresh` (same shape as normal mode).
- `orchestrator-auto`: auto-continue on all-green. Verification failure always pauses regardless of mode.

## Loop cap

3 retries per failure kind (`FAIL-SPEC`, `FAIL-QUALITY`) per milestone. On the 4th failure, pause with the full trail: every Worker diff, every reviewer verdict. `ESCALATE` pauses immediately — no retry.

## Verdict-append protocol (controller responsibility)

When re-dispatching a Worker on `FAIL-SPEC` or `FAIL-QUALITY`, the controller appends one block to the worker prompt, after the inline task text:

```
## Reviewer verdict (retry N)

<paste the FAIL-SPEC or FAIL-QUALITY findings verbatim from the reviewer>
```

The Worker prompt instructs the agent to treat this block as authoritative and apply the listed fixes verbatim without re-interpretation.

## Tier vocabulary

Skill text never names a concrete model. Use tier names with example hints:

| Tier | Role default | Hint phrasing |
|------|--------------|---------------|
| `cheap` | Worker | "fast/cheap model — e.g. Haiku-tier, GPT-5-mini-tier, or your runtime's small model" |
| `mid` | SpecReviewer, QualityReviewer | "mid-tier model — e.g. Sonnet-tier, GPT-5-tier" |
| `premium` | (not used in chain; holistic reviewer only) | "premium model — e.g. Opus-tier" |

Plan front-matter `roles:` block exposes the mapping. Three keys only: `worker`, `spec_reviewer`, `quality_reviewer`. No `planner` key.

## Token discipline (all role agents)

All three role prompts (`worker-prompt.md`, `spec-reviewer-prompt.md`, `quality-reviewer-prompt.md`) enforce ROBOT MODE: tool calls only, no narration, restricted output blocks. Reasons:
- Atomic plan tasks already contain the code — Workers read, type, commit.
- Reviewers run gates and report verdicts — they do not narrate the process.
- Free-form prose dilutes signal, inflates cost, and breaks the controller's verdict-parsing contract.

Output contracts (the controller's parser depends on these):

| Role | Pass | Fail |
|------|------|------|
| Worker | `OK <sha>` | `ERR <one-line reason>` |
| SpecReviewer | `PASS` | `FAIL-SPEC` + bullet list (`- <file:line>: <gap>; fix: …`) **OR** `ESCALATE` + one-paragraph plan-vs-spec mismatch |
| QualityReviewer | `PASS` | `FAIL-QUALITY` + bullet list (`- <file:line>: <issue>; fix: …`) |

No prose around the verdict blocks. No `Verdict:` prefix. No closing summary. No "Here is my review:" preamble. No mid-execution narration ("Let me check…", "Now I'll…", "Aha!", "Perfect.", "I see…", "First,…").

If a role agent reliably exceeds discipline, the issue is the prompt template, the inputs (under-specified plan task), or the model tier — not the controller parser. Tighten the prompt or escalate to a stronger tier. Do not loosen the contract.

If a Worker reliably exceeds this discipline, the issue is the plan task (under-specified) — not the Worker prompt. Tighten the plan.

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
- `ESCALATE` (plan ↔ spec mismatch) always pauses immediately, regardless of mode.

## Smoke verification (manual)

1. Create a throwaway feature with one milestone and one trivial task.
2. Set `roles.worker`, `roles.spec_reviewer`, `roles.quality_reviewer` all to the same tier (so behavior is observable without cost variation).
3. Run `/myspec:feature-implement`. Confirm BLOCKING run-mode prompt fires before any dispatch. Pick `orchestrator`.
4. Confirm:
   - Worker dispatched directly with inline task text (no Planner step).
   - Worker output matches strict report format only — no prose.
   - Worker diff applied (one or more commits).
   - SpecReviewer verdict and QualityReviewer verdict appear in transcript.
   - Milestone Checkpoint reached.
   - On green verification + user accepts last checkpoint, run completes without leaving a `briefs/` directory anywhere (none should ever have been created).
