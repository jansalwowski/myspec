---
description: "feature-spec must write spec.md with every section and frontmatter key feature-spec-review checks for (Overview, Requirements, User Stories, Acceptance Criteria, Out of Scope; spec_version, status, priority), plus dependencies.md and a manifest entry."
tags: [skill:feature-spec, skill:feature-spec-review, artifact-contract, regression]
max_turns: 14
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit]
---

New feature, call it invoice-reminders: customers get an email reminder three days before an unpaid invoice is due, and another one on the due date. Please write the spec for it now. Don't ask me anything; make reasonable assumptions and list them as open questions.
