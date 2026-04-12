---
name: "session-start"
description: "Use when starting a tracked work session (debugging, discovery, or implementation). Creates ${aiDir}/memory/sessions/active.md with proper structure. Requires /memory-preflight first. Keywords: begin session, new session, start tracking, session log. Do NOT use for quick fixes (<3 actions), research-only tasks, or documentation-only work."
---

# Session Start

## Prerequisites

Requires `/myspec:memory-preflight` or `/myspec:bootstrap` completion before starting a session.

## Workflow

### 1. Check Prerequisites

Confirm `/myspec:memory-preflight` or `/myspec:bootstrap` has been run this session.

If `${aiDir}/memory/sessions/active.md` already exists:
- When `status: active` — warn user and ask whether to archive via `/session-complete` first
- When `status: completed` — proceed (stale file, safe to overwrite)

### 2. Determine Mode

Ask or infer from task context:

- `debugging` — Repeated errors, stuck loops, investigating failures
- `discovery` — Exploring unfamiliar code, researching how things work
- `implementation` — Building features, significant refactors

### 3. Create Session Log

Write `${aiDir}/memory/sessions/active.md` using the session-log template from `${aiDir}/.templates/session-log.md`.

Fill frontmatter:
- `topic`: Brief description of the work
- `feature`: Feature name or empty for cross-cutting work
- `mode`: The mode from step 2
- `started`: Current timestamp (YYYY-MM-DD HH:MM)
- `status`: active

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

- [ ] `/myspec:memory-preflight` or `/myspec:bootstrap` was run before session start
- [ ] No pre-existing `active.md` with `status: active` was silently overwritten
- [ ] `${aiDir}/memory/sessions/active.md` exists with correct frontmatter
- [ ] Mode is one of: `debugging`, `discovery`, `implementation`
- [ ] Context section has 1-2 sentence goal

## When NOT to Use

- Quick fixes without debugging (<3 actions)
- Research tasks
- Documentation-only work
