# Blueprint: INDEX.md

## Purpose
Guide the user through creating a documentation index that maps all AI documentation files for quick navigation.

## Discovery Questions (ask one at a time)

1. "What documentation categories exist or should exist? Common ones include: features, plans, conventions, decisions. Any others?"

2. "What is the project's domain? (This helps label sections meaningfully, e.g., 'E-commerce Features' vs just 'Features')"

3. "Are there key architectural areas that need their own documentation? (e.g., database, authentication, caching, deployment, integrations)"

4. "Any other documentation sections you want indexed?" (or "skip" to finish)

## Output Format

Generate `${aiDir}/INDEX.md` with this structure:

```markdown
# Documentation Index

> Complete map of all AI documentation for this project.

## How to Use

- **Starting work**: Read `anti-patterns.md` then `pre-flight.md`
- **New feature**: Check `features/index.yaml` then `workflow.md`
- **Architecture question**: Browse `plans/` section below

## Core Documents

| Document | Purpose | Read When |
|----------|---------|-----------|
| `anti-patterns.md` | Common mistakes to avoid | Before any work |
| `pre-flight.md` | Verification checklist | Before and after implementation |
| `workflow.md` | Development workflow and policies | Starting any feature |

## Features

| Document | Purpose |
|----------|---------|
| `features/index.yaml` | Feature manifest — single source of truth for status |
| `features/{name}/spec.md` | Product specification (what and why) |
| `features/{name}/tech-spec.md` | Technical specification (how) |
| `features/{name}/dependencies.md` | Cross-feature dependency map |
| `features/{name}/scenarios.md` | Test scenarios in Gherkin format |

## Conventions

| Document | Purpose |
|----------|---------|
| `conventions/coding-standards.md` | Naming, file organization, style rules |
| `conventions/testing.md` | Test framework, patterns, coverage |
| `conventions/error-handling.md` | Error classes, handling patterns |

## Plans

| Document | Purpose |
|----------|---------|
{architectural docs based on user input}

## Decisions

| Document | Purpose |
|----------|---------|
| `decisions/{YYYY-MM-DD}-{topic}.md` | Architecture decision records |

## Ideas

| Document | Purpose |
|----------|---------|
| `../ideas/PRIORITY-LISTING.md` | Prioritized idea queue |
| `../ideas/INTAKE-INSTRUCTIONS.md` | How to add new ideas |
| `../ideas/PROCESSING-INSTRUCTIONS.md` | How to convert ideas to features |
```

## Output Location
Write to `${aiDir}/INDEX.md`.
