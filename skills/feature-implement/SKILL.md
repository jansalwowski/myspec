---
name: feature-implement
tags: [feature, implementation, execution, parallel, worktree]
description: "Use when an approved implementation-plan.md is ready to execute — dispatches one implementer subagent per task, parallelizing where the plan allows. Keywords: execute plan, run plan, start implementation. Do NOT use to create plans (feature-plan), or for a plan with no Execution Order table."
---

# Feature Implement

**Announce at start:** "Executing feature-implement on `${aiDir}/features/{feature}/implementation-plan.md`."

**Autopilot:** when the user opted in, answer this skill's gates — Step 0's "always ask" included — per [`_shared/autopilot.md`](../_shared/autopilot.md).

**Plugin lib:** `${CLAUDE_PLUGIN_ROOT}/lib` — the plugin's helper scripts. Files this skill sends you to write it as `<plugin lib>`: use this resolved path in its place. The Bash tool does not export the variable, so never type it in a command.

**You never write task code.** Every file a plan task creates or modifies is written by that task's implementer subagent, whatever goes wrong — and every review finding is fixed by an implementer. When the environment gets in the way — a denied command, a missing dependency, a tool that will not run — record the task as BLOCKED or NEEDS_CONTEXT, leave it `[~]`, and ask the user what would unblock it. Code you write yourself skips the phase review, and nothing reports that it did.

**Read on demand.** This file holds the serial path. Read a branch's file when its condition holds, before acting:

| When | Read |
|------|------|
| A phase holds a `**parallel:groupName**` group or a dual-stream fork | [parallel-tasks.md](parallel-tasks.md) |
| Front-matter sets `auto_parallel_phases: true` | [parallel-phases.md](parallel-phases.md) |
| Step 1 chose workflow mode | [workflow-args.md](workflow-args.md) |
| Triage leaves a Critical or Important finding (4d) | [fix-loop.md](fix-loop.md) |
| At startup, the plan already holds a `[x]` or `[~]` task or an Execution Log | [resume.md](resume.md) |
| A milestone carries `**Checkpoint probes:**` | [probe-gate.md](probe-gate.md) |
| Every milestone is complete (Step 5) | [completion.md](completion.md) |

## Execution Model

A **milestone** is a vertical slice of the feature and ends at a checkpoint with the user. A **phase** is a group of tasks within a milestone, ending at a barrier and one review; nothing should break when it completes. A **task** is one implementer dispatch.

## Task Status Tracking

| Status | Set when |
|--------|----------|
| `[ ]` todo | Default in generated plans |
| `[~]` in progress | Before dispatching the task's subagent. It stays through retries and through a stopped session, which is how resume finds it |
| `[x]` done | Only after the phase review passes for that task — never before |

Flip a task with `"${CLAUDE_PLUGIN_ROOT}/lib/plan-checkbox.sh" <plan> <N> doing|done`, never an ad-hoc edit script — it touches only that task's section. Barrier sub-steps use `[ ]`/`[x]` only.

## Execution Log (plan section)

The plan is the state that survives a crashed session. Maintain a `## Execution Log` section at the end of implementation-plan.md. Entry shapes:

- `Ruling: <what you decided> — <why> — <what it costs if wrong>`
- `Deferred minor (Phase N): <one-line finding> (file:line)`
- `Parked (Phase N): <finding> — Ruling: <why the code stands>`
- `Decision (Task N): <what> — <why>` (`Phase N, round R` for a cross-task fix) and `Not proven (Phase N): <ID>: <behavior>`
- `Probe (Milestone N): <P|D><n> <verdict> — observed: <value> — artifact: <path>`
- `Waiver (Milestone N): <P|D><n> — <the user's reason, in their words>`
- `Base (feature): <sha>`, `Base (Phase N): <sha>`, `Fix base (Phase N, round R): <sha>` — `BASE_SHA`, `PHASE_BASE`, `FIX_BASE`: the bases reviews diff from, logged so a restart can recover them
- `Timing (Phase N): …` — the 4f progress line

