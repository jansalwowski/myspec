---
description: "Grooming Claude Code's own per-project auto-memory (under ~/.claude/projects, the default config dir): memory-sanitize, not memory-optimize."
tags: [skill:memory-sanitize, skill:memory-optimize, trigger, capability]
max_turns: 6
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

My Claude Code auto-memory for this project, the MEMORY.md under ~/.claude/projects/, has grown to about forty entries. Lots of them are stale or duplicate each other, and some bodies are way too long. Can you clean it up?
