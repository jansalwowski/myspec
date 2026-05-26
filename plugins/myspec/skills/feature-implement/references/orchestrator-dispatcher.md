# Orchestrator Dispatcher (Orchestrator Mode)

Used by `feature-implement` when the plan's front-matter contains `orchestration: agent-chain`. Replaces the normal-mode Phase Review loop with a per-task chain. Step 5 holistic review is unchanged.

No Planner role — see `references/plan-templates-orchestrator.md` § "Why no Planner role".

## Run-mode prompt

At Step 1 of `feature-implement` (after detecting `orchestration: agent-chain`), the BLOCKING `AskUserQuestion` gate in `SKILL.md` Step 1 captures:

- `orchestrator` — pause at every Milestone Checkpoint.
- `orchestrator-auto` — auto-continue on green verification; pause on FAIL-SPEC ≥ 3, FAIL-QUALITY ≥ 3, ESCALATE, or verification failure.
- `normal-fallback` — single-executor; chain skipped.

Disclaimer in SKILL.md is shown every invocation. No default.

## Role split — file edits, verification, commits

Three roles, three responsibilities, no overlap:

| Role | May do | May NOT do |
|------|--------|-----------|
| Worker | Read, Edit, MultiEdit, Write declared files | Run shell, grep, glob, commit, push, run tests, run lint |
| Reviewer (SpecReviewer + QualityReviewer) | Read, Grep, Glob, run verification commands from plan / `.claude/verification.json`, `git diff`, `git log` | Edit files, commit, push, install, mutate state |
| Controller | Dispatch + parse + commit + checkpoint | Edit task-scoped files, run task TDD commands directly |

Controller commits AFTER QualityReview returns `PASS`, using the Worker's reported file list and the commit message from the task block. No exceptions for "small" tasks. The chain's value (gates, retry loop) is unreviewable when the controller bypasses it.

**Most common drift in prod:** Worker hits environment friction (no `node_modules`, no `.eslintcache`, base-ref mismatch). Controller rationalizes "I'll just do this one directly". The fix is ALWAYS to pre-stage in the controller's pre-dispatch step (see "Known limitation: subagent worktrees" below) and re-dispatch. If genuinely unworkable, surface via `AskUserQuestion` with `normal-fallback` as explicit option. Never silently switch lanes.

Self-check before every controller action: *Am I about to Edit/Write a file in feature scope, or run a test/lint/type-check command for task work? If yes — STOP and dispatch the appropriate subagent.*

## Dispatch envelope discipline (shared — applies to every role)

Render the envelope file VERBATIM and substitute only its declared slots. Do NOT add Job / Brief / Current state / Verification / Commit / Report Format wrapper sections. Do NOT include working directory, branch name, session metadata. Do NOT re-inline ROBOT MODE rules or output contracts — those live in the agent definition files (`~/.claude/agents/`, `~/.cursor/agents/`, `~/.codex/agents/`).

Verdict / result block violations (prose around bullets, "Verdict:" prefix, summary paragraphs, missing tags) are agent-prompt bugs, plan-task bugs, or tier bugs. Tighten the envelope, tighten the plan, or escalate tier. Do not loosen the controller parser.

## Per-milestone chain

For each milestone (walked in declaration order). Per task: Worker → SpecReview → QualityReview → Commit. Per milestone: Checkpoint after all tasks complete.

### 1. Worker(s)
- Dispatch one `worker-base` agent per task with the envelope from `references/role-prompts/worker-prompt.md`.
- Worker toolset (enforced in agent file): `Read, Edit, MultiEdit, Write` only. If the plan's task block contains `Reviewer` or `Controller` steps (verify, commit), strip them from `{{TASK_TEXT}}` before substitution.
- Tier resolution: `**Tier override:** worker=<tier>` in the task block → `roles.worker` in plan front-matter → built-in default `cheap`. First hit wins. Reviewer tiers are global. Controller resolves tier to concrete model and passes as per-call `model` parameter.
- Parallel groups: dispatch all group tasks in one message with `isolation: "worktree"` (see `SKILL.md:147–153`). Each worktree carries Worker + both Reviewers + Commit to completion before next group starts.
- Sequential tasks: one at a time. Reviewer runs in the same worktree as the Worker so it sees unstaged edits.
- Output contract: `<result>OK <file-list></result>` (comma-separated paths) or `<result>ERR <reason></result>`. Controller records the file list for the Commit step.

