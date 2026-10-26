---
description: "Draft spec with planted defects and the Agent tool granted. feature-spec-review must fire and run its analysis (Steps 1-6) in a fresh reviewer subagent dispatched with the shared reviewer prompt, then relay the REQ-002/REQ-004 contradiction it found (#356). The subagent arm of fold-pair spec-review: same prompt and outcome graders as spec-review-planted-flaws, which runs inline."
tags: [skill:feature-spec-review, orchestration, fold-pair:spec-review, fold-arm:subagent, capability]
runs: 1
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Please review the invoice-export spec in .ai/features/invoice-export/ and list every problem you find. Don't change any files.
