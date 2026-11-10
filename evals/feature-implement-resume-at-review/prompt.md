---
description: "A feature-implement run stopped during Phase 1's review and is resumed in a new session. Both Phase 1 tasks are committed and still [~], the Execution Log holds the bases, and `$STATE/phase-1.times` has implement, barrier and review stamps. Resume must continue at the phase review: it dispatches the phase reviewer and no Task 1 or Task 2 implementer. Without the stage check, resume.md re-executes every [~] task from scratch on top of its own commits."
tags: [skill:feature-implement, capability]
runs: 1
max_turns: 12
timeout_seconds: 420
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

/myspec:feature-implement Pick the invoice-due-dates implementation back up: the last session stopped partway through. Stay on the current branch, feat/invoice-due-dates, and proceed without asking. Stop once the first subagent you dispatch reports back.