### 2. SpecReview (gate)
- Dispatch ONE `reviewer-base` agent with the envelope from `references/role-prompts/spec-reviewer-prompt.md`. Envelope sets `FAIL label = FAIL-SPEC`.
- Tier: `roles.spec_reviewer` (default `mid`).
- Verdicts:
  - **PASS** → step 3.
  - **FAIL-SPEC** → loop to step 1. Controller appends reviewer bullets verbatim under `## Reviewer verdict (retry N)` in the Worker envelope. Cap: 3 retries; 4th pauses with full trail.
  - **ESCALATE** → plan ↔ spec mismatch; Workers cannot fix. Controller pauses, surfaces verdict, asks for plan fix (`/myspec:feature-update` or re-run `/myspec:feature-plan`).

### 3. QualityReview (gate)
- Gated on SpecReview `PASS`.
- Dispatch ONE `reviewer-base` agent with the envelope from `references/role-prompts/quality-reviewer-prompt.md`. Envelope sets `FAIL label = FAIL-QUALITY`. Reviewer runs verification commands (test, lint, type-check) declared in plan / `.claude/verification.json`.
- Tier: `roles.quality_reviewer` (default `mid`).
- Verdicts:
  - **PASS** → step 4.
  - **FAIL-QUALITY** → loop to step 1 with bullets appended verbatim. Cap: 3 retries; 4th pauses.

### 4. Commit (controller, per task)
- Runs only after that task's SpecReview PASS + QualityReview PASS.
- Stage exactly the file list the Worker reported (no `git add -A`). If the list is empty or includes a path outside the task's declared Files block, fail the task with `ERR scope` and surface both lists for human inspection.
- Commit message comes from the task block's `**Commit:**` line or `git commit -m "..."` literal. Controller does not invent a message.
- Sequential tasks: commit on the feature branch in the controller's worktree. Parallel tasks: commit on each task's worktree; merge at the parallel-group barrier (see `SKILL.md:147–153`).
- Workers and Reviewers do not commit. No exceptions.

### 5. Checkpoint (controller, per milestone)
- Reached only after every task has gone through Worker → SpecReview → QualityReview → Commit.
- Controller runs verification commands from the plan and `.claude/verification.json`.
- Interactive in `orchestrator`: `continue | stop | fresh`. `orchestrator-auto`: auto-continue on all-green; verification failure always pauses.

## Verdict-append protocol (controller responsibility)

On `FAIL-SPEC` or `FAIL-QUALITY`, controller appends one block to the Worker prompt after the inline task text. Extract the inner contents of the reviewer's `<verdict>…</verdict>` block — drop tags, keep body verbatim:

```
## Reviewer verdict (retry N)

<paste body — FAIL-SPEC or FAIL-QUALITY token line + bullet list, no tags>
```

Worker treats this block as authoritative and applies listed fixes verbatim.

## Loop cap

3 retries per failure kind (`FAIL-SPEC`, `FAIL-QUALITY`) per milestone. 4th failure pauses with the full trail. `ESCALATE` pauses immediately — no retry.

## Tier vocabulary

Skill text never names a concrete model.

| Tier | Role default | Hint phrasing |
|------|--------------|---------------|
| `cheap` | Worker | "fast/cheap model — Haiku-tier, GPT-5-mini-tier, or your runtime's small model" |
| `mid` | SpecReviewer, QualityReviewer | "mid-tier model — Sonnet-tier, GPT-5-tier" |
| `premium` | (holistic reviewer only) | "premium model — Opus-tier" |

Plan front-matter `roles:` block: three keys — `worker`, `spec_reviewer`, `quality_reviewer`. No `planner` key.

## Output contracts

