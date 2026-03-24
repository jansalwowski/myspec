---
title: "Memory System Templates"
purpose: "Templates for session logs, memories, and checklists"
updated: 2026-03-24
---

# Memory System Templates

This directory contains templates for the Agent Memory System files.

## Available Templates

| Template | Purpose | Used By |
|----------|---------|---------|
| `memory-procedural.md` | Procedural memory (patterns, anti-patterns) | `/myspec:memory-create type=procedural` |
| `memory-semantic.md` | Semantic memory (codebase facts) | `/myspec:memory-create type=semantic` |
| `memory-episodic.md` | Episodic memory (events, decisions) | `/myspec:memory-create type=episodic` |
| `index-procedural.md` | Procedural memory index | `/myspec:memory-create` |
| `index-semantic.md` | Semantic memory index | `/myspec:memory-create` |
| `index-episodic.md` | Episodic memory index | `/myspec:memory-create` |
| `session-log.md` | Active session (working memory) | `/myspec:session-start` |
| `feature-pre-flight.md` | Feature-specific checklist | Manual |
| `example-usage.md` | Complete workflow walkthrough | Reference |

## Usage

Agents should copy templates when creating new memory system files. Do not modify templates directly.

## File Locations

**Memory files** (in `${aiDir}/memory/{type}/`):
- `${aiDir}/memory/index.md` — Layer 1 global index (always loaded)
- `${aiDir}/memory/procedural/` — Procedural memories (patterns, anti-patterns)
- `${aiDir}/memory/semantic/` — Semantic memories (codebase facts)
- `${aiDir}/memory/episodic/` — Episodic memories (events, decisions)

**Session files** (in `${aiDir}/memory/sessions/`):
- `${aiDir}/memory/sessions/active.md` — Current working session
- `${aiDir}/memory/sessions/archive/` — Archived session logs

**Global files** (in `${aiDir}/`):
- `${aiDir}/pre-flight.md` — Global pre-work checklist

## Numbering Convention

Memory IDs use a type prefix and zero-padded 3-digit numbers:
- Procedural: P001, P002, ..., P010, ..., P099, P100 in `${aiDir}/memory/procedural/`
- Semantic: S001, S002, ..., S010, ..., S099, S100 in `${aiDir}/memory/semantic/`
- Episodic: E001, E002, ..., E010, ..., E099, E100 in `${aiDir}/memory/episodic/`
