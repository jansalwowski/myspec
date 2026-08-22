---
title: "Agent Memory System"
purpose: "Prevent debugging loops and preserve knowledge across sessions"
load_when:
  - path_matches: "${aiDir}/memory/sessions/**"
  - skill_invoked: "memory-preflight|memory-create|memory-lookup|session-start|session-complete|session-clean"
updated: 2026-03-29
---

# Agent Memory System

This rule governs the **project-level myspec memory** under `${aiDir}/memory/` — sessions plus procedural/semantic/episodic entries, written via `/myspec:memory-create`. The separate **harness-managed user-level auto-memory store** at `~/.claude-personal/projects/<encoded_cwd>/memory/` is governed by the companion rule `.claude/rules/auto-memory-style.md` (length budget, cut list, write-time ADD/UPDATE/NO-OP consolidation).

## Purpose

Prevent AI agents from repeating mistakes and losing knowledge by:
1. Tracking work across context clears (session logs / working memory)
2. Learning from resolved issues (procedural, semantic, episodic memories)
3. Running preventive checks before starting (pre-flight with staleness detection)

## Triggers

These are blocking requirements — skip them and the agent loses context across sessions, repeats prior mistakes, or stomps on a sibling agent's session file.

| When | Action | Why |
|------|--------|-----|
| Session start | Invoke `/myspec:bootstrap` | Reads project config + the Layer 1 memory index, lists active sessions, auto-archives orphans (>6h stale; 1–6h only reported). Scans the Layer 2 indexes only when given a task. |
| Before significant work mid-session (new feature, multi-file change, debugging) | Invoke `/myspec:memory-preflight` unless `/myspec:bootstrap` already scanned Layer 2 for this task | Scans all memory types, checks staleness |
| Before trivial work (single-file fix, typo, config change) | Read `${aiDir}/memory/index.md` (Layer 1 only) | Quick check, skip full scan |
| First code edit in any session | Automatic — no skill | `mark-code-changed.sh` (PostToolUse) creates `${aiDir}/memory/sessions/active/{session_id}.md` from the session-log template. Per-session-id keying makes this multi-agent safe — each agent gets its own file. |
| Starting a non-code session (debugging without edits, discovery, doc-only work) | Invoke `/myspec:session-start` | Manual creation; auto-creation only fires on code edits |
| Work complete | Invoke `/myspec:session-complete` | Multi-type extraction + archival of the agent's own session file (touches no sibling sessions) |
| User approves memory | Invoke `/myspec:memory-create` | Creates typed memory (procedural/semantic/episodic) |
| Allocating a memory ID | `.claude/lib/memory-claim-id.sh <procedural\|semantic\|episodic>` | Locks the main checkout, scans every worktree, returns the next free ID. Never read the index and pick a number — parallel sessions pick the same one and the tables auto-merge silently |
| After adding or removing a memory file | `node .claude/lib/memory-index.mjs` | The index tables are generated from the files; `--check` fails when they drift. A conflict on `index.md` is resolved by keeping either side and re-running |
| Debugging + repeated errors | Invoke `/myspec:memory-lookup` | Searches all memory types for solutions |

## Session Lifecycle (canonical — all skills follow this)

| Aspect | Convention |
|--------|-----------|
| Active file | `${aiDir}/memory/sessions/active/{session_id}.md` (one per agent; auto-created by `mark-code-changed.sh` on first code edit, or by `/myspec:session-start`) |
| Archive file | `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md` — slug from the refined `topic`; sessions swept without a real topic use `orphaned-{first 8 of session_id}` |
| Terminal statuses | `completed` (finished via `/myspec:session-complete`; eligible for memory extraction) or `abandoned` (swept by `/myspec:bootstrap` or `/myspec:session-clean` without completion). There is no `archived` status — archive is a location, not a status. |
| Age policy | mtime < 1h: live, never touch. 1–6h: ambiguous — ask, or report and route to `/myspec:session-clean`. > 6h: safe to sweep. |
| Owners | own session → `/myspec:session-complete`; other agents' dangling sessions → `/myspec:session-clean` (interactive triage) or `/myspec:bootstrap` (auto-archives only > 6h stale ones as `abandoned`) |

### Where session logs live

Session logs always live in the **primary checkout of the repository the edited file belongs to** — one queue per repo, whatever cwd the harness hands the hook.

| Edit happened in | Log lands in |
|------------------|--------------|
| The primary checkout | That checkout's `${aiDir}/memory/sessions/active/` |
| A linked worktree (`.claude/worktrees/<slug>/`) | The **main** checkout's `active/`, not the worktree's |
| Another repository (cross-repo session) | **That** repo's main checkout, if it is a myspec project; otherwise no log |

Why: a log inside a worktree is invisible to the staleness sweep and to `/myspec:session-complete`, and `git worktree remove` silently destroys it (gitignored, unrecoverable). The `Context` line still records the real edited path, worktree segment included.

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

Pause and ask the user when any of these triggers occur — past 2-3 attempts on the same surface, more iteration usually masks a misdiagnosis rather than converging on a fix:

| Trigger | Detection |
|---------|-----------|
| Repetition | Same file edited 3+ times without success |
| Same error | Same error appears after 2+ different fixes |
| Reversion | About to try a previously-failed approach |
| Complexity spiral | Adding workarounds without understanding root cause |
| User redirect | User has corrected approach 2+ times |

**Escalation template:** "I've made {N} attempts without success. What I've tried: [list]. Should we review the session log, check for patterns, or take a different approach?"

### Before Risky Changes

Warn the user and offer to commit current state before any of these — they're easy to lose track of and hard to bisect later:
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
