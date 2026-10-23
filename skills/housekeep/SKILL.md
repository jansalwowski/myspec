---
name: housekeep
description: "Use when the everyday leftovers should be swept in one go — merged branches and worktrees, stale session state, idle brainstorm sessions — or housekeep is overdue. Keywords: housekeeping, tidy up, sweep, routine cleanup. Do NOT use for a setup health check (doctor) or to groom memories (memory-optimize, memory-sanitize)."
---

# Housekeep

Run the everyday sweep in one script call and report what it did. It asks nothing: every removal is one a rule proves safe, and everything that needs judgement is counted and handed to the skill that asks.

**Announce at start:** "Running housekeep."

## Workflow

### Step 1: Run

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/housekeep.sh"            # lib/housekeep.sh in the myspec repo
```

Give the Bash call a 10-minute timeout: the branch step looks up merged PRs with `gh` for each branch the local proofs cannot settle. Pass `--dry-run` when the user asks what would go, `--no-fetch` when offline.

| Step | Removes without asking | Only counts |
|------|------------------------|-------------|
| branches | branches and worktrees `branch-cleanup.sh --unattended` proves merged, except the branch checked out where it runs | branches with no proof; worktrees that may be in use (git activity or a session in the last 24h, or a running process) or hold ignored files other than dependencies, build output, caches and editor state |
| sessions | `.jsonl` session state older than 24h, with its `.blobs/` and `.bash/` | live logs older than 6h |
| brainstorm | `.myspec/brainstorm/<session>/` idle 7 days with no running server | — |
| memory | — | memory-doctor errors and warnings |

A real run also writes the timestamp that `hooks/housekeep-nudge.sh` reads.

### Step 2: Report

Show the script's lines as printed. A line naming a skill (`run /myspec:worktree-clean`, `run /myspec:session-clean`, `run /myspec:memory-optimize`) is the follow-up: offer it in one line, never run it inline. Those skills ask per item, which is why they are not part of this sweep.

A `FAILED` line or a non-zero exit means a step did not run or a removal was refused: report it as such. An indented `SKIP` line under `branches` is a branch that failed re-verification at apply time; `/myspec:worktree-clean` explains the hold.

## Constraints

- Never delete anything the script left in place, and never add a step by hand. A rule belongs in `lib/housekeep.sh` with a case in `lib/tests/housekeep.test.sh`.
- Never pass `--force` to `git worktree remove` or `rm -rf` a worktree the script kept. A refusal means files exist only there.

| Excuse | Reality |
|--------|---------|
| "That branch was obviously merged, delete it too" | The script found no proof. Hand it to `/myspec:worktree-clean`, which shows why it was held and asks. |
| "The live logs are old, remove them while we're here" | A live log can hold a session's only record. `/myspec:session-clean` archives the substantive ones. |
| "Memory has warnings, fix them now" | Memory fixes need per-item approval. Offer `/myspec:memory-optimize`. |

## Verification Checklist

- [ ] `housekeep.sh` ran once and its output was shown as printed
- [ ] Each follow-up skill the output named was offered, not run
- [ ] Every `FAILED` or `SKIP` line and a non-zero exit were reported
