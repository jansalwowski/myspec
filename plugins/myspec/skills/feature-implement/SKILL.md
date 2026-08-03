---
name: feature-implement
tags: [feature, implementation, execution, parallel, worktree]
description: "Use when executing an implementation-plan.md from ${aiDir}/features/ — dispatches subagents per task, parallelizing when the plan allows (worktree isolation). Keywords: execute plan, implement feature, run plan, start implementation. Do NOT use for creating plans (feature-plan), for debugging (root-cause-debugging), or for plans without an Execution Order table."
---

# Feature Implement

Execute a feature implementation plan by dispatching subagents per task and reviewing at phase boundaries.

**Announce at start:** "Executing feature-implement on `${aiDir}/features/{feature}/implementation-plan.md`."

## Execution Model

**Milestone** = a vertical slice of the feature (BE → FE → tests). Top-level execution unit. Agent checkpoints occur at milestone boundaries.
**Phase** = a group of tasks within a milestone, ending at a barrier. Nothing should break when a phase completes.
**Task** = a unit of work dispatched to a subagent. Sequential or parallel within a phase.
**Phase review** = after each phase: spec compliance, code quality, test coverage, docs consistency.
**Milestone checkpoint** = after all phases in a milestone: verify all tasks done, ask user to continue / stop / fresh.

## Task Status Tracking

Plans use three checkbox states:

| Status | Meaning | When to set |
|--------|---------|-------------|
| `[ ]` | Todo | Default state in generated plans |
| `[~]` | In progress | Before dispatching a task's subagent |
| `[x]` | Done | After task subagent completes AND phase review passes |

**Rules:**

1. **Before dispatching a task's subagent:** edit the plan file, change `[ ]` → `[~]`
2. **After phase review passes for that task:** edit the plan file, change `[~]` → `[x]`
3. **If task fails and agent retries:** leave as `[~]` — only mark `[x]` after success
4. **If agent stops/crashes mid-task:** `[~]` remains in the file — new agent detects it during resume
5. **Never mark `[x]` before phase review confirms the task passes**

**Scope:** Task-level checkboxes (`### Task N:` steps). Barrier sub-steps use `[ ]`/`[x]` only (no `[~]`).

## Workflow

### Step 0: Confirm Implementation Flow (BLOCKING)

Before parsing the plan or dispatching any work, confirm where implementation
will happen. Always ask — even when prior state makes the answer obvious.

**1. Inspect current state** (REQUIRED reference: [`skills/_shared/git-helpers.md`](../_shared/git-helpers.md)):

- Resolve default branch (main vs master)
- Current `HEAD` branch name
- Working tree clean? (`git status --porcelain` empty)
- Existing worktree for this feature? (`git worktree list` contains `feat-{name}`)
- Plan has `[parallel:*]` groups?

**2. Pre-flight: dirty tree must be resolved first.**

If `git status --porcelain` is non-empty, ask the user to commit or stash
before proceeding. Do not switch branches or create a worktree on top of
unrelated changes. If the dirty files are exactly the feature's spec/plan
files, this is the symptom Step 7 of `/myspec:feature-plan` is meant to
prevent — offer to commit them now with the default message.

**3. Compute recommendation:**

| State | Recommended option |
|-------|--------------------|
| Worktree for this feature already exists | "Worktree" (reuse) |
| Plan has `[parallel:*]` groups, no worktree yet | "Worktree" |
| HEAD is already `feat/{name}` (or equivalent) | "Current branch" |
| HEAD == default branch | "New branch feat/{name}" |

**4. Ask via `AskUserQuestion`:**

```
question: "How should implementation proceed?"
header:   "Impl flow"
options:
  - "Worktree feat-{name}"        → .claude/worktrees/feat-{name}
                                     (best for parallel tasks; isolated)
  - "Current branch {HEAD}"        → continue on the existing branch
  - "New branch feat/{name}"       → create feat/{name} and switch
  - "Main branch"                  → not recommended; only for trivial fixes
```

- Order so the recommended option is first with `(Recommended — {why})` appended
  (e.g. `(Recommended — plan has parallel groups)`).
- Always ask, even when the recommendation is unambiguous. Confirmation is cheap;
  silent assumption is the bug.

**5. Auto-execute the choice:**

