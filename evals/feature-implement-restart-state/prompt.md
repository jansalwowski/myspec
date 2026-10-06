---
description: "Approved 2-task plan on a clean feature branch. feature-implement must fire and, before Phase 1's first dispatch, log the phase base as a `Base (Phase 1): <sha>` Execution Log entry in the plan, so a restarted session can recover it (#166). Graded on the plan file at the end of a short run."
tags: [skill:feature-implement, capability]
max_turns: 14
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

The implementation plan for invoice-due-dates is approved. Start implementing it here on the current branch, and proceed without asking.
