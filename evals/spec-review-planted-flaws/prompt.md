---
description: "Spec with 3 planted defects (untestable AC-2, REQ-002 vs REQ-004 contradiction, no failure/empty state). feature-spec-review must fire, flag all three, and not pass the review."
tags: [skill:feature-spec-review, planted-flaw, regression]
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

Please review the invoice-export spec in .ai/features/invoice-export/ and list every problem you find. Don't change any files.