- **Worktree:** if path exists → enter it; else create via the EnterWorktree
  tool (or `git worktree add .claude/worktrees/feat-{name} -b feat/{name}`
  if EnterWorktree isn't available in this session).
- **New branch:** `git checkout -b feat/{name}`. If branch exists, offer
  checkout vs. numeric suffix (`feat/{name}-2`).
- **Current branch:** no-op.
- **Main branch:** require explicit confirmation; record the user's reason so
  reviewers see it in the commit history.

### Step 1: Parse Plan → Execution DAG

Read the implementation plan. **Check front-matter first.**

**If front-matter contains `orchestration: agent-chain` — BLOCKING run-mode gate:**

Before dispatching ANY agent, before any further parsing, before announcing what you'll do — call `AskUserQuestion` and WAIT for the user's choice. Do not proceed on a default. Do not assume. Do not skip.

```
question: "Plan was authored in orchestrator mode. Run mode?"
header:   "Run mode"
options:
  - "orchestrator"        → matches plan; pauses at every Milestone Checkpoint (Recommended)
  - "orchestrator-auto"   → no checkpoint prompts on green verification; only pauses on
                            FAIL-SPEC ≥ 3, FAIL-QUALITY ≥ 3, or verification failure
  - "normal-fallback"     → treat as single-executor; skip role chain
```

Always display this disclaimer above the question, every invocation:

```
Orchestrator-auto runs end-to-end without per-milestone prompts. Chained autonomy
across roles is more surface for cascading errors. Use only for plans you have
already reviewed.
```

Record the user's choice. Only after the choice is captured, **REQUIRED:** read `references/orchestrator-dispatcher.md` for the 5-step chain (Worker(s) → SpecReview → QualityReview → Commit → Checkpoint), loop caps, and the verdict-append retry protocol. Steps 2, 4b, and 5 below still apply unchanged; orchestrator mode replaces Step 4 (Phase Review) with the per-milestone chain.

#### HARD CONSTRAINT — controller MUST NOT execute tasks directly (orchestrator + orchestrator-auto)

Once the user selects `orchestrator` or `orchestrator-auto`, the controller's role is **dispatch only**. Every plan task is implemented by a Worker subagent dispatched via the `Agent` tool with `isolation: "worktree"`. The controller writes ZERO code, edits ZERO files in the feature scope, runs ZERO Bash commands that modify the working tree.

**Forbidden controller actions in orchestrator mode:**
- Using `Edit`, `Write`, or `NotebookEdit` on files declared in any task's file list
- Running `git commit`, `git add`, `yarn install`, code-generation scripts, or test commands as part of task execution (verification commands at Checkpoint are the only exception)
- "Just doing this one task directly" because Worker dispatch hit friction
- Bypassing the chain on the final task, a small task, a "trivial" task, or a retry

**Environment friction is NEVER a valid bypass reason.** If a Worker can't install deps, can't find `node_modules`, can't run lint, can't see prior milestone commits — fix it **inside the Worker prompt's setup step** (symlink, reset, cherry-pick — see `references/orchestrator-dispatcher.md` "Known limitation" sections). Then re-dispatch. Do not absorb the work into the controller.

**Self-check before every action in orchestrator mode:** "Am I about to edit a file / run a build command / commit? If yes — STOP. Dispatch a Worker instead." If the friction looks insurmountable, surface it to the user with `AskUserQuestion` and let them choose `normal-fallback` explicitly. Do not silently drift to direct execution.

Violating this constraint defeats the entire purpose of orchestrator mode (autonomous self-reviewing chain) and produces unreviewable work — no SpecReview, no QualityReview, no Worker output contract. It is a contract breach, not a shortcut.

If `orchestration` is absent, continue in normal mode below — no run-mode prompt.

Parse milestones first, then build a DAG within each:

1. **Identify milestones:** Each `### Milestone N:` heading scopes a milestone. If no milestone headings exist, treat the entire plan as a single implicit milestone (backward compatibility).
2. **For each milestone**, extract the Execution Order table and build a DAG:
   - Nodes = tasks + barriers. Edges = `Depends On` column.
   - Identify phases (task groups separated by barriers).
   - Identify parallel groups (rows with `**parallel:groupName**` in Mode).
   - Identify dual-stream forks (phases with `3a`/`3b` style rows — two simultaneous chains).
3. **Cross-milestone dependencies:** If a milestone's first phase says `Depends On: Milestone N`, the entire previous milestone must be complete before this one starts.

**Resume detection (on startup):**
- Scan all task checkboxes in the plan file
- `[x]` = already done — skip entirely
- `[~]` = was in progress when previous agent stopped — re-execute this task from scratch
- `[ ]` = todo — execute normally
- Find the first milestone containing any non-`[x]` task. Resume from there.

**Validate before starting:**
- Every task in every Execution Order table has a `### Task N:` section.
- Every parallel group has a `## Barrier:` section.
- Parallel tasks have zero file overlap (check file lists — if they share a file, treat as sequential).
- Phase numbers are globally unique (no duplicates across milestones).

### Step 2: Setup

1. Verify Step 0's chosen branch/worktree is active (`git rev-parse --abbrev-ref HEAD` matches the chosen target). If not, bail out and re-run Step 0.
2. Record `BASE_SHA`: `git rev-parse HEAD`
3. Set the feature's `status: in-progress` in `${aiDir}/features/index.yaml` (owner of the `draft → in-progress` transition; `feature-complete` later flips it to `complete`).
4. Create task tracking with all tasks.

### Step 3: Execute Milestones

Walk milestones in order. For each milestone, walk its DAG topologically. For each phase:

**Sequential tasks** — dispatch one subagent at a time:

```
Dispatch implementer (./implementer-prompt.md)
  → DONE: proceed
  → DONE_WITH_CONCERNS: read concerns, decide before proceeding
  → NEEDS_CONTEXT: provide missing info, re-dispatch
  → BLOCKED: assess (more context / better model / break down / escalate to user)
```

**Parallel tasks** — dispatch ALL group tasks simultaneously in ONE message:

```
Validate file disjointness → dispatch Task N, Task M, Task K as separate
Agent calls with isolation: "worktree" in the same message → track per-task status
→ If one fails: keep successful worktrees, fix the failed task, then barrier
```

**Dual-stream fork** — dispatch both stream heads simultaneously with worktree isolation. Each stream proceeds independently (with its own sequential/parallel phases). Join waits for both streams.

### Step 4: Phase Review

After all tasks in a phase complete:

**a) Barrier merge** (parallel tasks only):
- Merge worktrees back to the feature branch **one at a time**.
- On conflict: attempt resolution (auto-generated files like lockfiles, codegen output → take union). Escalate to user if truly stuck.
- Run barrier verification commands from the plan (typecheck, tests).

