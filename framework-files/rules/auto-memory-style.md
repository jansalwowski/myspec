---
title: "Auto-Memory Style Guide"
purpose: "Length budget, cut list, and write-time consolidation for user-level auto-memory entries"
updated: 2026-09-03
---

# Auto-Memory Style Guide

Governs entries in the harness-managed user-level auto-memory store at `~/.claude-personal/projects/<encoded_cwd>/memory/`. Project-level myspec memory under `${aiDir}/memory/` is out of scope — it has its own typed templates and `.claude/rules/memory-system.md`.

The lesson is the **rule** plus the **trigger** plus the **minimal pattern**; everything else is a token tax paid on every recall. The budget applies at creation time and during `/myspec:memory-sanitize` COMPRESS passes.

## Length budget

| Type | Body target | Hard cap |
|------|-------------|----------|
| feedback | ≤ 12 lines | 20 |
| project | ≤ 15 lines | 25 |
| semantic | ≤ 8 lines | 15 |
| reference | ≤ 6 lines | 10 |

Index lines in `MEMORY.md`: ≤ 150 characters.

**Keep:** the rule (1 line); the trigger or detection cue (1–2); why, only when non-obvious (1); how to apply — minimal pattern, signature, or command (1–3); the caveat docs will not tell you (1–2). At most one code block, ≤ 6 lines, no imports or boilerplate.

**Cut:** the originating incident (the seed, not the lesson); full code blocks where a one-liner suffices; "where applied: file:line, PR #X" (rots — `grep` finds usage); restatements; date-bound references and SHAs.

## Before writing (ADD / UPDATE / NO-OP)

Scan `MEMORY.md` hooks for keyword overlap with the planned entry and read each hit. **NO-OP** when one already covers it — say "Already covered by `{file}` — open it?" and write nothing. **UPDATE** when one is close but missing this nuance — propose a verbatim diff to that file, never a new one. **ADD** only when truly novel. Append-style growth is the bloat path.

## Conflicts

When two kept memories contradict, newer wins: the older gets `status: superseded` in its frontmatter and a one-line body `Superseded by [{survivor}](./{survivor}).`, leaves `MEMORY.md`, and stays on disk as an audit trail.
