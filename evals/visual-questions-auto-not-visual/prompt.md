---
description: "visualQuestions auto: a choice between options words decide (sync vs background job) stays a plain question, not visualize-options."
tags: [skill:visualize-options, near-miss, rule, capability]
max_turns: 3
runs: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, AskUserQuestion]
---

The invoice CSV export is getting slow for big accounts. I can't decide whether to keep it synchronous in the request with a row limit, or move it to a background job that emails a download link. Ask me which one I want; don't write any files yet.
