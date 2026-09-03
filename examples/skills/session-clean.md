# `/myspec:session-clean` — examples

Sweeps abandoned session files in `.claude/state/sessions/`. Empty templates are deleted; sessions with real content are archived. Pairs with the `mark-code-changed.sh` hook that auto-creates active sessions on first code edit — over time those auto-created files pile up if no one runs `/myspec:session-complete` on them.

> **Related**: For wrapping up a *single* session you've been actively working in, use [`/myspec:session-complete`](session-complete.md). `session-clean` is the broom for the leftovers — sessions other agents started and never closed.

**Contents**

- [Routine sweep — mixed empty and substantive](#routine-sweep--mixed-empty-and-substantive)
- [Ambiguous siblings — live worktree detected](#ambiguous-siblings--live-worktree-detected)
- [Nothing to do — clean active directory](#nothing-to-do--clean-active-directory)

---

## Routine sweep — mixed empty and substantive

The high-yield case: the active directory has accumulated a week of auto-created sessions from various aborted starts and completed-but-never-archived work.

### Setup

The user hasn't run a sweep in a while. `.claude/state/sessions/` contains:

```
2026-04-23-1015-automockups.md      (mtime 8d ago,   empty template, status: active)
2026-04-24-0900-autocalibration.md  (mtime 7d ago,   3 log rows + 1 insight, status: active)
2026-04-27-1432-bugfix-oauth.md     (mtime 4d ago,   empty template, status: active)
2026-04-30-1100-currentwork.md      (mtime 12m ago,  in progress — this agent's own session)
```

The first three are leftovers from earlier sessions where the auto-create hook fired but `/myspec:session-complete` was never run.

### Invocation

```
/myspec:session-clean
```

### Skill flow

#### 1. Announce + inventory

> Running session cleanup audit.

Lists the four files, captures `mtime`, `status`, `cwd`, and topic from frontmatter. Identifies `2026-04-30-1100-currentwork.md` as the running agent's own session via `CLAUDE_SESSION_ID` and skips it from consideration.

#### 2. Classify content

Parses each remaining file's body:

- `2026-04-23-1015-automockups.md` — log table has only header + separator, Insights blank, Outcome bullets blank → **empty**
- `2026-04-24-0900-autocalibration.md` — 3 data rows in log table, one Insight written → **substantive**
- `2026-04-27-1432-bugfix-oauth.md` — empty template, never written to → **empty**

#### 3. Liveness gate

For each candidate:

- All three have `mtime` more than 1h ago ✓
- `git worktree list --porcelain` shows only the main checkout — no `cwd` matches a non-main worktree ✓
- All have `status: active` ✓

All three pass. Safe to act.

#### 4. Audit table

```
## Session Cleanup Audit

| # | session_id (short) | topic              | classification | mtime  | action  | reason                |
|---|--------------------|--------------------|----------------|--------|---------|------------------------|
| 1 | a1b2c3d4           | auto:mockups       | empty          | 8d ago | DELETE  | no log/insights/outcome |
| 2 | f73e26d3           | auto:calibration   | substantive    | 7d ago | ARCHIVE | 3 log rows, 1 insight   |
| 3 | 9e8d7c6b           | bugfix-oauth       | empty          | 4d ago | DELETE  | no log/insights/outcome |

Skipped: 2026-04-30-1100-currentwork.md (running agent's own session)

Summary: 2 to delete, 1 to archive, 1 skipped, 0 ambiguous.

Proceed? (yes / no / selective)
```

User: `yes`.

#### 5. Execute

For row 2 (archive): edits frontmatter `status: active` → `status: abandoned`, then `mv .claude/state/sessions/2026-04-24-0900-autocalibration.md ai/memory/sessions/archive/2026-04-24-0900-autocalibration.md`.

For rows 1 and 3 (delete): `rm` (untracked auto-created files).

#### 6. Final summary

> Deleted 2 empty sessions, archived 1 substantive session. Skipped 1 (your own).

### Why this example matters

- **Empty ≠ deletable on its own.** The empty/substantive split protects against deleting work-in-progress where someone wrote a single insight and walked away. Substantive always archives.
- **The agent's own session is sacrosanct.** If `session-clean` ever archived the file the running agent is logging into, the next log append would fail. The `CLAUDE_SESSION_ID` skip is load-bearing.
- **The 1-hour mtime gate is the second safety net.** Even if the env var were missing, anything younger than 1h is left alone — covers the case where a sibling agent in another terminal started a session 30 minutes ago.
- **Audit-then-confirm is the contract.** The skill never mutates without showing the table first. That makes the difference between "I'll trust this every time" and "I'll never run it."

---

## Ambiguous siblings — live worktree detected

When parallel agents are working in worktrees, some "abandoned" sessions are actually still live. The skill detects this and asks per file rather than barreling through.

### Setup

The user kicked off a parallel-group `feature-implement` phase 2h ago. Three subagents are working in worktrees `wt-T2/`, `wt-T3/`, `wt-T4/`. The user has switched terminals and run `/myspec:session-clean` from the main checkout.

`.claude/state/sessions/` contains:

```
2026-04-30-0900-orchestrator.md   (mtime 5m ago,    cwd = main checkout, this session)
2026-04-30-0905-T2.md              (mtime 90m ago,   cwd = /tmp/wt-T2,    1 log row)
2026-04-30-0905-T3.md              (mtime 45m ago,   cwd = /tmp/wt-T3,    2 log rows)
2026-04-30-0905-T4.md              (mtime 2m ago,    cwd = /tmp/wt-T4,    in progress)
2026-04-29-1500-leftover.md        (mtime 1d ago,    cwd = main, empty template)
```

`git worktree list --porcelain` confirms `/tmp/wt-T2`, `/tmp/wt-T3`, and `/tmp/wt-T4` are all live worktrees.

### Invocation

```
/myspec:session-clean
```

### Skill flow

#### 1. Inventory + skip self

Skips `2026-04-30-0900-orchestrator.md` (current agent's session).

#### 2. Classify + liveness gate

| File | Classification | mtime check | worktree check | Result |
|---|---|---|---|---|
| T2 | substantive (1 row) | >1h ✓ | cwd matches live worktree ✗ | **ambiguous** |
| T3 | substantive (2 rows) | <1h | cwd matches live worktree ✗ | **live → SKIP** |
| T4 | substantive | <1h | live worktree | **live → SKIP** |
| leftover | empty | >1h ✓ | cwd is main checkout (shared) | **safe → DELETE** |

T2 is the interesting one: mtime says it's been quiet for 90 min, but the worktree is still checked out — the subagent might be mid-task in a long operation, or it might genuinely have crashed.

#### 3. Audit table

```
## Session Cleanup Audit

| # | session_id  | topic           | classification | mtime   | action    | reason                              |
|---|-------------|-----------------|----------------|---------|-----------|--------------------------------------|
| 1 | aa11bb22    | leftover        | empty          | 1d ago  | DELETE    | no content, mtime old, cwd=main      |
| 2 | bb33cc44    | T2 work         | substantive    | 90m ago | ASK       | cwd matches live worktree /tmp/wt-T2 |
| 3 | cc55dd66    | T3 work         | substantive    | 45m ago | SKIP      | mtime <1h (likely live)              |
| 4 | dd77ee88    | T4 work         | substantive    | 2m ago  | SKIP      | mtime <1h (likely live)              |

Skipped: orchestrator (running agent's own).

Summary: 1 to delete, 0 to archive, 2 skipped (live), 1 ambiguous.

Proceed with deletes? (yes / no / selective)
```

User: `yes`.

`leftover` is removed. Then:

```
Per-file decision needed:

  bb33cc44 (T2 work) — substantive, mtime 90m ago, cwd /tmp/wt-T2 is a live worktree.
  The subagent in this worktree may still be running a long task, or may have crashed.

  Options: archive / skip / delete (delete refused — substantive)
```

User: `skip` (they want to check on the T2 subagent in person before deciding).

#### 4. Final summary

> Deleted 1 empty session, skipped 3 live sessions, deferred 1 ambiguous. Re-run after parallel agents finish.

### Why this example matters

- **Worktree match overrides "old enough" intuition.** A 90-minute-quiet session in a live worktree is far more likely to be a long-running build than abandoned work. The skill flags it instead of guessing.
- **Substantive can never be deleted, only archived or skipped.** Even on per-file confirmation. This is a hard rule, not a default.
- **The main checkout is treated as shared.** Sessions whose `cwd` is the main repo path don't trip the worktree-match check (every agent uses the main checkout) — they fall back to mtime. Otherwise the skill could never delete anything.

---

## Nothing to do — clean active directory

Running it on a tidy directory should be a no-op, not noise.

### Setup

`.claude/state/sessions/` contains only `2026-04-30-1100-currentwork.md` — the running agent's own in-progress session.

### Invocation

```
/myspec:session-clean
```

### Skill flow

```
Running session cleanup audit.

Inventory: 1 active session.

| # | session_id | topic        | classification | mtime  | action | reason                            |
|---|------------|--------------|----------------|--------|--------|------------------------------------|
| 1 | xy12ab34   | currentwork  | (skipped)      | 12m ago| SKIP   | running agent's own session        |

Summary: 0 to delete, 0 to archive, 1 skipped, 0 ambiguous.

Nothing to clean.
```

No prompt, no mutation, exits cleanly.

### Why this example matters

- **A clean directory is the goal state, not a failure mode.** The skill should be safe to run on a cron / pre-commit hook / weekly habit — most of the time it'll find nothing.
- **Still prints the audit row for the skipped self-session.** Confirms the safety check fired. If a future bug ever caused the skill to *not* skip the running session, this row would be missing — and the user would notice.
