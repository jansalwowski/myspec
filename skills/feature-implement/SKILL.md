---
name: feature-implement
tags: [feature, implementation, execution, parallel, worktree]
description: "Use when an approved implementation-plan.md is ready to execute — dispatches one implementer subagent per task, parallelizing where the plan allows. Keywords: execute plan, run plan, start implementation. Do NOT use to create plans (feature-plan), or for a plan with no Execution Order table."
---

# Feature Implement

Execute a feature implementation plan by dispatching subagents per task and reviewing at phase boundaries.

**Announce at start:** "Executing feature-implement on `${aiDir}/features/{feature}/implementation-plan.md`."

**Autopilot:** when the user opted in, answer this skill's gates — Step 0's "always ask" included — per [`_shared/autopilot.md`](../_shared/autopilot.md).

**You never write task code.** Every file a plan task creates or modifies is written by that task's implementer subagent, whatever goes wrong. When the environment gets in the way — a denied command, a missing dependency, a tool that will not run — record the task as BLOCKED or NEEDS_CONTEXT, leave it `[~]`, and ask the user what would unblock it. Code you write yourself skips the phase review, and nothing reports that it did.

## Execution Model

**Milestone** = a vertical slice of the feature (BE → FE → tests). Top-level execution unit. Agent checkpoints occur at milestone boundaries.
**Phase** = a group of tasks within a milestone, ending at a barrier. Nothing should break when a phase completes.
**Task** = a unit of work dispatched to a subagent. Sequential or parallel within a phase.
**Phase review** = after each phase: spec compliance, code quality, test coverage, docs consistency.
**Milestone checkpoint** = after all phases in a milestone: verify all tasks done, have a separate executor run the plan's checkpoint probes, ask user to continue / stop / fresh.

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

**Scope:** Task-level checkboxes (`### Task N:` steps). Barrier sub-steps use `[ ]`/`[x]` only (no `[~]`). Flip a task with `"${CLAUDE_PLUGIN_ROOT}/lib/plan-checkbox.sh" <plan> <N> doing|done`, never an ad-hoc edit script — it touches only that task's section.

## Execution Log (plan section)

Durable decisions live in the plan file, next to the checkboxes — the plan is the state that survives a crashed session, and `feature-complete` archives it. Maintain a `## Execution Log` section at the end of implementation-plan.md (create it on the first entry). Entry shapes:

