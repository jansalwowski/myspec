---
name: worktree-cleanup
description: "Use when cleaning up stale git worktrees and orphaned branches. Keywords: worktree cleanup, prune worktrees, stale branches, orphaned worktrees, git cleanup. Do NOT use for branch creation or feature branching."
---

# Worktree Cleanup

Audit and clean up git worktrees and orphaned agent branches.

**Announce at start:** "Running worktree cleanup audit."

## Workflow

### Step 1: Inventory Worktrees

Run `git worktree list --porcelain` and parse output. Skip the main checkout (first entry). For each additional worktree extract: path, HEAD SHA, branch name.

### Step 2: Classify Each Worktree

For each non-main worktree, determine its status:

- **orphaned**: Worktree path does not exist on disk (`[ ! -d <path> ]`)
- **dirty**: Has uncommitted changes (`git -C <path> status --porcelain` returns output)
- **merged**: HEAD is ancestor of main (`git merge-base --is-ancestor <sha> main` exits 0)
- **stale**: Last commit older than 3 days (`git -C <path> log -1 --format=%ct` vs current epoch)
- **active**: None of the above

Priority order: orphaned → dirty → merged → stale → active

### Step 3: Find Orphaned Branches

```bash
git branch --list 'worktree-agent-*'
```

Cross-reference against active worktrees from Step 1. Any `worktree-agent-*` branch with no corresponding worktree path is orphaned.

### Step 4: Present Report

Output a table before taking any action:

```
## Worktree Audit

| # | Path | Branch | Status | Last Commit | Action |
|---|------|--------|--------|-------------|--------|
| 1 | .claude/worktrees/agent-abc | worktree-agent-abc | merged+stale | 5d ago | PRUNE |
| 2 | .claude/worktrees/feat-x | feat/x | dirty | 1h ago | KEEP |
| 3 | (missing) | worktree-agent-def | orphaned | — | PRUNE BRANCH |

Orphaned branches (no worktree): worktree-agent-ghi, worktree-agent-jkl

Summary: N worktrees to prune, N branches to delete
```

### Step 5: Confirm and Execute

Ask: "Proceed with recommended cleanup? (yes / no / selective)"

- **yes**: Execute all recommended actions
- **no**: Exit without changes
- **selective**: User picks which items to clean

For each worktree to prune:
1. `git worktree remove <path>` — if fails, try `git worktree remove --force <path>` only with explicit user confirmation for dirty worktrees
2. `git branch -d <branch>` — if not fully merged, show warning and require explicit confirmation before using `-D`

For orphaned branches: `git branch -d <branch>` (or `-D` with explicit confirmation if unmerged)

Final always: `git worktree prune` to clean dangling references.

## Constraints

- **Never** remove a dirty worktree without explicit confirmation — show uncommitted changes first (`git -C <path> diff --stat`)
- **Never** force-delete an unmerged branch without explicit confirmation
- **Always** present the full report before executing any action

## Verification Checklist

- [ ] Audit report shown before any mutation; user confirmed the actions
- [ ] Every dirty-worktree removal and unmerged-branch delete had its own explicit confirmation
- [ ] `git worktree list` shows none of the removed worktrees; deleted branches absent from `git branch`
- [ ] `git worktree prune` run last; no dangling references remain
