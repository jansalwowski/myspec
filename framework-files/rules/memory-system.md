---
title: "Agent Memory System"
purpose: "Prevent debugging loops and preserve knowledge across sessions"
updated: 2026-09-02
---

# Agent Memory System

Governs the project-level memory under `${aiDir}/memory/` (session logs, procedural/semantic/episodic memories). The user-level auto-memory store is governed by `.claude/rules/auto-memory-style.md`. Always loaded, so it holds only triggers and contracts; procedures live in the skills, the escalation and risky-change protocols in `${aiDir}/pre-flight.md`.

## Triggers

| When | Action |
|------|--------|
| Session start | `/myspec:bootstrap` — Layer 1, memory health, session sweep; Layer 2 only when given a task |
| Before significant work (new feature, multi-file change, debugging) | `/myspec:memory-preflight`, unless bootstrap already scanned Layer 2 for this task |
| Before trivial work (single-file fix, typo, config) | Read `${aiDir}/memory/index.md` only |
| First code edit | Automatic — `mark-code-changed.sh` creates `.claude/state/sessions/{session_id}.md` (gitignored, primary checkout), one per agent, and appends every code path to its `## Files touched` — Bash writes included |
| Non-code session (debugging without edits, discovery, doc-only) | `/myspec:session-start` |
| Repeated failure — same file edited 3+ times, same error after 2 different fixes, about to retry a failed approach | Pause and ask the user. `/myspec:memory-lookup` first. Protocol and message template: `${aiDir}/pre-flight.md` |
| Debugging an unfamiliar error | `/myspec:memory-lookup` |
| Work complete | `/myspec:session-complete` — extraction plus archive of your own session file only |
| User approves a memory | `/myspec:memory-create` |
| Allocating a memory ID | `.claude/lib/memory-claim-id.sh <procedural\|semantic\|episodic>` — never read the index and pick a number; parallel sessions pick the same one and the tables auto-merge silently. Exit 3 → fix the conformance errors it printed; never hand-pick |
| After adding, removing, or superseding a memory | `node .claude/lib/memory-index.mjs` — the tables are generated from the files. On an `index.md` merge conflict keep either side and re-run |
| Memory drift suspected | `node .claude/lib/memory-doctor.mjs` — reports what disagrees with the tooling and how to fix it |
| Before reporting anything as done | Run the check, read the output, then claim the result; "should work" is not a result |

## Budgets

| Layer | Loaded | Budget | Where |
|-------|--------|--------|-------|
| 1 | Always | ~200 tokens | `${aiDir}/memory/index.md` — critical anti-patterns, one line per type index |
| 2 | Per task | ~500 tokens per index | `${aiDir}/memory/{procedural,semantic,episodic}/index.md` |
| 3 | On demand | Unlimited | Individual memory files, `${aiDir}/memory/sessions/archive/` |

Episodic memories older than 30 days consolidate into semantic facts; `/myspec:memory-preflight` flags the candidates.

## Session lifecycle

| Aspect | Convention |
|--------|-----------|
| Live file | `.claude/state/sessions/{session_id}.md` in the **main checkout** of the repo the edited file belongs to — gitignored, outside the doc tree, never inside a linked worktree (where `git worktree remove` destroys it) |
| Own session | The live file whose `## Files touched` lists a path you edited; several or none → newest mtime, and confirm. The harness never exposes the session id to the model |
| Archive file | `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md`; sessions swept without a real topic use `orphaned-{first 8 of session_id}` |
| Terminal statuses | `completed` (via `/myspec:session-complete`) or `abandoned` (swept). Archive is a location, not a status |
| Age policy | mtime < 1h: live, never touch. 1–6h: ambiguous — report and route to `/myspec:session-clean`. > 6h: sweep as `abandoned` |
| Ownership | Own → `/myspec:session-complete`; others' → `/myspec:session-clean` or bootstrap's > 6h sweep. Never touch a sibling's fresh file |