- `Ruling: <what you decided> — <why> — <what it costs if wrong>`
- `Deferred minor (Phase N): <one-line finding> (file:line)`
- `Parked (Phase N): <finding> — Ruling: <why the code stands>`
- `Probe (Milestone N): <P|D><n> <verdict> — observed: <value> — artifact: <path>` (copied from the probe executor's report)
- `Waiver (Milestone N): <P|D><n> — <the user's reason, in their words>`
- `Base (feature): <sha>`, `Base (Phase N): <sha>`, `Fix base (Phase N, round R): <sha>` — the `BASE_SHA`, `PHASE_BASE` and `FIX_BASE` a review diffs from, logged when recorded (Steps 2, 3, 4d) so a restarted session can recover them. A plan from before these entries has none; resume then records the base afresh, as it always did

Everything else a restarted session needs — review packages, verification logs — goes in the run's state directory, `$STATE` (Step 2), under a fixed name. Never `mktemp` and never a session scratchpad: a restart starts a new session with a new temp directory, and an implementer or reviewer dispatched with a path that no longer exists comes back NEEDS_CONTEXT.

The holistic reviewer (Step 5) reads this section to triage deferred minors, and the completion report surfaces every ruling. An entry that exists only in session context is a decision made in secret.

## Rulings, Not Stalls

A running plan does not wait on the user for every wrinkle. Non-catastrophic conflicts — a plan ambiguity, two tasks that disagree on a detail, a review finding that contradicts the plan's text — are yours to decide: the spec is the binding authority, the plan is its argument, and your judgment settles what neither answers. Record every decision in the Execution Log as `Ruling: <what> — <why> — <what it costs if wrong>` and keep going. A wrong ruling costs rework the user can see and undo; a session parked on a question costs their whole day.

**Hard stops — these go to the user, never a ruling:**

- An irreversible or destructive operation (data loss, dropped tables, force-push)
- A security-sensitive change (auth, secrets, permissions)
- A plan ↔ spec contradiction the code cannot bridge
- Scope explosion — the fix requires work no plan task covers
- Environment friction a dispatch cannot get past (a denied command, a missing dependency) — the task is BLOCKED until the user unblocks it; doing it yourself is never the fallback
- A checkpoint probe that came back FAIL or BLOCKED — a failing probe often means the spec was misread, which a fix loop cannot see

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

**5. Auto-execute the choice:**

- **Worktree:** if path exists → enter it; else create via the EnterWorktree
  tool (or `git worktree add .claude/worktrees/feat-{name} -b feat/{name}`
  if EnterWorktree isn't available in this session). Then provision it —
  `"${CLAUDE_PLUGIN_ROOT}/lib/worktree-provision.sh" <path> --base origin/<default-branch>` —
  a bare worktree has no dependency directories (`node_modules`, `vendor`, `.venv`, …) or lint cache, and the recipe in
  `_shared/worktree-provisioning.md` says when a real install is required.
- **New branch:** `git checkout -b feat/{name}`. If branch exists, offer
  checkout vs. numeric suffix (`feat/{name}-2`).
- **Current branch:** no-op.
- **Main branch:** require explicit confirmation; record the user's reason so
  reviewers see it in the commit history.

### Step 1: Parse Plan → Execution DAG

Read the implementation plan. **Check front-matter first.**

**Retired front-matter.** A plan carrying `orchestration: agent-chain` was authored for the orchestrator agent-chain mode, retired in 2.0 and no longer run. Stop with one line: "Plan carries retired `orchestration: agent-chain` front-matter — re-plan with /myspec:feature-plan." No run-mode prompt exists.

Parse milestones first, then build a DAG within each:

1. **Identify milestones:** Each `### Milestone N:` heading scopes a milestone. A plan with no milestone heading is a single-milestone plan (the `feature-plan` template omits the heading then): the whole plan is its one milestone.
2. **For each milestone**, extract the Execution Order table and build a DAG:
   - Nodes = tasks + barriers. Edges = `Depends On` column.
   - Identify phases (task groups separated by barriers).
   - Identify parallel groups (rows with `**parallel:groupName**` in Mode).
   - Identify dual-stream forks (phases with `3a`/`3b` style rows — two simultaneous chains).
3. **Cross-milestone dependencies:** If a milestone's first phase says `Depends On: Milestone N`, the entire previous milestone must be complete before this one starts.

**Resume detection (on startup):**
- Scan all task checkboxes in the plan file
- `[x]` = already done — skip entirely
- `[~]` = was in progress when previous agent stopped — re-execute this task from scratch. For a parallel task, first clear its stale worktree with `"${CLAUDE_PLUGIN_ROOT}/lib/task-worktree.sh" discard <feature>-t<N>` (a no-op when none exists) — `create` refuses an existing slug, and the partial work never passed review
- `[ ]` = todo — execute normally
- Recover the run's state: `BASE_SHA` from the `Base (feature)` entry (none in an older plan: `git merge-base HEAD <integration branch>`), and for the phase being resumed, `PHASE_BASE` from its `Base (Phase N)` entry, so the phase review still spans the commits made before the restart. Packages and logs from before the restart are in the state directory Step 2 sets
- Find the first milestone containing any non-`[x]` task. Resume from there — unless an earlier milestone, or any milestone when every task is `[x]`, carries `**Checkpoint probes:**` without a passing entry per probe; resume at the first such milestone's probe gate (Step 4b) instead. A passing entry is a `Probe` line with PASS (SERVED for a `D<n>` demo) or a `Waiver` line.

**Validate before starting:**
- Every task in every Execution Order table has a `### Task N:` section.
- Every parallel group has a `## Barrier:` section.
- Parallel tasks have zero file overlap (check file lists — if they share a file, treat as sequential).
- Phase numbers are globally unique (no duplicates across milestones).

**Plan freshness** — only when the front-matter has `planned_against: <sha>`; skip silently without it (older plans). Collect the `Modify:` paths of every task not yet `[x]`. `$INTEGRATION` is the branch feature work merges into: the one CLAUDE.md or the topology file names, else the default branch ([`_shared/git-helpers.md`](../_shared/git-helpers.md)) — the same resolution `feature-plan` used to record the SHA. Set `BASE=origin/$INTEGRATION` and run `git fetch origin "$INTEGRATION"` (no remote configured: `BASE=$INTEGRATION`, skip the fetch). A local branch name is never the ref when a remote exists: the fetch moves only `origin/$INTEGRATION`, so the local branch can lag and diff empty. Then run `git diff --name-only <sha>..."$BASE" -- <paths>` — three dots, so the diff runs from the merge base of the two: `feature-plan` records HEAD after merging the integration branch in, and a two-dot diff would list every file the feature branch itself changed:

| Result | Action |
|--------|--------|
| exits 0, empty output | Fresh — proceed |
| exits 0, lists files | Warn with the list, log `Ruling: run despite <files> changed on $INTEGRATION since planned_against — implementers read current code — cost if wrong: a stale task snippet costs a fix round`, and tell each task that modifies a listed file that it changed after the plan was written |
| non-zero exit (128: the SHA was rebased or squashed away) | Warn "cannot verify plan freshness — planned_against <sha> not found" — never read as unchanged — and proceed |
| the fetch exits non-zero | Warn "cannot verify plan freshness — fetch of $INTEGRATION failed" and proceed without running the diff — a diff against the unfetched ref is never read as unchanged |

It warns rather than blocks: implementers already work from the current code and `Touch only` scopes their edits, while the fix for real drift — re-planning — is the user's call, which the warning and the logged ruling put in front of them.

### Step 2: Setup

1. Verify Step 0's chosen branch/worktree is active (`git rev-parse --abbrev-ref HEAD` matches the chosen target). If not, bail out and re-run Step 0.
2. Record `BASE_SHA`: `git rev-parse HEAD`, and log `Base (feature): <sha>` — unless resume recovered it.
   Set the run's state directory, which survives a restarted session and is never committed:

   ```bash
   STATE="$(git rev-parse --show-toplevel)/.claude/state/implement/{feature}"
   mkdir -p "$STATE"
   git check-ignore -q "$STATE" || echo '.claude/state/' >> "$(git rev-parse --git-path info/exclude)"
   ```
3. Set the feature's `status: in-progress` in `${aiDir}/features/index.yaml` (owner of the `draft → in-progress` transition; `feature-complete` later flips it to `complete`).
4. Create task tracking with all tasks.
5. Set the orchestration marker. Mid-run the tree is red by design (an accepted barrier failure, a fix round in flight, a test the next phase owns), and the Stop hook would otherwise block every controller turn end on it. While the marker is set it reports failing checks as a warning instead; it ignores a marker older than 8h, so a crashed run cannot disable the gate for good.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/lib/session-event.sh" implement start
   ```

   The PostToolUse hook records it for this session from the command itself (you never see the session id), so run it as written, as a Bash command. Re-run it before each phase's first dispatch so a long run stays inside the 8h window. Remove it (`"${CLAUDE_PLUGIN_ROOT}/lib/session-event.sh" implement stop`) on **stop** or **fresh** at a milestone checkpoint and at the start of Step 5.

### Step 3: Execute Milestones

Walk milestones in order. For each milestone, walk its DAG topologically. For each phase:

**Before the phase's first dispatch:** refresh the orchestration marker (Step 2.5) and record `PHASE_BASE=$(git rev-parse HEAD)`, logging `Base (Phase N): <sha>` (a resumed phase keeps the base its entry holds). The phase review package (Step 4b) diffs `PHASE_BASE..HEAD`. Never substitute `HEAD~1` — it silently drops all but the last commit of a multi-commit phase.

**Verification tiers.** Each check runs at the narrowest scope that catches what it targets:

| Who | Runs | When |
|-----|------|------|
| Implementer | its task's `Verify at phase review` command, plus lint and typecheck scoped to the files it touched where the project's tools accept a file scope | before reporting, and after each fix |
| Controller | the full suite: the plan's barrier commands plus the required `.claude/verification.json` checks | once per phase (4a), at each milestone checkpoint, at Final Verification |
| Phase reviewer | each task's `Verify at phase review` command, plus any check needed to prove a risk it names | once per phase |
| Re-reviewer | only the checks the finding touches | each fix round |

Fill each implementer dispatch with its Verify command and the file-scoped lint/typecheck commands ("none" when a tool cannot take a file list). Scoped runs catch in seconds the slips that otherwise each cost a review round; the risk they add — weakening a test until it passes — is what the phase reviewer's test-weakening audit catches.

**Commit trailers.** Fill each implementer dispatch's `[Commit trailers]` with the lines your own instructions say end a commit message — a harness attribution reminder, a CLAUDE.md or project commit rule — copied verbatim, never one tool's trailer from memory. A subagent never sees those instructions, so a trailer you leave out is missing from every commit it and each fix round make. Every commit you make yourself (Step 5's `holistic-review.md`, a stop or fresh at a checkpoint) carries the same lines.

**Sequential tasks** — dispatch one subagent at a time:

```
Dispatch implementer (./implementer-prompt.md)
  → DONE: proceed
  → DONE_WITH_CONCERNS: read concerns, decide before proceeding
  → NEEDS_CONTEXT: provide missing info, re-dispatch
  → BLOCKED: assess (more context / better model / break down / escalate to user)
```

**Parallel tasks** — dispatch ALL group tasks simultaneously in ONE message. Harness `isolation: "worktree"` forks from the default branch, not the feature HEAD, so create each task's worktree yourself (`"${CLAUDE_PLUGIN_ROOT}/lib/task-worktree.sh" create <feature>-t<N>`; recipe in `_shared/worktree-provisioning.md`) and pass its path as the implementer's working directory. Create the worktrees before marking the tasks `[~]`, so the uncommitted plan edit does not trip `create`'s dirty-tree warning — a warning that fires every time trains you to ignore the one that matters. When a task regenerates output into a dependency directory (codegen into `node_modules`, `vendor`, `.venv`, …), pass `--no-symlink` and run the project's install in that worktree yourself before dispatch — implementers never install:

```
Validate file disjointness → task-worktree.sh create per task → mark [~] → dispatch Task N,
Task M, Task K as separate Agent calls in the same message → track per-task status
→ If one fails: keep successful worktrees, fix the failed task, then barrier
```

Parallelism pays only when each task outweighs its merge and review overhead; run small parallel groups sequentially in the controller's checkout.

**Dual-stream fork** — dispatch both stream heads simultaneously, each in its own task worktree. Each stream proceeds independently (with its own sequential/parallel phases). Join waits for both streams.

### Step 4: Phase Review

After all tasks in a phase complete:

**a) Barrier merge and verification:**
- Parallel tasks only: merge worktrees back to the feature branch **one at a time** (`task-worktree.sh merge <feature>-t<N>`). On conflict: attempt resolution (auto-generated files like lockfiles, codegen output → take union). Escalate to user if truly stuck.
- Every phase: run the full suite once — the plan's barrier commands plus each required `.claude/verification.json` check (its `diffCommand` when non-empty, with `MYSPEC_BASE_REF=$(git merge-base HEAD <default branch>)`) — and capture everything to one file, each check headed by its command and exit code: `VERIFY_LOG="$STATE/phase-N-verify.log"`. A red run still goes to review, where each failure is attributed. Never two suites at once in one worktree (Constraints). Export a fresh `MYSPEC_CHECK_RUN_ID` per check. A check that is killed or times out keeps running wherever its client sent it (a container, another host), so run its `cleanup` with the same `MYSPEC_CHECK_RUN_ID` before the next run.

**b) Build the review package, then dispatch the phase reviewer** (`./phase-reviewer-prompt.md`):

Write the phase diff to one file and hand the reviewer the path. A pasted diff parks itself permanently in the most expensive context, and a reviewer without one rebuilds it by hand — the single biggest reviewer cost:

```bash
PKG="$STATE/phase-N-review.diff"
{ git log --oneline "$PHASE_BASE"..HEAD; echo; git diff --stat "$PHASE_BASE"..HEAD; echo; git diff -U10 "$PHASE_BASE"..HEAD; } > "$PKG"
```

- Use the `PHASE_BASE` recorded before the phase's first dispatch — never `HEAD~1`. Never dispatch a phase reviewer without a diff file.
- Pass `VERIFY_LOG`, and the spec requirement IDs the phase touches (from task spec citations and the plan's `## Spec Coverage` table) with their text. The reviewer checks each as behavior across the whole feature: an invariant spanning tasks otherwise surfaces only at holistic review, after later phases built on it.
- Never pre-judge findings for the reviewer — never instruct it to ignore or not flag a specific issue. If the prompt you are writing contains "do not flag", "don't treat X as a defect", or "at most Minor" — stop: you are pre-judging, usually to spare yourself a fix loop. Let the reviewer raise it and rule on it in triage.
- Covers ALL tasks in the phase: spec compliance, code quality, test coverage, test-weakening audit, integration, docs.
- Returns: `APPROVED` or `ISSUES_FOUND` with per-finding severity (Critical / Important / Minor).

**c) Triage findings** (before any fix dispatch):

- **Minor** findings never enter the fix loop: append each to the plan's Execution Log as `Deferred minor (Phase N): …` — the holistic review triages them. A roll-up nobody reads is a silent discard; the Execution Log is read at Step 5 by contract.
- A finding labeled **plan-mandated** — or any finding that conflicts with what the plan's text requires — is yours to rule on: weigh it with the spec as the binding authority, record the ruling in the Execution Log, then either send it into the loop or park it. Do not dismiss a finding because the plan mandates it, and do not dispatch a fix that contradicts the plan without a recorded ruling.
- **Critical / Important** findings enter the fix loop.

**d) Fix loop** — a round is one fix dispatch plus one scoped re-review. Five rounds maximum per phase:

