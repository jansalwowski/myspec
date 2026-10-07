---
description: "Tech-spec with 2 planted flaws: REQ-004 (drafts never exported) has no step, and the reuse audit ignores the shared CSV writer the conventions mandate. Review must fire, flag both, and block planning. The export derives data with no verification_mode, which must be a Medium finding (#169)."
tags: [skill:feature-tech-spec-review, skill:feature-spec-review, planted-flaw, regression]
max_turns: 14
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

The tech-spec for invoice-export is written. Can you review it before we move on to planning? Just report what you find; don't edit anything.
