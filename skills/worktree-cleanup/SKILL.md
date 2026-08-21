---
name: worktree-cleanup
description: "Use when cleaning up stale git worktrees and orphaned branches. Keywords: worktree cleanup, prune worktrees, stale branches, orphaned worktrees, git cleanup, merged branches left behind, squash-merged branch won't delete. Do NOT use for branch creation or feature branching."
---

# Worktree Cleanup

Audit and clean up git worktrees and the branches behind them.

**Announce at start:** "Running worktree cleanup audit."

## Why this delegates to a script

`git branch -d` refuses to delete a branch it considers unmerged, and a squash merge never makes a branch an ancestor of the base — so under a squash-merge workflow every merged branch looks unmerged and `-d` refuses. Reaching for `-D` to get past that discards git's only safety net.

`lib/branch-cleanup.sh` earns the right to use `-D` by proving containment itself, and refuses when it cannot. Do not hand-roll the classification; a "looks merged" judgement is exactly what destroys work.

It also keeps the capability off the bypass path: its git calls happen in a child process, so `guard-git-branch.sh` never sees them and no `MYSPEC_ALLOW_BRANCH_OPS=1` prefix is needed.

## Workflow

### Step 1: Audit

```bash
.claude/lib/branch-cleanup.sh            # lib/branch-cleanup.sh in the myspec repo
```

Read-only. It fetches with `--prune` first (merged PRs leave stale `origin/<branch>` refs behind), classifies every local branch, and prints one line per branch with either the proof of containment or the reason it is held back.

Add `--base <ref>` when the base is not `origin/HEAD`, `--no-fetch` when offline, `--json` to post-process.

### Step 2: Present the report

Show the script's output as-is, then summarise: how many are provably contained, how many are held and why. Do not re-classify anything yourself, and do not describe a KEEP as "probably safe".

### Step 3: Confirm

Ask: "Remove the branches marked DELETE? (yes / no / selective)". Never skip this — the audit is read-only precisely so a human sees it first.

### Step 4: Apply

```bash
.claude/lib/branch-cleanup.sh --apply --branch <name> [--branch <name>]...
```

Every branch is named explicitly; there is no bulk mode. Each is re-verified at apply time, so a stale audit cannot authorise a deletion. The script removes the worktree first (never `--force`), then deletes the branch, then runs `git worktree prune`.

Report exactly what the script printed. A `SKIP` line means the branch was held back on re-verification — surface it, do not retry it.

When the hold is dirty files — `worktree has uncommitted or untracked files`, or a refused removal — those files exist nowhere but that worktree. If the user still wants the branch gone, run `git -C <worktree> status --porcelain -uall`, name the specific files, and offer: commit them to the branch, move them into the main checkout, or delete them (unrecoverable). Carry out the choice, then re-run the audit. Never resolve the hold yourself with `--force` or `rm -rf`.

## What the script proves

Either proof is sufficient; both are checked.

| Proof | Test | Covers |
|-------|------|--------|
| A | Every path the branch touched is byte-identical in the base | Squash merges; works offline |
| B | A merged PR exists **and** the local tip equals its `headRefOid` | Branches whose files the base has since changed |

Proof B without the tip check would delete a branch that was merged and then had new commits added. Proof A alone goes stale as soon as a later PR touches the same files. Neither is redundant.

## Hard vetoes

Any one of these keeps the branch, before proofs are considered:

- it is the current branch, or the base branch
- its worktree has uncommitted or untracked files
- its worktree was touched in the last hour (possibly a live session)
- it was never pushed and has no merged PR
- it has commits ahead of its remote-tracking ref

## Constraints

- **Never** pass `--force` to `git worktree remove`, never `rm -rf` a worktree to get past a refusal, and never edit the script to do so. Git's refusal to drop a dirty tree is the last backstop — a refusal means files exist only there, and "just finishing the cleanup" with force destroys them permanently.
- **Never** delete a branch the script marked KEEP because it "looks merged". If a classification is wrong, fix `classify()` and add a case to `lib/tests/branch-cleanup.test.sh`.
- A stash is repo-global and survives worktree removal — it is not a reason to keep a worktree.

## Verification Checklist

- [ ] Audit output shown to the user before any mutation; user confirmed
- [ ] Every removal went through `--apply --branch`, one flag per branch
- [ ] `git worktree list` no longer shows the removed worktrees
- [ ] `git branch` no longer lists the deleted branches
- [ ] Any `SKIP` or `FAILED` line reported to the user rather than retried
- [ ] `bash lib/tests/branch-cleanup.test.sh` passes if `classify()` was touched
