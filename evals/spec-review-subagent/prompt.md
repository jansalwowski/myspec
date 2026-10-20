---
description: "Draft spec with planted defects and the Agent tool granted. feature-spec-review must fire and run its analysis (Steps 1-6) in a fresh reviewer subagent dispatched with the shared reviewer prompt, then relay the REQ-002/REQ-004 contradiction it found (#356)."
tags: [skill:feature-spec-review, orchestration, capability]
runs: 1
max_turns: 10
timeout_seconds: 360
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Can you go over the invoice-export requirements in .ai/features/invoice-export/ and tell me what's wrong with them? Just report back, don't change any files.
