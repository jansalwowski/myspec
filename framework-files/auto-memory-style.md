---
title: "Auto-Memory Style Guide"
purpose: "Keep and cut lists, and conflict resolution, for user-level auto-memory entries"
updated: 2026-11-15
---

# Auto-Memory Style Guide

Governs entries in the harness-managed user-level auto-memory store at `<config_dir>/projects/<encoded_cwd>/memory/` (`<config_dir>` is `$CLAUDE_CONFIG_DIR`, default `~/.claude`). Project-level myspec memory under `${aiDir}/memory/` is out of scope — it has its own typed templates and `.claude/rules/memory-system.md`.

The lesson is the **rule** plus the **trigger** plus the **minimal pattern**; everything else is a token tax paid on every recall. It applies when an entry is written and during `/myspec:memory-sanitize` COMPRESS passes.

## What to keep

The length caps and the ADD / UPDATE / NO-OP check are in `.claude/rules/memory-system.md`, which every session loads.

**Keep:** the rule (1 line); the trigger or detection cue (1–2); why, only when non-obvious (1); how to apply — minimal pattern, signature, or command (1–3); the caveat docs will not tell you (1–2). At most one code block, ≤ 6 lines, no imports or boilerplate.

**Cut:** the originating incident (the seed, not the lesson); full code blocks where a one-liner suffices; "where applied: file:line, PR #X" (rots — `grep` finds usage); restatements; date-bound references and SHAs.

## Conflicts

When two kept memories contradict, newer wins: the older gets `status: superseded` in its frontmatter and a one-line body `Superseded by [{survivor}](./{survivor}).`, leaves `MEMORY.md`, and stays on disk as an audit trail.
