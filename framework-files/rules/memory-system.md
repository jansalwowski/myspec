---
title: "Agent Memory System"
purpose: "Prevent debugging loops and preserve knowledge across sessions"
load_when:
  - path_matches: "${aiDir}/sessions/**"
  - skill_invoked: "memory-preflight|memory-create|memory-lookup|session-start|session-complete"
updated: 2026-03-29
---

# Agent Memory System

> **Scope**: this file governs **project-level myspec memory** under `${aiDir}/memory/`
> (sessions, procedural/semantic/episodic, written via `/myspec:memory-create`).
> The **harness-managed user-level auto-memory store** at
> `~/.claude-personal/projects/{encoded-cwd}/memory/` is governed by the
> companion rule `.claude/rules/auto-memory-style.md` (length budget, cut list,
> write-time ADD/UPDATE/NO-OP consolidation).

## Purpose

Prevent AI agents from repeating mistakes and losing knowledge by:
1. Tracking work across context clears (session logs / working memory)
2. Learning from resolved issues (procedural, semantic, episodic memories)
3. Running preventive checks before starting (pre-flight with staleness detection)

## Triggers (BLOCKING)

These are **BLOCKING REQUIREMENTS**. You MUST invoke the specified skill at the specified time.

| When | Action | Why |
|------|--------|-----|
| Session start | MUST invoke `/myspec:bootstrap` | Reads project config + memory indexes, lists active sessions, auto-archives orphans (>1h stale). Replaces manual `/myspec:memory-preflight` at session start. |
| Before significant work mid-session (new feature, multi-file change, debugging) | Invoke `/myspec:memory-preflight` if `/myspec:bootstrap` was not run at session start | Scans all memory types, checks staleness |
| Before trivial work (single-file fix, typo, config change) | Read `${aiDir}/memory/index.md` (Layer 1 only) | Quick check, skip full scan |
| First code edit in any session | **Automatic — no skill** | `mark-code-changed.sh` (PostToolUse) creates `${aiDir}/memory/sessions/active/{session_id}.md` from the session-log template. Per-session-id keying makes this multi-agent safe — each agent gets its own file. |
| Starting a non-code session (debugging without edits, discovery, doc-only work) | Invoke `/myspec:session-start` | Manual creation; auto-creation only fires on code edits |
| Work complete | Invoke `/myspec:session-complete` | Multi-type extraction + archival of the agent's own session file (touches no sibling sessions) |
| User approves memory | Invoke `/myspec:memory-create` | Creates typed memory (procedural/semantic/episodic) |
| Debugging + repeated errors | Invoke `/myspec:memory-lookup` | Searches all memory types for solutions |

## Continuous Behaviors (No Skills)

These behaviors happen continuously during work and cannot be invoked as skills.

### Session Logging

After each significant action, append a row to the session log table:

```
| # | Action | File(s) | Result | Attempt | Type | Note |
```

- **Attempt**: Increment when repeating same/similar approach (triggers escalation at 3+)
- **Result**: ✅ (success) or ❌ (failure)
- **Type**: P (procedural) | S (semantic) | E (episodic)

### Escalation Protocol

Agent **MUST** pause and ask user when ANY of these triggers occur:

| Trigger | Detection |
|---------|-----------|
| Repetition | Same file edited 3+ times without success |
| Same error | Same error appears after 2+ different fixes |
| Reversion | About to try a previously-failed approach |
| Complexity spiral | Adding workarounds without understanding root cause |
| User redirect | User has corrected approach 2+ times |

**Escalation template:** "I've made {N} attempts without success. What I've tried: [list]. Should we review the session log, check for patterns, or take a different approach?"

### Before Risky Changes

Agent **SHOULD** warn user to commit when about to:
- Refactor working code
- Change component lifecycle/mounting
- Modify state management
- Touch integration points

**Risky change template:** "This change touches [X]. Recommend committing current state first."

### Verification Discipline

The Stop hook (`verify-before-stop.sh`) enforces verification checks mechanically. These rules cover what the hook **cannot** check:

**Evidence before claims.** Never use "should work", "probably passes", or express satisfaction before running verification. Run the command → read output → then claim result.

**Common failures:**

| Claim | Requires | Not Sufficient |
|-------|----------|----------------|
| Bug fixed | Reproduce original symptom: passes | Code changed, assumed fixed |
| Requirements met | Line-by-line spec checklist verified | Tests passing |
| Agent task completed | VCS diff shows correct changes | Agent reports "success" |

**Agent delegation:** After a subagent completes, check `git diff` for actual changes before reporting success. Do not trust agent completion claims without evidence.
