---
description: "Cleaning up the project's own memory folder (entries pointing at deleted code, duplicates, the index) is memory-optimize, not memory-lookup (searching memories for a past answer)."
tags: [skill:memory-optimize, skill:memory-lookup, trigger, capability]
runs: 1
max_turns: 2
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

The notes in .ai/memory have piled up over the year, and some of them still point at code we deleted in the spring. Go through them, work out which ones are dead weight or repeat each other, and get the index back in line.
