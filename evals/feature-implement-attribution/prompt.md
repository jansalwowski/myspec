---
description: "Approved 2-task plan, and a CLAUDE.md rule that every commit message ends with the trailer `Refs: BILL-142`. The Task 1 implementer dispatch must carry that trailer, since a subagent never sees CLAUDE.md and its commits would drop it (#191). Graded on the first dispatch only; max_turns stops the run soon after it."
tags: [skill:feature-implement, trigger, capability]
runs: 1
max_turns: 14
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

The implementation plan for invoice-due-dates is approved. Start implementing it here on the current branch, and proceed without asking.
