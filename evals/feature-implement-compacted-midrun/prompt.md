---
description: "A feature-implement run continues after a context compaction, mid-phase: both Phase 1 tasks were dispatched in this run, reported DONE and are committed, the plan marks them [~] and holds an Execution Log, and the barrier has run. The controller must go on to the phase review. It must not treat the [~] tasks as a resume: no read of resume.md, no second implementer dispatch (#425 review). The prompt starts the skill by its command, standing in for the body Claude Code re-attaches after a compaction, and then gives the compaction summary; the sandbox denies the suite, so the barrier log and review package are prebuilt."
tags: [skill:feature-implement, capability]
runs: 1
max_turns: 10
timeout_seconds: 360
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Agent, Bash]
---

/myspec:feature-implement This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion.

Summary:
- We are running /myspec:feature-implement on the invoice-due-dates plan, in controller mode, on the branch feat/invoice-due-dates. I chose "Current branch" at Step 0.
- Phase 1 holds Tasks 1 and 2. You dispatched both implementers earlier in this session; both reported DONE and their commits are on the branch. The plan marks both `[~]`, and its Execution Log has the `Base (feature)` and `Base (Phase 1)` entries.
- Phase 1's barrier has run. The suite log is `.claude/state/implement/invoice-due-dates/phase-1-verify.log` and the review package is `.claude/state/implement/invoice-due-dates/phase-1-review.diff`.
- Next step: Phase 1's review.

Continue the run from where it stopped, and proceed without asking. Stop once the phase reviewer reports back.
