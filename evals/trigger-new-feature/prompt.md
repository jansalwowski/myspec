---
description: "Natural \"new feature\" phrasing must route to feature-spec (not feature-tech-spec) and produce spec.md under the aiDir. \"Without asking me questions; I'll review afterwards\" answers the auto-review question No, so feature-spec-review must not run (#356)."
tags: [skill:feature-spec, skill:feature-tech-spec, skill:feature-spec-review, trigger, regression]
max_turns: 12
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit]
---

I want to start a new feature: users can export their invoices as CSV. Help me write the requirements. Scope: a user picks a date range and gets one CSV with invoice number, issue date, customer name, net amount, currency and status. Draft it now without asking me questions; I'll review afterwards.
