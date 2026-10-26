---
description: "A doctor run for one named surface (hooks and harness config) audits it in the main conversation: doctor fires, no Agent dispatch, and the controller itself reads the harness config the surface covers."
tags: [skill:doctor, orchestration, capability]
runs: 1
max_turns: 10
timeout_seconds: 360
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Can you run the myspec health check on just the hooks and harness config part of our setup? Only report what you find; don't change anything.
