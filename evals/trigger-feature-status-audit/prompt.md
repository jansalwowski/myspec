---
description: "Checking the whole manifest against the feature folders is feature-status-audit, not feature-verify (one feature) or doctor (setup)."
tags: [skill:feature-status-audit, skill:feature-verify, skill:doctor, trigger, regression]
max_turns: 2
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

Can you check whether index.yaml still matches what's actually in the features folder? I think some statuses are stale and a feature or two may be missing.