**b) Dispatch phase reviewer** (`./phase-reviewer-prompt.md`):
- Covers ALL tasks in the phase: spec compliance, code quality, test coverage, integration, docs.
- Returns: `APPROVED` or `ISSUES_FOUND` with specifics.

**c) Fix loop:**
- If `ISSUES_FOUND` → dispatch fix agent with specific issues → re-dispatch phase reviewer.
- Repeat until `APPROVED`.

**d) Mark phase complete:** all task checkboxes in the phase are now `[x]`, unlock downstream phases within the milestone.

**e) Inter-phase progress note** (within a milestone, no pause — proceed immediately):

```
✓ Phase N complete: [phase name]
  Next: Phase N+1 — [phase name] ([N tasks])
```

After all phases in a milestone complete → proceed to **Step 4b: Milestone Checkpoint**.

### Step 4b: Milestone Checkpoint

After all phases in a milestone complete (skip this step only for the final milestone — go directly to Step 5):

**a) Verify milestone completion:**
- All task checkboxes within this milestone are `[x]` (no `[~]` or `[ ]` remaining)
- All barrier verification commands passed
- Run verification commands from `.claude/verification.json` (test, typecheck)

**b) Pause and ask user:**

```
═══ Milestone N complete: [milestone name] ═══

  Completed: [list of task names]
  Next: Milestone N+1 — [milestone name] ([N tasks])

  continue  → proceed to Milestone N+1 in this session
  stop      → commit all changes, exit (resume later with /feature-implement)
  fresh     → commit all changes, exit — start fresh /feature-implement session next

  Choice?
```

- **continue** → proceed to next milestone
- **stop** → ensure all changes committed, output: "Stopped after Milestone N. Resume with `/myspec:feature-implement` — it will detect completed milestones via `[x]` checkboxes.", then exit
- **fresh** → same as stop, additionally output: "Recommended: start a fresh `/myspec:feature-implement` session. The new agent will auto-detect progress from checkbox state and resume from Milestone N+1."