- **Round 1 — resume the implementer that owns the finding.** Its context is intact: it knows the task, the code, and its own choices. Send the open findings verbatim, scoped to its task. If the harness cannot resume a completed subagent, dispatch fresh as in round 2.
- **Rounds 2–5 — fresh implementer.** A resumed context grows by a whole transcript per round and carries the last round's stale hypotheses, while each round usually chases a different root cause (one run's implementer grew from 194k to 430k tokens over three resumed rounds). Dispatch with the task text, the open findings verbatim, and the rounds summary below; it reads the current code itself. Frame it: "A prior implementer attempted this fix N times; you own it now." Rounds 4–5 go one tier up: a loop that survives three rounds usually needs more capability, not more context.
- **A finding about a rule** — an invariant, a boundary, a format, a requirement's wording — is fixed everywhere the rule is stated or applied, not only at the cited line: say so in the fix dispatch, next to the finding. A rule fixed in the code but still stated the old way in a test, a doc or the tech-spec comes back NOT ADDRESSED and costs a whole extra round.
- A parallel task's worktree was merged and removed at 4a: every fix implementer works from your checkout, since fixes are sequential.
- **Every round ends with a scoped re-review** (`./re-review-prompt.md`) — a fresh dispatch every round, never a resumed re-reviewer and never a full phase re-review. Record `FIX_BASE` (the HEAD the previous review saw) and log `Fix base (Phase N, round R): <sha>`, build a fix-diff package over `FIX_BASE..HEAD` the same way as 4b, as `$STATE/phase-N-fix-R.diff`, and dispatch with the open findings list and the rounds summary: one paragraph naming each earlier round's findings closed, your rulings on them, and approaches already rejected ("none" in round 1). The re-reviewer verdicts each finding ADDRESSED / NOT ADDRESSED against the fix diff only, running just the checks each finding touches; the next barrier or milestone checkpoint runs the full suite over the fix. New Critical/Important breakage in the fix diff joins the open findings; out-of-scope observations go to the Execution Log as deferred minors — they never extend the loop.
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

