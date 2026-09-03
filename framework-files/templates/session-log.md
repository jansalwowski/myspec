---
session_id: ""      # harness session id (filename stem); fill if known
topic: ""
feature: ""
mode: ""            # debugging | discovery | implementation
started: YYYY-MM-DD HH:MM
status: active      # active → completed (session-complete) | abandoned (swept)
auto_created: false
worktree: ""        # worktree dir basename if session runs in one; empty on main checkout
---

<!-- Live logs live in .claude/state/sessions/ (gitignored, primary checkout); archives in ${aiDir}/memory/sessions/archive/ -->

# Session: {topic}

## Context
[1-2 sentence goal for this session]

## Log

| # | Action | File(s) | Result | Attempt | Type | Note |
|---|--------|---------|--------|---------|------|------|
| 1 | [action taken] | [file:line] | [✅/❌/💡] | 1 | [P/S/E] | [brief note] |

<!-- Result: ✅ Success | ❌ Failed | 💡 Discovery -->
<!-- Attempt: Increment when repeating same approach. Escalate at 3+ -->
<!-- Type: P = procedural | S = semantic | E = episodic -->

## Insights
[Notable discoveries during work — fill as you go]

## Outcome
<!-- Fill on session-complete -->
- **What worked**:
- **Root cause**:
- **Key insights**:

## Extraction Candidates
<!-- Fill on session-complete — proposed typed memories -->
- [ ] [type] description

## Files touched
<!-- Appended by mark-code-changed.sh on every code edit; keep this section last. A skill recognises its own session by the paths it edited. -->
