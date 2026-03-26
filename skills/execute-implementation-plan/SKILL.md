---
description: "Use when executing an implementation-plan.md from the AI features directory. Understands [parallel:groupName] tags, Execution Order tables, barrier sections, dual-stream fork/join. Dispatches subagents per task (sequential or parallel with worktree isolation), reviews at phase boundaries. Do NOT use for creating plans (use feature-implement), for debugging (use dispatching-parallel-agents), or for plans without Execution Order table."
---

# Execute Implementation Plan

Execute a feature implementation plan by dispatching subagents per task and reviewing at phase boundaries.

**Announce at start:** "I'm using execute-implementation-plan to execute `${aiDir}/features/{feature}/implementation-plan.md`."

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Execution Model

**Phase** = a shippable group of tasks ending at a barrier. Nothing should break when a phase completes.
**Task** = a unit of work dispatched to a subagent. Sequential or parallel within a phase.
**Phase review** = after each phase: spec compliance, code quality, test coverage, docs consistency.

## The Process

### Step 1: Parse Plan → Execution DAG

Read the implementation plan. Extract the Execution Order table and build a DAG:
- Nodes = tasks + barriers. Edges = `Depends On` column.
- Identify phases (task groups separated by barriers).
- Identify parallel groups (rows with `**parallel:groupName**` in Mode).
- Identify dual-stream forks (phases with `3a`/`3b` style rows — two simultaneous chains).

**Validate before starting:**
- Every task in the Execution Order has a `### Task N:` section.
- Every parallel group has a `## Barrier:` section.
- Parallel tasks have zero file overlap (check file lists — if they share a file, treat as sequential).

### Step 2: Setup

1. Ensure you are on a feature branch (never `main` / `master`). Create one if needed.
2. Record `BASE_SHA`: `git rev-parse HEAD`
3. Create task tracking with all tasks.

### Step 3: Execute Phases

Walk the DAG topologically. For each phase:

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
- On conflict: attempt resolution (auto-generated files like lockfiles → take union). Escalate to user if truly stuck.
- Run barrier verification commands from the plan (type-check, tests).

**b) Dispatch phase reviewer** (`./phase-reviewer-prompt.md`):
- Covers ALL tasks in the phase: spec compliance, code quality, test coverage, integration, docs.
- Returns: `APPROVED` or `ISSUES_FOUND` with specifics.

**c) Fix loop:**
- If `ISSUES_FOUND` → dispatch fix agent with specific issues → re-dispatch phase reviewer.
- Repeat until `APPROVED`.

**d) Mark phase complete:** update plan file checkboxes (`- [ ]` → `- [x]`), unlock downstream phases.

### Step 5: Completion

1. Run Final Verification section from the plan.
2. Dispatch holistic reviewer (`./holistic-reviewer-prompt.md`) for full diff `BASE_SHA..HEAD`.
3. Hand off to `/myspec:finishing-a-development-branch`.

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

## Red Flags

**Never:**
- Dispatch parallel tasks that share files
- Skip phase review after a barrier
- Start work on `main`/`master` without user consent
- Make subagent read the plan file (provide full task text inline)
- Skip barrier verification commands
- Proceed past 3 failed attempts without escalating

## Integration

**Called by:** `/myspec:feature-implement` (after plan approval)
**Next:** `/myspec:finishing-a-development-branch` — REQUIRED after all phases complete
**Then:** `/myspec:feature-complete` — update docs after branch is merged