### Step 5: Completion

1. Run Final Verification section from the plan.
2. Dispatch holistic reviewer (`./holistic-reviewer-prompt.md`) for full diff `BASE_SHA..HEAD`. This is the quick in-flight gate; the deeper independent conformance audit lives in `/myspec:feature-implement-review`.
3. **Ask the user what to do next** via `AskUserQuestion` — do not auto-hand-off:

```
question: "Implementation complete. What next?"
header:   "Next step"
options:
  - "feature-implement-review" → independent audit that the code fulfills the spec and
                                  plan (traceability + behavioral), persists a report
                                  (Recommended for anything non-trivial)
  - "code-review"               → quality, standards, and bug review of the changes
                                  (universal dimensions + any project rules)
  - "feature-complete"          → skip the reviews; sync docs, archive plan, merge
  - "Stop here"                 → leave the branch as-is; continue later
```

Execute the choice: invoke `/myspec:feature-implement-review`, `/myspec:code-review`, `/myspec:feature-complete`, or stop and report the branch name. The two review passes are complementary, not exclusive (conformance vs. code quality) — after one finishes, offer this choice again so the user can run the other or proceed.

**Orchestrator mode interaction:** Step 5 runs identically in both modes. Per-milestone SpecReview + QualityReview are scoped to one milestone's diff; the holistic reviewer covers the whole feature. They do not overlap and orchestrator mode does NOT skip Step 5. No `briefs/` directory is created — Workers receive task text inline.

## Model Selection

Skill text uses **tier names** (`cheap` / `mid` / `premium`). Controller (main thread) maps tier → concrete model based on runtime availability. Plugin runs across Claude Code, Codex, Cursor, etc. — no hardcoded model IDs.

| Role | Complexity | Tier | Hint (controller picks concrete model) |
|------|-----------|------|----------------------------------------|
| Implementer | 1-2 files, mechanical | `cheap` | e.g. Haiku-tier, GPT-5-mini-tier, or runtime's small model |
| Implementer | Multi-file, integration | `mid` | e.g. Sonnet-tier, GPT-5-tier |
| Phase reviewer | — | `mid` | e.g. Sonnet-tier, GPT-5-tier |
| Final holistic reviewer | — | `premium` | e.g. Opus-tier |
| Orchestrator SpecReviewer / QualityReviewer | — | `mid` | e.g. Sonnet-tier, GPT-5-tier |
| Orchestrator Worker | — | `cheap` | e.g. Haiku-tier, GPT-5-mini-tier |

Orchestrator-mode plans override defaults via the `roles:` front-matter block.

## Error Handling

| Situation | Action |
|-----------|--------|
| BLOCKED | More context → re-dispatch; better model; break down; or ask user |
| NEEDS_CONTEXT | Provide info, re-dispatch |
| One parallel task fails | Keep other worktrees, fix failed, then barrier |
| Merge conflict at barrier | Attempt resolution; escalate if stuck |
| Verification fails at barrier | Identify offending task, dispatch fix agent |
| 3+ attempts same task | Escalate: "I've made N attempts. What I tried: [list]." |

## Constraints

**Never:**
- Dispatch parallel tasks that share files — the worktree merge will conflict on shared paths
- Make subagent read the plan file — provide full task text inline so the subagent has no parsing to do
- Skip barrier verification commands — they're how the phase fails fast on broken merges
- Proceed past 3 failed attempts without escalating — the issue won't fix itself on attempt 4

## Verification Checklist

After all phases complete:

- [ ] All plan task checkboxes marked `[x]` in implementation-plan.md (no `[~]` or `[ ]` remaining)
- [ ] All barrier verification commands passed (typecheck, tests)
- [ ] Holistic reviewer returned `APPROVED`
- [ ] No uncommitted changes from implementation
- [ ] Read `.claude/verification.json` and run each required check — all pass

## Integration

**Called by** [REQUIRED — an approved plan must exist]: `/myspec:feature-plan` (after plan approval)
**Next** [OPTIONAL reviews, then REQUIRED completion]: `/myspec:feature-implement-review` (conformance audit) and/or `/myspec:code-review` (quality review), then `/myspec:feature-complete` — chosen by the user in Step 5
