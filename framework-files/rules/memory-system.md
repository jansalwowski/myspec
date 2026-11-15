---
title: "Agent Memory System"
purpose: "Prevent debugging loops and preserve knowledge across sessions"
updated: 2026-11-15
---

# Agent Memory System

Governs the project-level memory under `${aiDir}/memory/`. Procedures are in the skills, protocols in `${aiDir}/pre-flight.md`. User-level auto-memory: the last section.

## Triggers

| When | Action |
|------|--------|
| Session start | `/myspec:bootstrap` — Layer 1, memory health, session count; Layer 2 only when given a task |
| Before work | Significant (new feature, multi-file change, debugging): `/myspec:memory-preflight`, unless bootstrap already scanned Layer 2 for this task. Trivial (single-file fix, typo, config): read `${aiDir}/memory/index.md` only |
| First code edit | Automatic — `mark-code-changed.sh` appends every code path, Bash writes included, to `## Files touched` in `.claude/state/sessions/{session_id}.md`, shared with subagents |
| Non-code session (debugging without edits, discovery, doc-only) | `/myspec:session-start` |
| Repeated failure — same file edited 3+ times, same error after 2 different fixes, about to retry a failed approach (full list: `${aiDir}/pre-flight.md`) | `/myspec:memory-lookup`, then pause and ask the user |
| Debugging an unfamiliar error | `/myspec:memory-lookup` |
| Work complete | `/myspec:session-complete` — extraction plus archive of your own session file only |
| User says "remember / note / keep in mind …" | Project fact (environment, gotcha, decision, convention) → `/myspec:memorize`, not auto-memory. Personal preference (style, role) → auto-memory. `/memorize` always wins |
| User approves a memory | `/myspec:memory-create` |
| Allocating a memory ID | `/myspec:memory-create` claims it (`memory-claim-id.sh`) — never pick a number from the index; parallel sessions collide. Exit 3 → fix the conformance errors it printed |
| After adding, removing, or superseding a memory | The skill that edited it regenerates the tables (`/myspec:memory-create`, `/myspec:memory-optimize`); never hand-write an index row. On an `index.md` merge conflict keep either side and regenerate |
| Memory drift suspected | `/myspec:memory-optimize` — runs the doctor, which reports each disagreement and its fix |

## Session lifecycle

| Aspect | Convention |
|--------|-----------|
| Live file | `.claude/state/sessions/{session_id}.md` in the edited file's **main checkout** — gitignored, never in a linked worktree (`git worktree remove` would destroy it) |
| Own session | The live file whose `## Files touched` lists a path you edited untagged, or tags your subagent; several or none → newest mtime, and confirm |
| Archive file | `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md` in the main checkout |
| Terminal statuses | `completed` (via `/myspec:session-complete`) or `abandoned` (swept). Archive is a location, not a status |
| Age policy | mtime < 1h: live, never touch. 1–6h: ambiguous, `/myspec:session-clean` asks. > 6h: `/myspec:session-clean` deletes it when empty, else archives it as `abandoned` |
| Ownership | Own → `/myspec:session-complete`; others' → `/myspec:session-clean` |

## User-level auto-memory

The harness store at `<config_dir>/projects/<encoded_cwd>/memory/` (`$CLAUDE_CONFIG_DIR`, default `~/.claude`). Before writing an entry, scan `MEMORY.md` hooks for overlap: **NO-OP** when one already covers it, **UPDATE** that file when one is close, **ADD** only when novel. Body lines, target/cap: feedback 12/20, project 15/25, semantic 8/15, reference 6/10; `MEMORY.md` lines ≤ 150 characters. What to keep and cut, and conflicts: `${aiDir}/auto-memory-style.md`.
