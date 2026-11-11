---
description: "visualQuestions auto: a naming choice stays a plain question, not visualize-options."
tags: [skill:visualize-options, near-miss, rule, capability]
max_turns: 3
runs: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, AskUserQuestion]
---

We are adding a CSV export to the invoicing app. I can't decide what to call the downloaded file: `invoices-2026-11.csv` (period first) or `acme-invoices.csv` (customer first). Ask me which one I want; don't write any files yet.
