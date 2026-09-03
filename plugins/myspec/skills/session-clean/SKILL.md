---
name: session-clean
description: "Use when sweeping dangling session files in .claude/state/sessions/ or orphaned untracked files in ${aiDir}/memory/sessions/archive/. Keywords: session cleanup, dangling sessions, session sweep, orphaned archives, empty session pruning. Do NOT use to archive the running agent's own active session (session-complete) or to clean worktrees (worktree-cleanup)."
---

# Session Clean

Sweep abandoned session files in `.claude/state/sessions/` (live logs — gitignored, primary checkout), plus orphaned (untracked) files in `${aiDir}/memory/sessions/archive/`. Empty / no-value sessions are deleted; substantive active sessions are archived; substantive archived sessions are left alone.

**Announce at start:** "Running session cleanup audit."

**Hard rules** (apply throughout):
- Never delete a substantive *active* session — archive instead. Content is signal even if abandoned.
- Never touch a file with `mtime` < 1h without explicit confirmation — a live agent may not have logged yet.
- Never touch a **tracked** file under `archive/` — pruning committed history is out of scope. Untracked files in `archive/` are in scope but require per-file confirmation.
- Never delete a substantive orphaned archive file without explicit confirmation — content has value even if uncommitted.
- Never act on a session whose `worktree:` marker matches a live worktree without per-file confirmation.

## Workflow

### Step 1: Inventory

List `.claude/state/sessions/*.md` and `${aiDir}/memory/sessions/archive/*.md`. For each file capture: `session_id` (from filename and frontmatter), `mtime`, location (`active` | `archive`), for archive files the tracked-by-git flag (`git ls-files --error-unmatch <path>` exits 0 if tracked; live logs are never tracked — the state directory is gitignored), frontmatter fields (`status`, `worktree`, `auto_created`, `topic`, `feature`, `started`), and the `## Files touched` list.

**Drop from consideration immediately**:
- Tracked files under `archive/` (committed history — out of scope).
- Your own session: the live log whose `## Files touched` lists a path you edited this session. The harness never exposes the session id to the model; if no file lists your edits, treat the most recently mtime-bumped live log as potentially yours and route it to ambiguous in Step 3.

### Step 2: Classify Content

For each file, parse the body. A session is **empty / no value** if it contains only template scaffolding or auto-generated boilerplate with no human or agent insight added:

- **Empty / no value** — any of these patterns:
  - Zero data rows in the `## Log` table (only header + separator), `## Insights` blank, all `## Outcome` bullets blank (`**What worked**:` etc. have no text after the colon).
  - `## Log` contains only auto-generated boilerplate entries (e.g., `session started`, `auto-created`, generic status pings) AND `## Insights` is blank AND `## Outcome` bullets are blank. A row counts as boilerplate if its content adds no recoverable information beyond what the frontmatter already encodes.
- **Substantive**: anything else — at least one log row with real content, or any text under `## Insights`, or any populated `## Outcome` bullet.

When in doubt between boilerplate and substantive, treat as substantive (safer side).

### Step 3: Liveness Gate

A file is **safe to act on** only if ALL hold:

- `mtime` is more than 6 hours ago (`date +%s` minus file mtime > 21600) — the 1–6h band is ambiguous, below
- `worktree:` from frontmatter does **not** match a **non-main entry** of `git worktree list --porcelain` (compare `worktree:` against entry basenames; the main checkout is always listed but considered shared — for sessions without a worktree marker, use mtime alone). Field missing also passes.
- For live logs: `status:` is `active` (defensive: skip anything else). For untracked files in `archive/`: `status:` is a terminal status (`completed` | `abandoned`) or missing; `status: active` inside `archive/` is anomalous, route to ambiguous.

If `mtime` is 1–6h old OR the worktree marker matches a live worktree but no commits in last 1h → **ambiguous**.

### Step 4: Decide Action

