---
description: "Phase 1 of an approved 2-task plan is implemented and committed; both tasks are [~] in the plan, uncommitted, as the controller leaves them; the barrier log and review package are prebuilt, since the sandbox denies the suite. feature-implement must fire and dispatch the phase reviewer with the template's note that plan checkboxes are controller-managed, so the reviewer does not report the uncommitted [~] as a defect (#167). Graded on the reviewer dispatch only."
tags: [skill:feature-implement, capability]
runs: 1
max_turns: 10
timeout_seconds: 360
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

We're mid-way through implementing the invoice-due-dates plan on this branch. Tasks 1 and 2 (Phase 1) both reported DONE and are committed; the [~] marks in the plan are from this run. Phase 1's barrier has run too: the phase started at `HEAD~2`, the suite log is `.claude/state/implement/invoice-due-dates/phase-1-verify.log`, and the review package is `.claude/state/implement/invoice-due-dates/phase-1-review.diff`. Continue the feature-implement run with Phase 1's review, and proceed without asking. Stop once the phase reviewer reports back.