Canonical agent definitions at `skills/feature-implement/agents/{claude,cursor,codex}/` (versioned in repo). Installed to user scope at `~/.claude/agents/`, `~/.cursor/agents/`, `~/.codex/agents/` by `/myspec:init` and `/myspec:update`. Manual install: see `skills/feature-implement/agents/README.md`.

| Role | Block tag | Pass body | Fail body |
|------|-----------|-----------|-----------|
| Worker | `<result>…</result>` | `OK <file-list>` (comma-separated paths) | `ERR <one-line reason>` |
| SpecReviewer | `<verdict>…</verdict>` | `PASS` | `FAIL-SPEC` + bullet list (`- <file:line>: <gap>; fix: …`) **OR** `ESCALATE` + one paragraph |
| QualityReviewer | `<verdict>…</verdict>` | `PASS` | `FAIL-QUALITY` + bullet list (`- <file:line>: <issue>; fix: …`) |

### Controller parser semantics

- `grep -ozP '(?s)<result>.*?</result>'` on Worker output → must match exactly one block. Zero or multiple → loud failure, pause the run.
- Same for `<verdict>…</verdict>` on reviewer output.
- Inside the block: first whitespace-trimmed line is the verdict token (`OK`, `ERR`, `PASS`, `FAIL-SPEC`, `FAIL-QUALITY`, `ESCALATE`). For Workers, the remainder of that line is the comma-separated file list (OK) or reason (ERR). For reviewers, subsequent lines are bullet list or escalate paragraph.

If a role agent reliably emits prose outside tags, the issue is the envelope, the plan task, or the tier — not the parser. Bare-token recognition was tried and bled prose preambles past the contract (caught in `7f758d3`). Do not loosen the parser.

## Interaction with Step 5 (holistic review)

Orchestrator mode does NOT skip Step 5. After the final Checkpoint passes, `feature-implement` still:

1. Runs Final Verification.
2. Dispatches the holistic reviewer at `../holistic-reviewer-prompt.md` for the full `BASE_SHA..HEAD` diff.
3. Hands off to `/myspec:feature-complete`.

Chain-level SpecReview + QualityReview are per-milestone. Holistic is end-of-feature. No overlap.

## Auto-mode safety rails

- `orchestrator-auto` valid only when plan front-matter has `orchestration: agent-chain`. Normal plans never run unattended.
- Disclaimer shown every invocation.
- Verification failure always pauses.
- 4th retry of any kind always pauses.
- `ESCALATE` always pauses immediately, regardless of mode.

## Known limitation: subagent worktrees

`isolation: "worktree"` on the `Agent` tool forks the child worktree off the **main checkout's HEAD**, not the controller session's worktree HEAD. Plus child worktrees are bare checkouts — no `node_modules`, no `.eslintcache`. Reviewer needs both. Workers cannot stage either — no shell. Controller pre-stages, before dispatching each Worker into a worktree:

1. **Realign:** `git reset --hard <feature-branch-name>` in the worktree.
2. **Symlink `node_modules`** from parent.
3. **Copy `.eslintcache`** from parent.
4. **After Commit step:** cherry-pick the resulting sha back onto the session's feature branch (FF merge fails because Worker bases diverge from session HEAD).

Parallel groups fork independently — only the merge-back at the parallel-group barrier applies, not the per-dispatch realignment. Tracking: [Issue #11](https://github.com/jansalwowski/myspec/issues/11). Until harness-level fix, this is controller's job.

## Smoke verification (manual)

1. Throwaway feature, one milestone, one trivial task.
2. Set `roles.worker`, `roles.spec_reviewer`, `roles.quality_reviewer` all to the same tier.
3. Run `/myspec:feature-implement`. Confirm BLOCKING run-mode prompt fires before any dispatch. Pick `orchestrator`.
4. Confirm: Worker dispatched with inline task text, no Planner step. Worker output is strict report format only — no prose. SpecReviewer + QualityReviewer verdicts appear in transcript. Controller commits after both PASS. Milestone Checkpoint reached. No `briefs/` directory created.
