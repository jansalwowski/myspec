---
name: feature-implement
tags: [feature-workflow, implementation, execution, parallel, worktree]
description: "Use when executing an implementation-plan.md from ai/features/. Uses subagents per task — parallelizes when plan allows (worktree isolation). Handles [parallel:groupName] tags, Execution Order tables, barrier sections, dual-stream fork/join. Keywords: execute plan, implement feature, run plan, start implementation. Do NOT use for creating plans (use feature-plan), for debugging (use dispatching-parallel-agents), or for plans without Execution Order table."
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

**Rules (BLOCKING — must follow exactly):**

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

Read the implementation plan. Parse milestones first, then build a DAG within each:

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
3. Create task tracking with all tasks.

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
2. Dispatch holistic reviewer (`./holistic-reviewer-prompt.md`) for full diff `BASE_SHA..HEAD`.
3. Hand off to `/myspec:feature-complete`.

## Model Selection

| Role | Complexity | Model |
|------|-----------|-------|
| Implementer | 1-2 files, mechanical | `model: "haiku"` |
| Implementer | Multi-file, integration | `model: "sonnet"` |
| Phase reviewer | — | `model: "sonnet"` |
| Final holistic reviewer | — | `model: "opus"` |

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
- Dispatch parallel tasks that share files
- Skip phase review after a barrier
- Skip Step 0 — the flow prompt is BLOCKING, even when prior state seems obvious
- Start work on `main`/`master` without an explicit Step 0 choice and a recorded reason
- Make subagent read the plan file (provide full task text inline)
- Skip barrier verification commands
- Proceed past 3 failed attempts without escalating
- Mark `[x]` before phase review confirms the task passes

## Verification Checklist

After all phases complete:

- [ ] All plan task checkboxes marked `[x]` in implementation-plan.md (no `[~]` or `[ ]` remaining)
- [ ] All barrier verification commands passed (typecheck, tests)
- [ ] Holistic reviewer returned `APPROVED`
- [ ] No uncommitted changes from implementation
- [ ] Read `.claude/verification.json` and run each required check — all pass

## Integration

**Called by:** `/myspec:feature-plan` (after plan approval)
**Next:** `/myspec:feature-complete` — update docs after implementation is complete
