---
name: "session-start"
description: "Use when starting a NON-CODE session (debugging without edits, discovery, doc-only work) — code-editing sessions get their log auto-created by the mark-code-changed.sh hook on first edit. Keywords: begin session, new session, start tracking, debugging session. Do NOT use for code-editing work (auto-handled), quick fixes, or one-shot questions."
---

# Session Start

## When This Skill Applies

Sessions are **auto-created** on first code edit by `mark-code-changed.sh` (PostToolUse hook) at `${aiDir}/memory/sessions/active/{session_id}.md`. Manual invocation is only useful for:

- **Discovery work** — exploring unfamiliar code without editing
- **Debugging without code changes** — investigating logs, configs, or running services
- **Doc-only work** that warrants tracking

For ordinary code-editing work, skip this skill — the hook handles it.

## Prerequisites

`/myspec:memory-preflight` or `/myspec:bootstrap` should have run earlier in the session.

## Workflow

### 1. Check for Existing Active Session

List `${aiDir}/memory/sessions/active/*.md` (excluding `.gitkeep`).

If one exists with `auto_created: true` and recent mtime — that's the auto-created session for the current agent. Refine its frontmatter (topic, feature, mode) instead of creating a new one.

If multiple exist — check `cwd` and `started` fields to identify the relevant one. Multiple-active is normal in multi-agent workflows where subagents created their own sessions.

### 2. Determine Mode

- `debugging` — Repeated errors, stuck loops, investigating failures
- `discovery` — Exploring unfamiliar code, researching how things work
- `implementation` — Building features, significant refactors

### 3. Create or Refine Session Log

**Refining an auto-created session**: edit the existing file. Update `topic`, `feature`, `mode`, set `auto_created: false`, fill the Context section.

**Creating a new manual session** (no auto-created file exists): write a new file at `${aiDir}/memory/sessions/active/{session_slug}.md` where `session_slug` is a short hyphenated topic (since the harness session_id is not exposed to the agent). Use the template at `${aiDir}/.templates/session-log.md`.

Fill frontmatter:
- `session_id`: leave empty if not derivable; the slug serves as the key
- `topic`: Brief description of the work
- `feature`: Feature name or empty for cross-cutting work
- `mode`: The mode from step 2
- `started`: Current timestamp (YYYY-MM-DD HH:MM)
- `status`: active
- `auto_created`: false

### 4. Fill Initial Context

Write 1-2 sentence goal in the Context section.

## Session Logging Guidelines

After each significant action, append a row to the log table:

- **#**: Sequential number
- **Action**: Brief description (e.g., "Update props", "Add lifecycle hook")
- **File(s)**: File path and line number if applicable
- **Result**: ✅ (success), ❌ (failure), or 💡 (discovery)
- **Attempt**: Increment when repeating same/similar approach
- **Type**: Tag each action with the type of knowledge it produces:
  - `P` = procedural (how to do/not do something)
  - `S` = semantic (a fact about the system)
  - `E` = episodic (a significant event or decision)
  This guides multi-type extraction at session-complete.
- **Note**: Optional context, especially for repeated attempts

## Where the Log Lives

Session logs live in the **main checkout of the repository the edited file belongs to** — one queue per repo, whatever cwd the harness hands the hook.

| Edit happened in | Log lands in |
|------------------|--------------|
| The primary checkout | That checkout's `${aiDir}/memory/sessions/active/` |
| A linked worktree (`.claude/worktrees/<slug>/`) | The **main** checkout's `active/`, not the worktree's |
| Another repository (cross-repo session) | **That** repo's main checkout, if it is a myspec project; otherwise no log |

A log inside a worktree is invisible to the staleness sweep and to `/myspec:session-complete`, and `git worktree remove` destroys it (gitignored, unrecoverable). The `Context` line still records the real edited path, worktree segment included.

## Escalation and Risky Changes

Past 2–3 attempts on the same surface, more iteration usually masks a misdiagnosis. The triggers, the pause message, and the commit-first advice for risky changes are in `${aiDir}/pre-flight.md` ("Escalation Triggers", "Before Risky Changes"); the log's Attempt column is what makes them detectable.

## Example Log Entries

```markdown
| # | Action | File(s) | Result | Attempt | Type | Note |
|---|--------|---------|--------|---------|------|------|
| 1 | Update streetview props | StreetViewPanel.vue:42 | ❌ | 1 | P | |
| 2 | Update streetview props | StreetViewPanel.vue:42 | ❌ | 2 | P | Same approach! |
| 3 | Destroy/recreate instance | StreetViewPanel.vue:35-70 | ✅ | 1 | P | Per user hint |
| 4 | Found geocoding uses OpenCage API | geocodeService.ts | 💡 | 1 | S | Not Google as assumed |
```

## Verification Checklist

- [ ] Session file exists at `${aiDir}/memory/sessions/active/{session_id_or_slug}.md`
- [ ] Frontmatter has all required fields populated (topic, mode, started, status)
- [ ] Mode is one of: `debugging`, `discovery`, `implementation`
- [ ] Context section has 1-2 sentence goal
- [ ] Sibling active sessions (other agents' files) were NOT touched

## When NOT to Use

- Code-editing work — auto-creation handles this
- Quick fixes without debugging (<3 actions)
- Documentation-only work that's a one-shot edit
