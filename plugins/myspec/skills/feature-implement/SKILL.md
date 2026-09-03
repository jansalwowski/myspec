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

## Execution Log (plan section)

Durable decisions live in the plan file, next to the checkboxes — the plan is the state that survives a crashed session, and `feature-complete` archives it. Maintain a `## Execution Log` section at the end of implementation-plan.md (create it on the first entry). Three entry shapes:

- `Ruling: <what you decided> — <why> — <what it costs if wrong>`
- `Deferred minor (Phase N): <one-line finding> (file:line)`
- `Parked (Phase N): <finding> — Ruling: <why the code stands>`

The holistic reviewer (Step 5) reads this section to triage deferred minors, and the completion report surfaces every ruling. An entry that exists only in session context is a decision made in secret.

## Rulings, Not Stalls

A running plan does not wait on the user for every wrinkle. Non-catastrophic conflicts — a plan ambiguity, two tasks that disagree on a detail, a review finding that contradicts the plan's text — are yours to decide: the spec is the binding authority, the plan is its argument, and your judgment settles what neither answers. Record every decision in the Execution Log as `Ruling: <what> — <why> — <what it costs if wrong>` and keep going. A wrong ruling costs rework the user can see and undo; a session parked on a question costs their whole day.

**Hard stops — these go to the user, never a ruling:**

- An irreversible or destructive operation (data loss, dropped tables, force-push)
- A security-sensitive change (auth, secrets, permissions)
- A plan ↔ spec contradiction the code cannot bridge (orchestrator mode: `ESCALATE`)
- Scope explosion — the fix requires work no plan task covers

At Step 5, list every ruling in the completion report under **"Rulings I made"**, in the order made, each with its cost-if-wrong. The list is exhaustive: if the Execution Log holds a ruling, the report holds it.

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
  if EnterWorktree isn't available in this session). Then provision it —
  `.claude/lib/worktree-provision.sh <path> --base origin/<default-branch>` —
  a bare worktree has no `node_modules` or lint cache, and the recipe in
  `_shared/worktree-provisioning.md` says when a real install is required.
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

**Before the phase's first dispatch:** record `PHASE_BASE=$(git rev-parse HEAD)`. The phase review package (Step 4b) diffs `PHASE_BASE..HEAD`. Never substitute `HEAD~1` — it silently drops all but the last commit of a multi-commit phase.

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

**b) Build the review package, then dispatch the phase reviewer** (`./phase-reviewer-prompt.md`):

Write the phase diff to one file and hand the reviewer the path. A pasted diff parks itself permanently in the most expensive context, and a reviewer without one rebuilds it by hand — the single biggest reviewer cost:

```bash
PKG=$(mktemp "${TMPDIR:-/tmp}/phase-review.XXXXXX")
{ git log --oneline "$PHASE_BASE"..HEAD; echo; git diff --stat "$PHASE_BASE"..HEAD; echo; git diff -U10 "$PHASE_BASE"..HEAD; } > "$PKG"
```

- Use the `PHASE_BASE` recorded before the phase's first dispatch — never `HEAD~1`. Never dispatch a phase reviewer without a diff file.
- Never pre-judge findings for the reviewer — never instruct it to ignore or not flag a specific issue. If the prompt you are writing contains "do not flag", "don't treat X as a defect", or "at most Minor" — stop: you are pre-judging, usually to spare yourself a fix loop. Let the reviewer raise it and rule on it in triage.
- Covers ALL tasks in the phase: spec compliance, code quality, test coverage, integration, docs.
- Returns: `APPROVED` or `ISSUES_FOUND` with per-finding severity (Critical / Important / Minor).

**c) Triage findings** (before any fix dispatch):

- **Minor** findings never enter the fix loop: append each to the plan's Execution Log as `Deferred minor (Phase N): …` — the holistic review triages them. A roll-up nobody reads is a silent discard; the Execution Log is read at Step 5 by contract.
- A finding labeled **plan-mandated** — or any finding that conflicts with what the plan's text requires — is yours to rule on: weigh it with the spec as the binding authority, record the ruling in the Execution Log, then either send it into the loop or park it. Do not dismiss a finding because the plan mandates it, and do not dispatch a fix that contradicts the plan without a recorded ruling.
- **Critical / Important** findings enter the fix loop.

**d) Fix loop** — a round is one fix dispatch plus one scoped re-review. Five rounds maximum per phase:

- **Rounds 1–3 — resume the implementer that owns the finding.** Its context is intact: it knows the task, the code, and its own choices. Send the open findings verbatim, scoped to its task. If the harness cannot resume a completed subagent, dispatch a fresh implementer carrying the task text plus the findings.
- **Rounds 4–5 — fresh implementer, one tier up.** A loop that survives three resumes usually means the implementer cannot see its own problem — fresh eyes and a capability bump in one move. Frame the dispatch: "A prior implementer attempted this fix N times; you own it now."
- **Every round ends with a scoped re-review** (`./re-review-prompt.md`), never a full phase re-review. Record `FIX_BASE` (the HEAD the previous review saw), build a fix-diff package over `FIX_BASE..HEAD` the same way as 4b, and dispatch with the open findings list. The re-reviewer verdicts each finding ADDRESSED / NOT ADDRESSED against the fix diff only. New Critical/Important breakage in the fix diff joins the open findings; out-of-scope observations go to the Execution Log as deferred minors — they never extend the loop.
- Never fix findings yourself in the controller session — your context stays clean for coordination, and controller fixes skip review.