Everything else a restarted session needs — review packages, verification logs — goes in the run's state directory, `$STATE` (Step 2), under a fixed name. Never `mktemp` and never a session scratchpad: a restart gets a new temp directory, and the old paths are gone.

An entry that exists only in session context is a decision made in secret.

## Rulings, Not Stalls

Non-catastrophic conflicts — a plan ambiguity, two tasks that disagree on a detail, a review finding that contradicts the plan's text — are yours to decide: the spec is the binding authority, the plan is its argument, and your judgment settles what neither answers. Log every decision as a `Ruling:` and keep going.

**Hard stops — these go to the user, never a ruling:**

- An irreversible or destructive operation (data loss, dropped tables, force-push)
- A security-sensitive change (auth, secrets, permissions)
- A plan ↔ spec contradiction the code cannot bridge
- Scope explosion — the fix requires work no plan task covers
- Environment friction a dispatch cannot get past (a denied command, a missing dependency) — the task is BLOCKED until the user unblocks it
- A checkpoint probe that came back FAIL or BLOCKED

## Workflow

### Step 0: Confirm Implementation Flow (BLOCKING)

Confirm where implementation will happen before parsing the plan. Always ask — even when prior state makes the answer obvious.

1. **Inspect** (REQUIRED reference: [`_shared/git-helpers.md`](../_shared/git-helpers.md)): default branch, current `HEAD` branch, `git status --porcelain`, an existing worktree for this feature (`git worktree list` contains `feat-{name}`), and whether the plan has `[parallel:*]` groups.
2. **A dirty tree is resolved first.** Ask the user to commit or stash; never switch branches or create a worktree on top of unrelated changes. If the dirty files are exactly the feature's spec/plan files, offer to commit them.
3. **Ask via `AskUserQuestion`** — question "How should implementation proceed?", header "Impl flow" — with the recommended option first and `(Recommended — {why})` appended:

| Option | Recommended when | On choice |
|--------|------------------|-----------|
| Worktree `feat-{name}` | A worktree for the feature exists (reuse), or the plan has `[parallel:*]` groups | Enter `.claude/worktrees/feat-{name}` if it exists; else create it with EnterWorktree (or `git worktree add .claude/worktrees/feat-{name} -b feat/{name}`). Then provision it: `"${CLAUDE_PLUGIN_ROOT}/lib/worktree-provision.sh" <path> --base origin/<default-branch>` |
| Current branch `{HEAD}` | HEAD is already `feat/{name}` or equivalent | No-op |
| New branch `feat/{name}` | HEAD is the default branch | `git checkout -b feat/{name}`. If it exists, offer checkout vs. a numeric suffix |
| Main branch | Never — only for trivial fixes | Require explicit confirmation, and record the user's reason in the commit history |

Barrier checks, checkpoints and probes build or serve the app in this worktree; when they do, provision it with `--no-symlink` and run the project's install there (`_shared/worktree-provisioning.md`).

### Step 1: Parse Plan → Execution DAG

Read the implementation plan, front-matter first.

- **Retired front-matter.** A plan carrying `orchestration: agent-chain` stops with one line: "Plan carries retired `orchestration: agent-chain` front-matter — re-plan with /myspec:feature-plan."
- **Run mode.** `"${CLAUDE_PLUGIN_ROOT}/lib/myspec-config.sh" get orchestration.featureImplement` prints `"controller"` (also for an unrecognised value or a failed read) or `"workflow"`. Choose workflow only when this session has the Workflow tool; without it print "Workflow mode is unavailable in this session (no Workflow tool), so feature-implement runs in controller mode."

**Build the DAG:**