After all phases in a milestone complete (for the final milestone run only (b), then go to Step 5):

**a) Verify milestone completion:**
- All task checkboxes within this milestone are `[x]` (no `[~]` or `[ ]` remaining)
- All barrier verification commands passed
- Run the full suite — every required check in `.claude/verification.json` — over the milestone's tree

**b) Probe gate** — only when the milestone carries a `**Checkpoint probes:**` block. Dispatch the plugin agent `myspec:probe-executor` (Agent tool, `subagent_type: "myspec:probe-executor"`, `mid` tier) — never general-purpose, which keeps the edit tools the executor's definition removes. Its prompt is the payload and nothing else: the block verbatim and whole, the checkout's absolute path with `BASE_SHA`, the artifact directory, and the Target override (an address the user gave for a `NEED:` line, else "none") — never the spec rationale, the plan's reasoning, implementer reports, phase verdicts, or your view of the milestone. One executor per milestone, `mixed` included, so probes run in plan order. Create the artifact directory before each dispatch, under the restart-safe, gitignored run state rather than `mktemp`, so the artifact paths in the Execution Log still open after a restart; each dispatch gets the next free `run-R`:

```bash
PROBES="$STATE/probes/milestone-N"   # $STATE: Step 2
R=1; while [ -e "$PROBES/run-$R" ]; do R=$((R+1)); done
ART="$PROBES/run-$R"; mkdir -p "$ART"
```

