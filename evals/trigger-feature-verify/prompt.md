---
description: "One feature's health (docs, plan, code, manifest) is feature-verify, not feature-status-audit (every feature) or doctor (setup)."
tags: [skill:feature-verify, skill:feature-status-audit, skill:doctor, trigger, regression]
max_turns: 6
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

Is the invoice-export feature in good shape? Audit its docs, plan and manifest entry and tell me what has drifted.
