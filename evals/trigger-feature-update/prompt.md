---
description: "New requirements for a feature that already shipped go to feature-update, which edits its spec.md and tech-spec.md in place, not feature-spec (a new feature) or feature-tech-spec (a first design)."
tags: [skill:feature-update, skill:feature-spec, skill:feature-tech-spec, trigger, capability]
runs: 1
max_turns: 2
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

The invoice CSV export went live last month. Accounting now wants a VAT amount column in the file and a way to export one customer's invoices only. Work that into its requirements and technical design.
