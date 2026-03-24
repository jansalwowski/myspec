---
description: "Use when starting a tracked work session (debugging, discovery, or implementation). Creates ${aiDir}/memory/sessions/active.md with proper structure. Requires /myspec:memory-preflight first. Do NOT use for quick fixes (<3 actions), research-only tasks, or documentation-only work."
---

# Session Start

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Prerequisites

You must have completed `/myspec:memory-preflight` before starting a session.

## Procedure

### 1. Check Prerequisites

Confirm `/myspec:memory-preflight` has been run this session.

### 2. Determine Mode

Ask or infer from task context:

- `debugging` — Repeated errors, stuck loops, investigating failures
- `discovery` — Exploring unfamiliar code, researching how things work
- `implementation` — Building features, significant refactors

### 3. Create Session Log

Write `${aiDir}/memory/sessions/active.md` using the session-log template from `${aiDir}/templates/session-log.md`.

Fill frontmatter:
- `topic`: Brief description of the work
- `feature`: Feature name or empty for cross-cutting work
- `mode`: The mode from step 2
- `started`: Current timestamp (YYYY-MM-DD HH:MM)
- `status`: active

### 4. Fill Initial Context

Write 1-2 sentence goal in the Context section.

## Session Log Template

Copy the template at `${aiDir}/templates/session-log.md` to `${aiDir}/memory/sessions/active.md` and fill in the frontmatter fields from step 3.

> Do not maintain a separate inline template here — `${aiDir}/templates/session-log.md` is the single source of truth.

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
| 1 | Update component props | Panel.ts:42 | ❌ | 1 | P | |
| 2 | Update component props | Panel.ts:42 | ❌ | 2 | P | Same approach! |
| 3 | Destroy/recreate instance | Panel.ts:35-70 | ✅ | 1 | P | Per user hint |
| 4 | Found geocoding uses OpenCage API | geocodeService.ts | 💡 | 1 | S | Not Google as assumed |
```

## When NOT to Use

- Quick fixes without debugging (<3 actions)
- Research tasks
- Documentation-only work