**The breaker.** When round 5's re-review still leaves findings open, stop dispatching and adjudicate each open finding yourself — you hold the plan and cross-phase context the reviewer lacks:

- Reviewer wrong, or the point is contestable → `Parked (Phase N): <finding> — Ruling: <why the code stands>`
- Real, but nothing downstream builds on it → park the same way, with a ruling that says it is real and deferred
- Real and load-bearing (a later phase builds on it, or it reveals a plan defect) → rule on the smallest change that unblocks the dependent work, record the ruling, and carry it into the next phase's dispatch

Adjudicate only at the cap — adjudicating earlier to end a loop is pre-judging with a different name. Hard stops (see Rulings, Not Stalls) still go to the user.

**e) Mark phase complete:** all task checkboxes in the phase are now `[x]` (parked findings do not block — their rulings are recorded), unlock downstream phases within the milestone.

**f) Inter-phase progress note** (within a milestone, no pause — proceed immediately):

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
2. Build the full-feature review package (same commands as Step 4b, over `BASE_SHA..HEAD`) and dispatch the holistic reviewer (`./holistic-reviewer-prompt.md`) with the package path plus the plan's Execution Log entries (deferred minors and parked findings) so it can triage which must be fixed before merge. This is the quick in-flight gate; the deeper independent conformance audit lives in `/myspec:feature-implement-review`.
3. Print the completion report. It contains, in order: the milestone summary; the holistic verdict; **"Rulings I made"** — every `Ruling:` line from the Execution Log, in the order made, each with its cost-if-wrong ("none" if the log holds no rulings); and the deferred-minors triage outcome. This report is the only place the decisions taken on the user's behalf reach them.
4. **Ask the user what to do next** via `AskUserQuestion` — do not auto-hand-off:

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

**Name the tier on every dispatch.** An omitted model inherits the session's model — often the most expensive tier — which silently defeats this table. An upstream production run put all 26 of its reviewers on the top tier exactly this way.

**Turn count beats token price.** Cost scales with how many turns a subagent takes, and the cheapest models routinely take 2-3x the turns on multi-step work — costing more overall. `mid` is the floor for reviewers and for implementers working from prose descriptions. Reserve `cheap` for pure transcription — the task text contains the complete code to write — and single-file mechanical fixes. Fix-loop rounds 4-5 use a tier above the implementer that got stuck.

## Error Handling

| Situation | Action |
|-----------|--------|
| BLOCKED | More context → re-dispatch; better model; break down; or ask user |
| NEEDS_CONTEXT | Provide info, re-dispatch |
| One parallel task fails | Keep other worktrees, fix failed, then barrier |
| Merge conflict at barrier | Attempt resolution; escalate if stuck |
| Verification fails at barrier | Identify offending task, dispatch fix agent |
| 3+ attempts same task | Escalate: "I've made N attempts. What I tried: [list]." |
| Review finding conflicts with plan text | Rule on it (spec is binding), record in Execution Log, then fix or park |
| Round 5 re-review leaves findings open | Breaker: adjudicate each finding — park with ruling or carry forward. Never a round 6 |

## Constraints

**Never:**
- Dispatch parallel tasks that share files — the worktree merge will conflict on shared paths
- Make subagent read the plan file — provide full task text inline so the subagent has no parsing to do
- Skip barrier verification commands — they're how the phase fails fast on broken merges
- Proceed past 3 failed attempts without escalating — the issue won't fix itself on attempt 4
- Tell a reviewer what not to flag — a suppressed finding never reaches the user; adjudicate it in triage instead
- Diff a review with `HEAD~1` — use the recorded `PHASE_BASE` / `FIX_BASE` / `BASE_SHA`
- Fix review findings in the controller session — resume or dispatch an implementer; controller fixes skip review

## Verification Checklist

After all phases complete:

- [ ] All plan task checkboxes marked `[x]` in implementation-plan.md (no `[~]` or `[ ]` remaining)
- [ ] All barrier verification commands passed (typecheck, tests)
- [ ] Holistic reviewer returned `APPROVED`
- [ ] Execution Log deferred minors triaged by the holistic review (fixed or explicitly accepted)
- [ ] Every `Ruling:` line from the Execution Log surfaced under "Rulings I made" in the completion report
- [ ] No uncommitted changes from implementation
- [ ] Read `.claude/verification.json` and run each required check — all pass

## Integration

**Called by** [REQUIRED — an approved plan must exist]: `/myspec:feature-plan` (after plan approval)
**Next** [OPTIONAL reviews, then REQUIRED completion]: `/myspec:feature-implement-review` (conformance audit) and/or `/myspec:code-review` (quality review), then `/myspec:feature-complete` — chosen by the user in Step 5
