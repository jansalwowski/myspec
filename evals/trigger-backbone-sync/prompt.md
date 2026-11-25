---
description: "Checking backbone.yml against the repository after a refactor is backbone-sync, not feature-spec-sync (feature docs against code)."
tags: [skill:backbone-sync, skill:feature-spec-sync, trigger, capability]
runs: 1
max_turns: 2
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

Last week's refactor moved payments into its own package and added a CLI for the nightly export. Does backbone.yml still describe the repo correctly? Tell me which entries are wrong or missing.
