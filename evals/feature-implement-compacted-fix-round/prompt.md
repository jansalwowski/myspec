---
description: "A feature-implement run continues after a context compaction, inside Phase 1's fix loop: three fix rounds on the mid tier left the finding open. The controller must run round 4 as the skill says: a fresh implementer, one tier above the one that got stuck, told the rule is fixed everywhere it is stated (#425 review). The prompt starts the skill by its command, standing in for the body Claude Code re-attaches after a compaction, and then gives the compaction summary. Graded on the round-4 fix dispatch only."
tags: [skill:feature-implement, capability]
runs: 1
max_turns: 10
timeout_seconds: 360
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

/myspec:feature-implement This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion.

Summary:
- We are running /myspec:feature-implement on the invoice-due-dates plan, in controller mode, on the branch feat/invoice-due-dates. I chose "Current branch" at Step 0.
- Phase 1 holds Tasks 1 and 2. Both implementers reported DONE and their commits are on the branch; the plan marks both `[~]`.
- Phase 1's reviewer returned ISSUES_FOUND with one finding:

  > **Important** — `is_overdue` treats an invoice as overdue on its due date (`today >= due_date(invoice)`, app/invoices/due_dates.py:15). REQ-003 says an issued invoice is overdue only when today is *after* its due date, and AC-3 says an invoice due 2026-10-01 is not overdue on 2026-10-01.

- Fix rounds 1, 2 and 3 have run. Every fix dispatch so far used `model: sonnet`, this session's mid tier. Each round's re-review came back NOT ADDRESSED, and none of their changes are on the branch, so the code is as the phase left it. The plan's Execution Log has the three `Fix base` entries. No ruling was made on the finding, and no approach was ruled out.
- Next step: fix round 4.

Continue the run from where it stopped, and proceed without asking. Stop once the round-4 fix implementer reports back.