The executor loads no project CLAUDE.md, so what the target needs to start must be on the Target and Scratch env lines; a gap comes back as a `NEED:` line. You never run, reword, or drop a probe yourself: the agent that did the work must not be the one that decides whether its verification ran, and tests green is not a substitute. Copy each probe line into the Execution Log. The gate passes only on `PROBES_PASSED`, with an observed value and artifact on every line. A missing report counts as BLOCKED, and FAIL or BLOCKED is a hard stop — ask the user, putting each of the report's `NEED:` lines to them first:

- **fix** → run the finding through the 4d fix loop (or, for a `NEED:` line, get what it names from the user), then re-dispatch the executor with the same probes, the next `run-R` directory, and any Target override the user gave
- **waive <P|D><n>** → log `Waiver (Milestone N): …`; the probe stays unrun, and the completion report says so
- **stop** → as in (c)

**c) Pause and ask user:**

```
═══ Milestone N complete: [milestone name] ═══

  Completed: [list of task names]
  Probes:    [n passed, n waived — or "none in plan"]  Demo: [URL + screenshot paths, if any]
  Next: Milestone N+1 — [milestone name] ([N tasks])

  continue  → proceed to Milestone N+1 in this session
  stop      → commit all changes, exit (resume later with /feature-implement)
  fresh     → commit all changes, exit — start fresh /feature-implement session next

  Choice?
```

