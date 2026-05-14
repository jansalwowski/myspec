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

## Controller hard constraint — dispatch only, never execute

In orchestrator and orchestrator-auto modes the controller's job is dispatch + parse + checkpoint. NOT implementation. Every task goes through a Worker subagent. Direct controller edits to task-scoped files, direct `git commit`s of task work, direct execution of TDD commands as part of task execution — all forbidden. Verification commands at the Checkpoint are the ONLY controller-side execution allowed.

This rule exists because the chain's value (SpecReview gate, QualityReview gate, Worker output contract, retry loop) is unreviewable work when the controller bypasses it. A "small" task done directly silently breaks the audit chain. A "I'll save tokens" shortcut produces the failure mode the chain was designed to eliminate.

**Most common drift trigger seen in prod:** Worker hits environment friction (no `node_modules`, no `.eslintcache`, base-ref mismatch). Controller rationalizes "I'll just do this one directly". The correct response is ALWAYS to encode the fix into the Worker prompt's setup step (symlink / reset --hard / cherry-pick — see Known Limitation sections below) and re-dispatch. If the friction is genuinely unworkable, surface it to the user via `AskUserQuestion` with `normal-fallback` as an explicit option. Never silently switch lanes.

Self-check before every controller action: *Am I about to Edit/Write a file in the feature scope, or run a build/test/commit command for task work? If yes — STOP and dispatch a Worker.*

## Per-milestone chain (4 steps)

For each milestone (walked in declaration order):

