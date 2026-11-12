---
description: "A feature-implement run stopped inside serial Phase 1, after Task 1 was committed with its Plan-Task line and before Task 2 committed. Both tasks are [~], the bases are logged, and `$STATE/phase-1.times` holds only an implement stamp. Resume must dispatch the Task 2 implementer and never a Task 1 implementer. Without the commit check, resume.md re-executes Task 1 from scratch on top of its own commit (#440)."
tags: [skill:feature-implement, capability]
runs: 1
max_turns: 12
timeout_seconds: 420
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

/myspec:feature-implement Pick the invoice-due-dates implementation back up: the last session stopped partway through. Stay on the current branch, feat/invoice-due-dates, and proceed without asking. Stop once the first subagent you dispatch reports back.