Mark `fresh` as `(Recommended)` when the plan has more than five tasks: a multi-milestone
run in one session is dispatch-latency-bound and the controller's context degrades across
milestones.

- **continue** → proceed to next milestone
- **stop** → remove the orchestration marker, ensure all changes committed, output: "Stopped after Milestone N. Resume with `/myspec:feature-implement` — it will detect completed milestones via `[x]` checkboxes.", then exit
- **fresh** → same as stop (marker removed), additionally output: "Recommended: start a fresh `/myspec:feature-implement` session. The new agent will auto-detect progress from checkbox state and resume from Milestone N+1."

### Step 5: Completion

1. Remove the orchestration marker (Step 2.5) so the Stop hook blocks again, then run the Final Verification section from the plan.
2. Build the full-feature review package (same commands as Step 4b, over `BASE_SHA..HEAD`, as `$STATE/feature-review.diff`) and dispatch the holistic reviewer (`./holistic-reviewer-prompt.md`) on the `premium` tier with the package path plus the plan's Execution Log entries (deferred minors and parked findings) so it can triage which must be fixed before merge. This pass is mandatory — never skipped, never downgraded to a cheaper tier. Write its report to `${aiDir}/features/{feature}/holistic-review.md` (frontmatter in the prompt file) and commit it with the commit trailers (Step 3): `/myspec:feature-implement-review` reads it and skips what it already covers.
3. Print the completion report. It contains, in order: the milestone summary, with probe results and any live demo URL; the holistic verdict; **"Rulings I made"** — every `Ruling:` line from the Execution Log, in the order made, each with its cost-if-wrong ("none" if the log holds no rulings); every `Waiver:` line; and the deferred-minors triage outcome. This report is the only place the decisions taken on the user's behalf reach them.
4. **Ask the user what to do next** via `AskUserQuestion` — do not auto-hand-off:

```
question: "Implementation complete. What next?"
header:   "Next step"
options:
  - "feature-implement-review" → REQ/AC traceability, test trace, scope drift on top of
                                  holistic-review.md; persists conformance-report.md
  - "/code-review"              → Claude Code's built-in bug review of the branch diff
  - "feature-complete"          → skip the reviews; sync docs, archive plan, merge
  - "Stop here"                 → leave the branch as-is; continue later
```

Recommend `feature-implement-review` when the holistic verdict is not READY TO MERGE, any criterion came back ⚠/❌, a probe was waived, or the plan has 10+ tasks; otherwise `feature-complete`, since the holistic pass already checked every criterion. Execute the choice: invoke `/myspec:feature-implement-review`, the built-in `/code-review` (not a myspec skill; Claude Code only), `/myspec:feature-complete`, or stop and report the branch name. The two review passes are complementary, not exclusive (conformance vs. bugs) — after one finishes, offer this choice again so the user can run the other or proceed.