### 1. Worker(s)
- Dispatch one `worker-base` agent per task. Render the dispatch envelope from `references/role-prompts/worker-prompt.md` and pass it as the agent's prompt body. The agent itself (`~/.claude/agents/worker-base.md`, `~/.cursor/agents/worker-base.md`, or `~/.codex/agents/worker-base.toml`) owns the output contract and ROBOT MODE rules — the envelope owns only per-task content.
- Tier resolution (in order): `**Tier override:** worker=<tier>` line inside the task block → `roles.worker` in plan front-matter → built-in default `cheap`. First hit wins. SpecReviewer + QualityReviewer tiers are global only — they have no per-task override. The controller resolves the tier to a concrete model name and passes it as the per-call `model` parameter on the dispatch invocation (Claude Code Task `model`, Cursor / Codex equivalents); this overrides the agent file's `model: inherit`.
- Parallel groups: dispatch all group tasks in one message with `isolation: "worktree"`, exactly as `SKILL.md:147–153` describes for normal mode.
- Sequential tasks: dispatch one at a time.
- Worker receives the full task text inline. Worker does NOT re-read the plan file.
- **Dispatch wrapper discipline (BLOCKING):** render the worker-prompt envelope VERBATIM and substitute only `{{TASK_TEXT}}` (full task block from plan), `{{FILE_LIST}}` (task's declared file list), and `{{TASK_SHORT_NAME}}` (dispatch description). Do NOT add a "Job", "Brief", "Current state", "Verification", "Commit", or "Report Format" wrapper section around the task. Do NOT include working directory, branch name, brief file path, or session metadata. Do NOT re-inline the ROBOT MODE rules or output contract — those live in the agent definition. Every non-task sentence the controller adds dilutes the robot framing and produces yapping. Verification commands and commit messages already live inside the plan's task block — that is the controller's only payload.
- Worker output contract is one `<result>…</result>` block: `<result>OK <sha></result>` or `<result>ERR <reason></result>`. Anything else is a contract violation — log it for the SpecReviewer and tighten the agent prompt or task text.

### 2. SpecReview (gate)
- Dispatch ONE `reviewer-base` agent. Render the dispatch envelope from `references/role-prompts/spec-reviewer-prompt.md` and pass it as the agent's prompt body. The agent (`~/.claude/agents/reviewer-base.md`, `~/.cursor/agents/reviewer-base.md`, or `~/.codex/agents/reviewer-base.toml`) owns the verdict-block contract and ROBOT MODE rules. The envelope sets `FAIL label = FAIL-SPEC` and supplies the gate logic and inputs.
- Tier: from `roles.spec_reviewer` (default `mid`); resolved to a concrete model and passed as the per-call `model` parameter on the dispatch invocation.
- **Dispatch wrapper discipline (BLOCKING):** render the spec-reviewer envelope VERBATIM and substitute only `{{SPEC_RELEVANT_BLOCK}}`, `{{TECH_SPEC_RELEVANT_BLOCK}}`, `{{PLAN_MILESTONE_BLOCK}}`, and `{{MILESTONE_BASE_SHA}}`. Do NOT add "Job / Inputs / Verification / Report" wrapper sections. Do NOT re-inline the ROBOT MODE rules or output contract — those live in the agent definition. Reviewer output contract is one of three verdict blocks (`PASS` / `FAIL-SPEC` bullets / `ESCALATE` paragraph) with NO prose around them.
- Verdicts (exactly one):
  - **PASS** → step 3.
  - **FAIL-SPEC** → loop to step 1. Controller re-dispatches the failing Worker(s) with the SpecReviewer bullet list appended verbatim under a `## Reviewer verdict` header in the Worker prompt. Cap: 3 retries; 4th failure pauses and surfaces full trail.
  - **ESCALATE** → plan ↔ spec mismatch. Workers cannot fix. Controller pauses, surfaces SpecReviewer verdict block to user, and asks for plan fix (`/myspec:feature-update` or re-run `/myspec:feature-plan`) before resuming.

### 3. QualityReview (gate)
- Gated on SpecReview `PASS` only.
- Dispatch ONE `reviewer-base` agent. Render the dispatch envelope from `references/role-prompts/quality-reviewer-prompt.md` and pass it as the agent's prompt body. The agent owns the verdict-block contract and ROBOT MODE rules. The envelope sets `FAIL label = FAIL-QUALITY` and supplies the checks and scope rules.
- Tier: from `roles.quality_reviewer` (default `mid`); resolved to a concrete model and passed as the per-call `model` parameter on the dispatch invocation.
- **Dispatch wrapper discipline (BLOCKING):** render the quality-reviewer envelope VERBATIM and substitute only `{{MILESTONE_BASE_SHA}}`. Do NOT add "Job / Inputs / Checks / Report" wrapper sections. Do NOT re-inline the ROBOT MODE rules or output contract — those live in the agent definition. Reviewer output contract is one of two verdict blocks (`PASS` / `FAIL-QUALITY` bullets) with NO prose around them.
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

When re-dispatching a Worker on `FAIL-SPEC` or `FAIL-QUALITY`, the controller appends one block to the worker prompt, after the inline task text. Extract the inner contents of the reviewer's `<verdict>…</verdict>` block — drop the tags, keep the body verbatim — and paste under a literal markdown header so the Worker has stable structure to recognize:

```
## Reviewer verdict (retry N)

<paste the body of the reviewer's <verdict> block here — the FAIL-SPEC or
FAIL-QUALITY token line followed by the bullet list, no tags>
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

ROBOT MODE rules and output contracts live in the agent definition files, not in the dispatch envelopes:

- `~/.claude/agents/worker-base.md` / `~/.cursor/agents/worker-base.md` / `~/.codex/agents/worker-base.toml` — Worker role.
- `~/.claude/agents/reviewer-base.md` / `~/.cursor/agents/reviewer-base.md` / `~/.codex/agents/reviewer-base.toml` — Reviewer role (label `FAIL-SPEC` or `FAIL-QUALITY` selected by the envelope per dispatch).

The dispatch envelopes in `references/role-prompts/` carry only per-call inputs (task text, file list, spec/plan blocks, milestone SHA, FAIL label, gate logic). Reasons:
- Atomic plan tasks already contain the code — Workers read, type, commit.
- Reviewers run gates and report verdicts — they do not narrate the process.
- Free-form prose dilutes signal, inflates cost, and breaks the controller's verdict-parsing contract.
- Static rules in one place per harness means a tweak (new forbidden phrase, new failure mode) is one edit per harness, not three.

Output contracts (the controller's parser depends on these). Every role agent wraps its verdict in a machine-parseable delimiter — the controller extracts the single `<result>…</result>` or `<verdict>…</verdict>` block and ignores everything else. Bare-token recognition was tried and bled prose preambles past the contract (caught in `7f758d3`); explicit delimiters make the failure mode loud ("no block found") instead of silent ("misread `PASS — nit:…` as PASS").

| Role | Block tag | Pass body | Fail body |
|------|-----------|-----------|-----------|
| Worker | `<result>…</result>` | `OK <sha>` | `ERR <one-line reason>` |
| SpecReviewer | `<verdict>…</verdict>` | `PASS` | `FAIL-SPEC` + bullet list (`- <file:line>: <gap>; fix: …`) **OR** `ESCALATE` + one-paragraph plan-vs-spec mismatch |
| QualityReviewer | `<verdict>…</verdict>` | `PASS` | `FAIL-QUALITY` + bullet list (`- <file:line>: <issue>; fix: …`) |

Anything outside the tags is logged but not parsed. No `Verdict:` prefix inside the tags. No closing summary. No "Here is my review:" preamble. No mid-execution narration ("Let me check…", "Now I'll…", "Aha!", "Perfect.", "I see…", "First,…").

If a role agent reliably emits prose outside the tags or omits the tags entirely, the issue is the prompt template, the inputs (under-specified plan task), or the model tier — not the controller parser. Tighten the prompt or escalate to a stronger tier. Do not loosen the parser to accept bare tokens.

### Controller parser semantics

- `grep -ozP '(?s)<result>.*?</result>'` on Worker output → must match exactly one block. Zero or multiple matches → loud failure, pause the run.
- Same for `<verdict>…</verdict>` on reviewer output.
- Inside the block: first whitespace-trimmed line is the verdict token (`OK`, `ERR`, `PASS`, `FAIL-SPEC`, `FAIL-QUALITY`, `ESCALATE`). For Workers, the remainder of that line is the sha (OK) or reason (ERR). For reviewers, subsequent lines are the bullet list or escalate paragraph.

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

## Known limitation: subagent worktree base ref

`isolation: "worktree"` on the `Agent` tool forks the child worktree off the **main checkout's HEAD**, not off the controller session's current worktree HEAD. When the controller is itself running inside a worktree (the common orchestrator case), sequential Workers in the same milestone do NOT see commits made by prior Workers — each Worker sees only the main checkout's branch state.

Tracking: [Issue #11](https://github.com/jansalwowski/myspec/issues/11). Pending an `Agent`-tool-level fix (either fork-from-session-HEAD or `baseRef` parameter), apply this workaround in the controller dispatch flow:

1. **Worker Step 0 (forced realignment).** When dispatching a Worker, prepend to the task block:
   ```
   ## Step 0 — realign worktree
   git reset --hard <feature-branch-name>
   ```
   This pulls the feature branch's latest state into the freshly-forked worktree before the Worker starts editing.

2. **Controller cherry-pick on Worker success.** After Worker returns `OK <sha>`, the controller cherry-picks `<sha>` from the worker worktree back onto the session's feature branch. A straight FF merge won't work because the Worker bases diverge from the session HEAD.

3. **Parallel groups are unaffected** — they fork independently anyway. The issue only bites sequential dispatch within a milestone.

This workaround is verbose; document it explicitly in the milestone's first Worker prompt so the Worker doesn't strip it as "setup meta the template forbids".

## Known limitation: subagent worktrees lack node_modules and lint cache

Subagent worktrees are bare checkouts. They have no `node_modules` and no `.eslintcache`. TDD verification commands and Stop-hook lint can fail spuriously. Workarounds (symlink parent's `node_modules`, copy `.eslintcache`) live in [Issue #11](https://github.com/jansalwowski/myspec/issues/11). Until the harness pre-populates these, Worker prompts may need a setup step that performs the symlink/copy before running verification.

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
