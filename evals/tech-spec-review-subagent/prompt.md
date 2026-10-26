---
description: "Tech-spec with planted flaws and the Agent tool granted. feature-tech-spec-review must fire and run its analysis (Steps 1-6) in a fresh reviewer subagent dispatched with the shared reviewer prompt, then relay the uncovered REQ-004 it found (#356). The subagent arm of fold-pair tech-spec-review: same prompt and outcome graders as tech-spec-review-planted-flaws, which runs inline."
tags: [skill:feature-tech-spec-review, skill:feature-spec-review, orchestration, fold-pair:tech-spec-review, fold-arm:subagent, capability]
runs: 1
max_turns: 14
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

The tech-spec for invoice-export is written. Can you review it before we move on to planning? Just report what you find; don't edit anything.