1. Each `### Milestone N:` heading scopes a milestone; a plan with no milestone heading is one milestone.
2. Per milestone, read the Execution Order table: nodes = tasks + barriers, edges = the `Depends On` column, phases = task groups separated by barriers. Note parallel groups (`**parallel:groupName**` in Mode) and dual-stream forks (`3a`/`3b` rows).
3. Only when the front-matter sets `auto_parallel_phases: true`: find concurrent phase sets (parallel-phases.md).
4. A milestone whose first phase says `Depends On: Milestone N` starts only after that milestone is complete.

**Validate before starting:** every task in an Execution Order table has a `### Task N:` section; every parallel group has a `## Barrier:` section; parallel tasks share no file (if they do, treat them as sequential); phase numbers are unique across milestones.

**Resume** — at startup only, on the Read on demand trigger: [resume.md](resume.md) gives the checkbox states, the recovered bases and the resume point. Mid-run, a `[~]` task is one you dispatched: leave it.

**Plan freshness** — only when the front-matter has `planned_against: <sha>`. Collect the `Modify:` paths of every task not yet `[x]`. `$INTEGRATION` is the branch feature work merges into: the one CLAUDE.md or the topology file names, else the default branch. Run `"${CLAUDE_PLUGIN_ROOT}/lib/plan-freshness.sh" check <sha> "$INTEGRATION" <paths>` and act on its exit status:

- **0, `fresh`** — proceed.
- **1, `stale`** plus the changed paths — warn with the list, log a `Ruling:` naming the files (cost if wrong: a stale task snippet costs a fix round), and tell each task that modifies a listed file that it changed after the plan was written.
- **2, `unknown: <reason>`** — warn "cannot verify plan freshness — <reason>" and proceed. Never read it as fresh.

### Step 2: Setup

1. Verify Step 0's chosen branch/worktree is active (`git rev-parse --abbrev-ref HEAD`). If not, bail out and re-run Step 0.
2. Record `BASE_SHA` (`git rev-parse HEAD`) and log `Base (feature): <sha>` — unless resume recovered it.
3. Set the run's state directory, which survives a restart and is never committed:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/lib/implement-state.sh" init {feature}
   ```

   It prints the directory's absolute path: that is `$STATE`. Run it alone, as written — folded into a chain it costs the user a permission prompt for the whole chain.
4. Set the feature's `status: in-progress` in `${aiDir}/features/index.yaml`, and create task tracking with all tasks.
5. Set the orchestration marker. Mid-run the tree is red by design; while the marker is set, the Stop hook warns instead of blocking every turn end.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/lib/session-event.sh" implement start
   ```

   Run it as written, as a Bash command: a hook records it from the command itself. The marker expires after 8h, so re-run it before each phase's first dispatch. Remove it (`… implement stop`) on **stop** or **fresh** at a checkpoint and at the start of Step 5.

### Step 3: Execute Milestones

Walk milestones in order, and each milestone's DAG topologically.

**Before a phase's first dispatch:** refresh the orchestration marker and record `PHASE_BASE=$(git rev-parse HEAD)`, logging `Base (Phase N): <sha>` — once per phase: a resumed phase keeps its entry's base; a concurrent phase logs it at its merge (parallel-phases.md), not here. Stamp each stage as it starts, for 4f's timings: `"${CLAUDE_PLUGIN_ROOT}/lib/implement-state.sh" stamp {feature} N implement`, then `barrier` (4a), `review` (4b), `fix-R` (each 4d round), and `done` (4e).

**Verification tiers.** An implementer runs its task's `Verify at phase review` command plus lint and typecheck scoped to the files it touched — never the full suite, a build, or an install. You run the full suite once per phase (4a), at each milestone checkpoint, and at Final Verification.

**Dispatch one implementer per task** with [implementer-prompt.md](implementer-prompt.md), sequential tasks one at a time. Fill each dispatch with:

- The full task text inline — a subagent never reads the plan file.
- Its Verify command and the file-scoped lint/typecheck commands ("none" when a tool cannot take a file list).
- `[Commit trailers]`: the lines your own instructions say end a commit message (a harness attribution reminder, a CLAUDE.md or project commit rule), copied verbatim, never one tool's trailer from memory. A subagent never sees those instructions. Your own commits carry the same lines.
- A named model tier (Model Selection).

