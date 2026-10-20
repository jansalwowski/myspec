---
description: "Tech-spec with planted flaws and the Agent tool granted. feature-tech-spec-review must fire and run its analysis (Steps 1-6) in a fresh reviewer subagent dispatched with the shared reviewer prompt, then relay the uncovered REQ-004 it found (#356)."
tags: [skill:feature-tech-spec-review, orchestration, capability]
runs: 1
max_turns: 10
timeout_seconds: 360
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Before we plan invoice-export, could you check its tech-spec for problems? Only report them; leave the files alone.
