---
description: "A failing test in this repo with a stack trace routes to root-cause-debugging, not research, though the user asks to find out why."
tags: [skill:research, skill:root-cause-debugging, near-miss, capability]
runs: 1
max_turns: 3
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

tests/test_due_dates.py started failing after this morning's merge: KeyError: 'tz' at app/invoices/due.py line 6. Find out why it's failing.