| Report | Action |
|--------|--------|
| DONE | Log decisions, proceed |
| DONE_WITH_CONCERNS | Read the concerns, decide before proceeding |
| NEEDS_CONTEXT | Provide the missing info, re-dispatch |
| BLOCKED | More context, a better model, or a smaller task, then re-dispatch; else ask the user |

After 3 attempts on one task, whatever it reported, escalate: "I've made N attempts. What I tried: [list]."

**Parallel groups, dual-stream forks, concurrent phases and workflow mode** replace only this step's dispatches, per their files (Read on demand); barriers and reviews stay per phase.

### Step 4: Phase Review

After all tasks in a phase complete:

**a) Barrier.** Merge parallel task worktrees first (parallel-tasks.md). Then run the full suite once — the plan's barrier commands plus each required `.claude/verification.json` check (its `diffCommand` when non-empty, with `MYSPEC_BASE_REF=$(git merge-base HEAD <default branch>)`) — and capture everything to `VERIFY_LOG="$STATE/phase-N-verify.log"`, each check headed by its command and exit code. A red run still goes to review, where each failure is attributed. Export a fresh `MYSPEC_CHECK_RUN_ID` per check; a check that is killed or times out keeps running wherever its client sent it, so run its `cleanup` with the same id before the next run.

**b) Build the review package, then dispatch the phase reviewer** ([phase-reviewer-prompt.md](phase-reviewer-prompt.md), `mid` tier):

```bash
PKG="$STATE/phase-N-review.diff"
"${CLAUDE_PLUGIN_ROOT}/lib/review-diff.sh" "$PHASE_BASE" "$PKG"
```

Hand the reviewer the path, never a pasted diff. Every review package in this skill comes from this helper, always from a recorded base (`PHASE_BASE`, `FIX_BASE`, `BASE_SHA`) — never `HEAD~1`, which drops all but the last commit. Exit 2 means the base is not a commit and no package was written: recover the base from the Execution Log, or stop for the user. Never dispatch a reviewer without a diff file.

- Pass `VERIFY_LOG`, and the spec requirement IDs the phase touches (from task spec citations and the plan's `## Spec Coverage` table) with their text, plus each one's Test cell when that table has a Test column. In workflow mode, also pass the per-task loop results.
- Never pre-judge findings. If the prompt you are writing contains "do not flag", "don't treat X as a defect", or "at most Minor" — stop: let the reviewer raise it and rule on it in triage.
- It returns `APPROVED` or `ISSUES_FOUND` with per-finding severity (Critical / Important / Minor), plus Decisions and Not proven to log.

**c) Triage findings** (before any fix dispatch):

- **Minor** findings never enter the fix loop: log each as `Deferred minor (Phase N): …`.
- A finding labeled **plan-mandated**, or one that conflicts with the plan's text, is yours to rule on with the spec as the binding authority: log the ruling, then send it into the loop or park it. Never dismiss it because the plan mandates it, nor fix against the plan without a logged ruling.
- **Critical / Important** findings enter the fix loop.

**d) Fix loop.** Read [fix-loop.md](fix-loop.md) before a fix dispatch whenever it is not in your context. Its shape: a round is one fix dispatch plus one fresh scoped re-review ([re-review-prompt.md](re-review-prompt.md)) over a logged `Fix base`, five rounds at most. Round 1 resumes the implementer that owns the finding; later rounds dispatch a fresh one, rounds 4–5 one tier up. Tell the fixer that a finding about a rule is fixed everywhere the rule is stated or applied, not only at the cited line. After round 5 you adjudicate each open finding (the breaker) — never a round 6, and never earlier.

**e) Mark the phase complete:** flip its tasks to `[x]` (parked findings do not block — their rulings are logged) and unlock downstream phases.

**f) Progress note** — no pause, proceed immediately:

