---
description: "The user asks for the spec to be reviewed before they see it. feature-spec must run feature-spec-review with --from-author, whose analysis runs in a reviewer subagent, and spec.md must stay draft: no user said yes to approval, and AskUserQuestion is not granted (#356)."
tags: [skill:feature-spec, skill:feature-spec-review, orchestration, capability]
runs: 1
max_turns: 24
timeout_seconds: 480
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent]
---

New feature, call it invoice-reminders: customers get an email reminder three days before an unpaid invoice is due, and another one on the due date. Write the spec and get it reviewed before you show it to me. Make reasonable assumptions and list them as open questions.
