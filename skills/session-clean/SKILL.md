---
name: session-clean
description: "Use when sweeping dangling auto-created session files in ai/memory/sessions/active/. Keywords: session cleanup, dangling sessions, archive sessions, session sweep. Deletes empty sessions, archives substantive ones, never touches the running agent's own session or files modified within the last hour. Do NOT use to archive the running agent's own active session (use /myspec:session-complete) or to clean worktrees (use /myspec:worktree-cleanup)."
---

# Session Clean

Sweep abandoned session files in `ai/memory/sessions/active/`. Empty templates are deleted; sessions with real content are archived.

**Announce at start:** "Running session cleanup audit."

**Hard rules** (apply throughout):
- Never delete a substantive session — archive instead.
- Never touch a file with `mtime` < 1h without explicit confirmation.
- Never touch `archive/`.
- Never act on a session whose `cwd` matches a live worktree without per-file confirmation.

## Workflow

### Step 1: Inventory

List `ai/memory/sessions/active/*.md`. For each file capture: `session_id` (from filename and frontmatter), `mtime`, frontmatter fields (`status`, `cwd`, `auto_created`, `topic`, `feature`, `started`).

Skip the file whose `session_id` matches the current agent's session (env `CLAUDE_SESSION_ID` if set; otherwise treat the most recently mtime-bumped file as potentially yours and route to ambiguous in Step 3).

### Step 2: Classify Content

For each file, parse the body:

- **Empty**: zero data rows in the `## Log` table (only header + separator), `## Insights` section blank, all `## Outcome` bullets blank (`**What worked**:` etc. have no text after the colon).
- **Substantive**: any of the above contains real content.

### Step 3: Liveness Gate

A file is **safe to act on** only if ALL hold:

- `mtime` is more than 1 hour ago (`date +%s` minus file mtime > 3600)
- `cwd:` from frontmatter is **not** present in **non-main entries** of `git worktree list --porcelain` (the main checkout is always listed but considered shared — for sessions whose `cwd` is the main checkout, use mtime alone). `cwd` missing also passes.
- `status:` is `active` (defensive: skip anything else)

If `mtime` is 1–6h old OR `cwd` matches a live worktree but no commits in last 1h → **ambiguous**.

### Step 4: Decide Action

| Classification | Liveness | Action |
|---|---|---|
| Empty | safe | DELETE (`rm`) |
| Substantive | safe | ARCHIVE (`git mv` to `archive/{session_id}.md`, set `status: archived` in frontmatter) |
| Empty or Substantive | ambiguous | ASK per file |
| Any | live (mtime <1h or live worktree+recent) | SKIP |

### Step 5: Report

Print a table before any mutation:

```
## Session Cleanup Audit

| # | session_id (short) | topic | classification | mtime | action | reason |
|---|---|---|---|---|---|---|
| 1 | 40b2f520 | auto:mockups | empty | 1d ago | DELETE | no log/insights/outcome |
| 2 | f73e26d3 | auto:calibration | substantive | 2d ago | ARCHIVE | 3 log rows |
| 3 | abc12345 | bugfix-x | empty | 30m ago | SKIP | mtime <1h (likely live) |

Summary: 1 to delete, 1 to archive, 1 skipped, 0 ambiguous
```

### Step 6: Confirm and Execute

Ask: "Proceed? (yes / no / selective)"

- **yes**: execute all recommended actions
- **no**: exit
- **selective**: prompt per row

For ambiguous rows, ask per file: `delete / archive / skip`.

For ARCHIVE: edit frontmatter `status: active` → `status: archived`, then `git mv` to `archive/`.
For DELETE: `rm` (not `git rm` — these are typically untracked auto-created files; if tracked, fall back to `git rm`).

Print one-line summary on completion.

## Constraints

- **Never** delete a substantive session — archive instead. Content is signal even if abandoned.
- **Never** touch a file with `mtime` < 1h without asking, even if it looks empty (live agent may not have logged yet).
- **Never** touch `archive/`. Pruning historical record is out of scope.
- **Never** act on a file whose `cwd:` matches a live worktree without explicit per-file confirmation.

## Verification Checklist

- [ ] Listed all `ai/memory/sessions/active/*.md` files
- [ ] Skipped current agent's own session (matched `CLAUDE_SESSION_ID` or marked ambiguous)
- [ ] Each file classified empty or substantive
- [ ] Liveness gate applied (mtime > 1h, cwd not in `git worktree list`, status=active)
- [ ] Audit table printed before any mutation
- [ ] User confirmed before any delete/archive
- [ ] Substantive sessions archived with `status: archived` set in frontmatter
- [ ] Empty sessions removed (`rm`, or `git rm` if tracked)
- [ ] No file under `archive/` was touched
- [ ] Final one-line summary printed
