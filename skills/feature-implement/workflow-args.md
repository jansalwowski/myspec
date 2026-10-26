# Workflow Mode: args Contract and Status Table

Read from SKILL.md Step 3, "Workflow mode". The plugin workflow `myspec:implement-phase` (`workflows/implement-phase.js`) runs one phase's per-task loop. For each task it runs an implementer, then an independent verify agent, then a standards and spec-contract check on the cheap tier. Every serious finding is re-judged on the mid tier before it costs a fix. A task gets at most two fix rounds, and the second runs one tier up. The workflow then returns a structured result for each task. It flips no checkbox, merges nothing, runs no barrier, and asks nobody anything. The controller keeps every gate.

## args

Pass `args` as a JSON object, not as a JSON-encoded string.

| Field | Required | Value |
|-------|----------|-------|
| `feature` | yes | the feature directory name |
| `phase` | yes | the phase number |
| `mode` | yes | `sequential` or `parallel`, from the phase's Mode column |
| `phaseBase` | yes | the `PHASE_BASE` sha recorded before this launch |
| `stateDir` | yes | `$STATE`, absolute. The verify agent writes each task's diff here as `phase-N-task-<id>-r<round>.diff` |
| `planPath` | yes | the plan's repo-relative path. Its uncommitted checkbox edits are not counted as a dirty tree |
| `models` | yes | `{cheap, mid, premium}`: the concrete model for each tier, chosen as in the Model Selection table |
| `reviewDiff` | no | the absolute path of the plugin's `lib/review-diff.sh`, which SKILL.md gives. Without it, the verify agent runs plain `git diff` |
| `checkStage` | no | `false` skips the standards and spec-contract check and its re-judge. Default `true`. Set it only as [Measuring the check stage](#measuring-the-check-stage) says |
| `standards` | no | repo-relative paths of the project standards the check reads, such as conventions files and `.claude/rules/` files. Empty means the check covers the spec contract only |
| `tasks` | yes | one entry per task in the phase, in plan order |

Each `tasks` entry:

| Field | Required | Value |
|-------|----------|-------|
| `id` | yes | the task number |
| `name` | no | the task name |
| `tier` | yes | `cheap`, `mid` or `premium`: the implementer tier, chosen as in controller mode |
| `workdir` | yes | absolute path: your checkout for a sequential task, or the task worktree you created for a parallel one |
| `implementerPrompt` | yes | `implementer-prompt.md`'s prompt, filled exactly as for a controller-mode dispatch (task text, context, plan drift, isolation constraint, Verify command, commit trailers) |
| `files` | yes | the paths from the task's `**Files:**` lines (Create, Modify, Test). A changed file outside them is a scope finding |
| `verifyCommand` | yes | the task's `Verify at phase review:` command |
| `scopedChecks` | no | the file-scoped lint and typecheck commands you would put in the dispatch. Empty or `none` means no scoped check |
| `specContract` | no | the task's `**Spec contract:**` block, verbatim |

A missing or malformed required field returns `started: false`, `reason: "bad-args"` with a `detail`, and dispatches nothing. Fix the payload, or run the phase in controller mode.

## Result

`{started: true, phase, mode, checkStage, tasks: [...], notRun: [ids]}`. `notRun` lists the sequential tasks after a BLOCKED or NEEDS_CONTEXT task, which the workflow did not start. Each task result:

| Field | Meaning |
|-------|---------|
| `status` | `DONE`, `DONE_WITH_CONCERNS`, `OPEN_FINDINGS`, `BLOCKED` or `NEEDS_CONTEXT` |
| `rounds` | fix rounds used, 0 to 2 |
| `head`, `commits`, `changedFiles` | what the last verify run saw |
| `findings` | open findings, each tagged with a `kind`. `check` is a Verify or scoped command that exited non-zero. `scope` is a file outside `files`. `commit` means no commit since the task base. `dirty` is an uncommitted file. `base` means the base is not a commit. `contract` is an upheld standards or spec-contract finding |
| `deferredMinors` | minor findings from the check. They are never re-judged or fixed |
| `notChecked` | commands the verify agent could not run, and checks that returned nothing |
| `notEvidenced` | checks the implementer reported running that the verify agent did not run |
| `concerns`, `summary` | from the implementer and its fix rounds |
| `checkStats` | what the check stage did, summed over every round: `{claims, minor, upheld, rejected, unjudged}`. `claims` counts every finding the check raised, `minor` the deferred ones, and the other three the re-judge verdicts on the rest. `null` when `checkStage` was `false` |

## Status → controller action

| Status | Controller action |
|--------|-------------------|
| `DONE` | Proceed. The barrier and the phase review run as in controller mode |
| `DONE_WITH_CONCERNS` | Read `concerns`, decide as in controller mode, then proceed |
| `OPEN_FINDINGS` | Proceed to the barrier. Pass the task's `findings` to the phase reviewer under "Per-Task Loop Results". The reviewer confirms or rejects each one, and confirmed ones enter Step 4d's fix loop. Do not fix them yourself, and do not launch the workflow again for them |
| `BLOCKED` / `NEEDS_CONTEXT` | Handle as in controller mode: supply the context, raise the tier, split the task, or ask the user. Then launch the workflow again with only that task and the `notRun` tasks, with `phaseBase` set to the current HEAD. That field is only the workflow's diff base: the phase review keeps the recorded `PHASE_BASE`. The task stays `[~]` |
| `started: false` | Fix the payload, or run the phase in controller mode, and log a `Ruling:` |

For every task: append each `deferredMinors` entry to the Execution Log as `Deferred minor (Phase N)`, and log its `checkStats` as `Check stage (Phase N, Task <id>): <claims> claims, <minor> minor, <upheld> upheld, <rejected> rejected, <unjudged> unjudged`, or `Check stage (Phase N, Task <id>): skipped` when it is `null`. Pass `notChecked` and `notEvidenced` to the phase reviewer: they are claims nobody verified, and the barrier's full suite is what decides them.

## Measuring the check stage

The check and its re-judge cost up to two agents per task per round, on top of the verify agent and before the phase reviewer reads the same diff. Nobody has measured whether they catch what the phase review would miss, so the stage stays only while the logs show it earning its cost.

- **Read the logged lines across runs.** `upheld` findings are the stage's catches: each cost a fix round before the phase review. `rejected` findings are re-judge spend on noise from the cheap tier. Many runs with `upheld` at 0, or a phase review that keeps confirming the same findings the stage upheld, say the stage duplicates the phase review.
- **Compare with it off.** When the user asks to run without the check stage, set `checkStage: false` for the whole feature, so every phase runs the same way. Log `Ruling: check stage off for <feature> at the user's request — cost if wrong: findings it would have caught reach the phase review`. Then compare the phase reviewers' Critical and Important findings and the fix rounds they cost against runs with it on.