| Location | Classification | Liveness | Action |
|---|---|---|---|
| `active/` | Empty / no value | safe | DELETE (`rm`) |
| `active/` | Substantive | safe | ARCHIVE (`mv` to `archive/YYYY-MM-DD-{slug}.md`, set `status: abandoned` in frontmatter; the archive is committed content, so `git add` it and tell the user) |
| `active/` | Empty or Substantive | ambiguous | ASK per file |
| `archive/` (untracked, orphaned) | Empty / no value | safe | ASK per file — recommend DELETE (`rm`); orphan with no value and no git history to preserve |
| `archive/` (untracked, orphaned) | Substantive | safe | SKIP — already in archive, content has value, leave for the user to commit |
| `archive/` (untracked, orphaned) | any | ambiguous | ASK per file |
| Any | any | live (mtime <1h or live worktree+recent) | SKIP |

### Step 5: Report

Print a table before any mutation:

```
## Session Cleanup Audit

| # | session_id (short) | loc | tracked | topic | classification | mtime | action | reason |
|---|---|---|---|---|---|---|---|---|
| 1 | 40b2f520 | active | no | auto:mockups | empty | 1d ago | DELETE | no log/insights/outcome |
| 2 | f73e26d3 | active | no | auto:calibration | substantive | 2d ago | ARCHIVE | 3 log rows |
| 3 | abc12345 | active | no | bugfix-x | empty | 30m ago | SKIP | mtime <1h (likely live) |
| 4 | 9981ee07 | archive | no (orphan) | auto:scratch | empty | 3d ago | ASK→DELETE | orphaned untracked, only boilerplate log |
| 5 | 5512aa11 | archive | no (orphan) | refactor-auth | substantive | 5d ago | SKIP | orphaned but has content; leave for user to commit |

Summary: 1 to delete, 1 to archive, 1 orphan-delete (after ask), 2 skipped, 0 ambiguous
```

### Step 6: Confirm and Execute

Ask: "Proceed? (yes / no / selective)"

- **yes**: execute all recommended actions; orphan-deletes in `archive/` still require per-file confirmation
- **no**: exit
- **selective**: prompt per row

For ambiguous rows, ask per file: `delete / archive / skip`.
For orphaned `archive/` rows marked ASK→DELETE, ask per file: `delete / skip`.

For ARCHIVE: edit frontmatter `status: active` → `status: abandoned` (the session was swept, not completed — `/myspec:session-complete` owns `completed`), then `mv` to `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md` and `git add` it. Slug: kebab-case of `topic`; if topic is empty or still `auto:*`, use `orphaned-{first 8 of session_id}`. Date: from `started:` if parseable, else today.
For DELETE of a live log: `rm`.
For DELETE in `archive/` (orphan): `rm` only — never run `git rm` here (in-scope archive files are always untracked by construction).

Print one-line summary on completion.

## Verification Checklist

- [ ] Listed all `.claude/state/sessions/*.md` and `${aiDir}/memory/sessions/archive/*.md` files
- [ ] Filtered out tracked files in `archive/`
- [ ] Skipped current agent's own session (matched by `## Files touched`, or marked ambiguous)
- [ ] Each file classified empty/no-value or substantive (boilerplate-only logs counted as empty)
- [ ] Liveness gate applied (mtime > 6h safe / 1–6h ambiguous, worktree marker not in `git worktree list`, status check)
- [ ] Audit table printed before any mutation (with `loc` and `tracked` columns)
- [ ] User confirmed before any delete/archive
- [ ] Orphaned archive deletes confirmed per file
- [ ] Substantive active sessions archived to `archive/YYYY-MM-DD-{slug}.md` with `status: abandoned` set in frontmatter
- [ ] Empty live logs removed (`rm`)
- [ ] Empty orphaned archive sessions removed (`rm` only)
- [ ] No tracked file under `archive/` was touched
- [ ] Final one-line summary printed
