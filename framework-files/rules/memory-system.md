---
title: "Agent Memory System"
purpose: "Prevent debugging loops and preserve knowledge across sessions"
updated: 2026-10-07
---

# Agent Memory System

Governs the project-level memory under `${aiDir}/memory/`. User-level auto-memory: `.claude/rules/auto-memory-style.md`. Procedures are in the skills, protocols in `${aiDir}/pre-flight.md`.

## Triggers

| When | Action |
|------|--------|
| Session start | `/myspec:bootstrap` — Layer 1, memory health, session sweep; Layer 2 only when given a task |
| Before significant work (new feature, multi-file change, debugging) | `/myspec:memory-preflight`, unless bootstrap already scanned Layer 2 for this task |
| Before trivial work (single-file fix, typo, config) | Read `${aiDir}/memory/index.md` only |
| First code edit | Automatic — `mark-code-changed.sh` appends every code path, Bash writes included, to `## Files touched` in `.claude/state/sessions/{session_id}.md`, shared with subagents |
| Non-code session (debugging without edits, discovery, doc-only) | `/myspec:session-start` |
| Repeated failure — same file edited 3+ times, same error after 2 different fixes, about to retry a failed approach | `/myspec:memory-lookup`, then pause and ask the user. Protocol and message template: `${aiDir}/pre-flight.md` |
| Debugging an unfamiliar error | `/myspec:memory-lookup` |
| Work complete | `/myspec:session-complete` — extraction plus archive of your own session file only |
| User says "remember / note / keep in mind …" | Project fact (environment, gotcha, decision, convention) → `/myspec:memorize`, not auto-memory. Personal preference (style, role) → auto-memory. `/memorize` always wins |
| User approves a memory | `/myspec:memory-create` |
| Allocating a memory ID | `/myspec:memory-create` claims it (`memory-claim-id.sh`) — never pick a number from the index; parallel sessions collide. Exit 3 → fix the conformance errors it printed |
| After adding, removing, or superseding a memory | The skill that edited it regenerates the tables (`/myspec:memory-create`, `/myspec:memory-optimize`); never hand-write an index row. On an `index.md` merge conflict keep either side and regenerate |
| Memory drift suspected | `/myspec:memory-optimize` — runs the doctor, which reports each disagreement and its fix |
| Before reporting anything as done | Run the check and read the output first; "should work" is not a result |

## Budgets

| Layer | Loaded | Budget | Where |
|-------|--------|--------|-------|
| 1 | Always | ~200 tokens | `${aiDir}/memory/index.md` — critical anti-patterns, one line per type index |
| 2 | Per task | ~40 tokens per row | `${aiDir}/memory/{procedural,semantic,episodic}/index.md` |
| 3 | On demand | Unlimited | Individual memory files, `${aiDir}/memory/sessions/archive/` |

Episodic memories older than 30 days consolidate into semantic facts; `/myspec:memory-preflight` flags the candidates.

## Session lifecycle

| Aspect | Convention |
|--------|-----------|
| Live file | `.claude/state/sessions/{session_id}.md` in the edited file's **main checkout** — gitignored, never in a linked worktree (`git worktree remove` would destroy it) |
| Own session | The live file whose `## Files touched` lists a path you edited untagged, or tags your subagent; several or none → newest mtime, and confirm. You never see your session id; never pass this one to `set-isolation.sh` |
| Archive file | `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md`; topic-less sweeps use `orphaned-{first 8 of session_id}` |
| Terminal statuses | `completed` (via `/myspec:session-complete`) or `abandoned` (swept). Archive is a location, not a status |
| Age policy | mtime < 1h: live, never touch. 1–6h: ambiguous, route to `/myspec:session-clean`. > 6h: sweep as `abandoned` |
| Ownership | Own → `/myspec:session-complete`; others' → `/myspec:session-clean` or bootstrap's > 6h sweep |