```
✓ Phase N complete: [phase name] — 41m (implement 17m · barrier 6m · review 9m · fixes 2 rounds 9m)
  Next: Phase N+1 — [phase name] ([N tasks])
```

Durations come from `$STATE/phase-N.times` (a stage runs until the next stamp; one with no stamp shows as `?`). Log the same line as `Timing (Phase N)`.

### Step 4b: Milestone Checkpoint

After all phases in a milestone complete. For the final milestone run only (b), then continue at Step 5.

**a) Verify completion:** every task in the milestone is `[x]`, and the full suite — every required check in `.claude/verification.json` — passes over the milestone's tree.

**b) Probe gate** — only when the milestone carries a `**Checkpoint probes:**` block. Read [probe-gate.md](probe-gate.md), then dispatch the plugin agent `myspec:probe-executor` (`subagent_type: "myspec:probe-executor"`) — never general-purpose. You never run, reword, or drop a probe yourself, and tests green is not a substitute. The gate passes only on a `PROBES_PASSED` report or a logged user `Waiver` — it is the one check you do not grade; FAIL, BLOCKED or a missing report is a hard stop.

**c) Pause and ask the user.** Print `═══ Milestone N complete: [name] ═══`, the completed tasks, the probe results (`n passed, n waived`, or "none in plan") with any demo URL and screenshot paths, and the next milestone with its task count. Then ask: **continue** in this session, **stop**, or **fresh** (stop, and start a new session next).

Mark `fresh` as `(Recommended)` when the plan has more than five tasks: the controller's context degrades across milestones. On **stop** or **fresh**, remove the orchestration marker, commit everything, and say how to resume: `/myspec:feature-implement` detects progress from the `[x]` checkboxes.

### Step 5: Completion

Read [completion.md](completion.md) and follow it: Final Verification, the mandatory `premium` holistic review, the report (evidence first), then ask the user what comes next — never auto-hand-off.

## Model Selection

Map each tier name to a concrete model the runtime has; never hardcode a model ID.

| Role | Tier |
|------|------|
| Implementer — pure transcription (the task text holds the complete code) or a single-file mechanical fix | `cheap` |
| Implementer — multi-file, integration, or working from prose | `mid` |
| Phase reviewer, probe executor | `mid` |
| Fix-loop rounds 4–5 | one tier above the stuck implementer |
| Holistic reviewer | `premium` |

**Name the tier on every dispatch** — an omitted model inherits the session's, often the most expensive. `mid` is the floor for reviewers: the cheapest models take 2-3x the turns on multi-step work.

## Constraints

**Never:**
- Write or edit a file a plan task owns, or fix a review finding yourself — not after a denied command, not to save a dispatch. Controller-written code skips every review
- Tell a reviewer what not to flag — a suppressed finding never reaches the user; adjudicate it in triage
- Skip the barrier's verification commands
- Run two verification suites at once in one worktree — concurrent runs share caches, build output, ports, and test databases. The Stop hook can run the suite when your turn ends, so do not end a turn while a subagent is running checks in the same worktree
- `cd` into a task worktree — use `git -C <path>` and absolute paths. Why: `_shared/worktree-provisioning.md` (Controller stays out)

## Verification Checklist

- [ ] No `[~]` or `[ ]` task left in implementation-plan.md
- [ ] Every required `.claude/verification.json` check and the plan's Final Verification pass, run after `session-event.sh implement stop`
- [ ] The holistic verdict is READY TO MERGE, or the user accepted a lesser one; `holistic-review.md` is committed and its deferred minors triaged
- [ ] Every logged `Ruling:`, `Decision` and `Waiver:` line is in the completion report
- [ ] `git status --porcelain` is empty

## Integration

**Called by** [REQUIRED — an approved plan must exist]: `/myspec:feature-plan`
**Next** [OPTIONAL reviews, then REQUIRED completion]: `/myspec:feature-implement-review` and/or `/code-review`, then `/myspec:feature-complete`
