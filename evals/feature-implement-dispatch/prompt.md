---
description: "Approved 2-task plan for invoice-due-dates on a clean feature branch. feature-implement must fire and hand Task 1 to an implementer subagent (Agent) rather than write app/ or tests/ files in the controller (the 9ed2ed9 failure). Graded on the start of the run only; max_turns stops it soon after the first dispatch. Bash is limited to run.sh's read-only git grant, so the implementer cannot run pytest or commit; the order grader also fails when the implementer writes no file."
tags: [skill:feature-implement, skill:feature-plan, trigger, capability]
max_turns: 14
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

The implementation plan for invoice-due-dates is approved. Start implementing it here on the current branch, and proceed without asking.
