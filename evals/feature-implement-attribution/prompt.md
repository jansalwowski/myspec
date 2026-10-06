---
description: "Approved 2-task plan, and a CLAUDE.md rule that every commit message ends with the trailer `Refs: BILL-142`. The Task 1 implementer dispatch must carry that trailer, since a subagent never sees CLAUDE.md and its commits would drop it (#191). Graded on the first dispatch only; the prompt stops the run once Task 1's implementer reports back, and max_turns backs that up."
tags: [skill:feature-implement, trigger, capability]
runs: 1
max_turns: 10
timeout_seconds: 360
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

The implementation plan for invoice-due-dates is approved. Start implementing it here on the current branch, and proceed without asking. Do Task 1 only for now, and stop once its implementer reports back.
