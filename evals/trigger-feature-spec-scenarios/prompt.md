---
description: "Asking for Gherkin test scenarios on an existing, approved spec must route to feature-spec (its scenarios argument; feature-scenario is gone in 3.0), not feature-tech-spec, feature-spec-review or feature-plan, and write scenarios.md beside the spec."
tags: [skill:feature-spec, skill:feature-tech-spec, skill:feature-spec-review, skill:feature-plan, trigger, capability]
runs: 1
max_turns: 12
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit]
---

The invoice-due-dates spec is approved. Write the test scenarios for it in Gherkin — happy path, edge cases and error states — as scenarios.md next to the spec. Don't ask me anything and don't touch the spec itself; I'll review afterwards.