## Model Selection

Skill text uses **tier names** (`cheap` / `mid` / `premium`). Controller (main thread) maps tier → concrete model based on runtime availability. Model IDs change between releases, so no hardcoded model IDs.

| Role | Complexity | Tier | Hint (controller picks concrete model) |
|------|-----------|------|----------------------------------------|
| Implementer | 1-2 files, mechanical | `cheap` | e.g. Haiku-tier, GPT-5-mini-tier, or runtime's small model |
| Implementer | Multi-file, integration | `mid` | e.g. Sonnet-tier, GPT-5-tier |
| Phase reviewer | — | `mid` | e.g. Sonnet-tier, GPT-5-tier |
| Probe executor | — | `mid` | e.g. Sonnet-tier, GPT-5-tier |
| Final holistic reviewer | — | `premium` | e.g. Opus-tier |

**Name the tier on every dispatch.** An omitted model inherits the session's model — often the most expensive tier — which silently defeats this table. An upstream production run put all 26 of its reviewers on the top tier exactly this way.

**Turn count beats token price.** Cost scales with how many turns a subagent takes, and the cheapest models routinely take 2-3x the turns on multi-step work — costing more overall. `mid` is the floor for reviewers and for implementers working from prose descriptions. Reserve `cheap` for pure transcription — the task text contains the complete code to write — and single-file mechanical fixes. Fix-loop rounds 4-5 use a tier above the implementer that got stuck.

## Error Handling

| Situation | Action |
|-----------|--------|
| BLOCKED | More context → re-dispatch; better model; break down; or ask user — never implement it yourself |
| NEEDS_CONTEXT | Provide info, re-dispatch |
| One parallel task fails | Keep other worktrees, fix failed, then barrier |
| Merge conflict at barrier | Attempt resolution; escalate if stuck |
| Verification fails at barrier | Dispatch the phase reviewer with the log; it attributes each failure, and fixes go through the fix loop |
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
- Write or edit a file a plan task owns — not after a denied command or a missing dependency, not to save a dispatch; mark the task BLOCKED or NEEDS_CONTEXT and ask the user. Controller-written code skips every review
- Fix review findings in the controller session — resume or dispatch an implementer; controller fixes skip review
- `cd` into a task worktree — reach it with `git -C <path>` and absolute paths; implementers do the `cd`. Why: [`_shared/worktree-provisioning.md`](../_shared/worktree-provisioning.md) (Controller stays out)
- Let an implementer run the full suite, a build, or an install — its checks are its task's Verify command and file-scoped static checks; the suite is the barrier's
- Run two verification suites at once in one worktree — concurrent runs share caches, build output, ports, and test databases, and the timing flakes they cause cost an investigation. The Stop hook can run the suite when your turn ends, so do not end a turn while a subagent is running checks in the same worktree
- Skip the Step 5 holistic review, or run it below `premium` — it is the only pass that sees the whole feature
- Pass a milestone checkpoint whose probes lack a `PROBES_PASSED` report or a logged user waiver — the probe gate is the one check the controller does not grade

## Verification Checklist

After all phases complete:

- [ ] All plan task checkboxes marked `[x]` in implementation-plan.md (no `[~]` or `[ ]` remaining)
- [ ] All barrier verification commands passed (typecheck, tests)
- [ ] Holistic reviewer returned `APPROVED`
- [ ] Execution Log deferred minors triaged by the holistic review (fixed or explicitly accepted)
- [ ] Every `Ruling:` line from the Execution Log surfaced under "Rulings I made" in the completion report
- [ ] No uncommitted changes from implementation
- [ ] Orchestration marker removed (`session-event.sh implement stop`) before Final Verification
- [ ] Read `.claude/verification.json` and run each required check — all pass

## Integration

**Called by** [REQUIRED — an approved plan must exist]: `/myspec:feature-plan` (after plan approval)
**Next** [OPTIONAL reviews, then REQUIRED completion]: `/myspec:feature-implement-review` (conformance audit) and/or the built-in `/code-review` (bug review), then `/myspec:feature-complete` — chosen by the user in Step 5
