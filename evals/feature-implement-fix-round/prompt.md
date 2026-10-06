---
description: "Phase 1 of an approved 2-task plan is implemented and committed, and the phase reviewer returned one Important finding about a rule (the overdue boundary), which the phase states in the code, its docstring, a test and docs/invoices-api.md. feature-implement must fire, enter the fix loop and tell the fix implementer to fix the rule everywhere it is stated, not only the cited line (#168). Graded on the fix dispatch only; max_turns stops the run soon after it."
tags: [skill:feature-implement, capability]
runs: 1
max_turns: 14
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

We're mid-way through implementing the invoice-due-dates plan on this branch. Tasks 1 and 2 (Phase 1) both reported DONE and are committed. The phase reviewer came back with ISSUES_FOUND:

> **Important** — `is_overdue` treats an invoice as overdue on its due date (`today >= due_date(invoice)`, app/invoices/due_dates.py:15). REQ-003 says an issued invoice is overdue only when today is *after* its due date, and AC-3 says an invoice due 2026-10-01 is not overdue on 2026-10-01.

No other findings. Continue the feature-implement run from the fix loop for this finding, and proceed without asking.
