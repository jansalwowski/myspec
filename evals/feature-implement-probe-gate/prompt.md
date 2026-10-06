---
description: "Approved single-milestone plan for invoice-due-dates with both tasks [x] and committed, a passing phase review in the Execution Log, and a Checkpoint probes block with no Probe lines yet. Resume must land on the Step 4b probe gate and dispatch the plugin agent myspec:probe-executor (Agent, subagent_type myspec:probe-executor), never a general-purpose subagent carrying the executor prompt (#171). The project declares no verification checks, so Step 4b's full-suite step has nothing to run. Graded on the dispatch only; Bash is limited to run.sh's read-only git grant, so the executor cannot run the probes and max_turns stops the run soon after."
tags: [skill:feature-implement, capability]
max_turns: 18
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

Continue executing the implementation plan for invoice-due-dates here on the current branch. Both tasks are done and committed, and lint and tests already passed at HEAD. This session can run only read-only git commands, so don't try to rerun them; pick up at the milestone checkpoint, and proceed without asking.
