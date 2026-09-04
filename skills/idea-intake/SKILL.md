---
name: "idea-intake"
description: "Use when a new idea file lands in ${aiDir}/ideas/ and needs triaging into the priority queue — analysis, priority, dependencies, PRIORITY-LISTING.md. Keywords: new idea, idea queue, idea triage, queue idea. Do NOT use to convert an idea to a spec (idea-process)."
tags: [ideas, planning, intake, queue]
---

# Idea Intake

Process a new idea file and add it to the priority queue.

## Prerequisites

- New idea file exists in `${aiDir}/ideas/` directory
- Read `${aiDir}/ideas/PRIORITY-LISTING.md` for current queue state

## Workflow

### 1. Read the New Idea

Read the idea file completely. Note:
- What problem does it solve?
- What features does it relate to?
- Is the priority specified? (look for `priority [level]` or `[level]`)
- Are there obvious dependencies?

### 2. Analyze and Ask Questions

**Always ask clarifying questions before adding to queue.**

#### Priority Questions

If priority is not specified or unclear:

> What priority should this idea have?
> - **HIGHEST**: Core functionality, blocks other features
> - **HIGH**: Important feature, should be done soon
> - **MEDIUM**: Nice to have, no urgency
> - **LOW**: Future consideration
> - **LOWEST**: Long-term vision, may never happen

#### Dependency Questions

> Does this idea depend on any existing features or ideas?

#### Scope Questions

If the idea seems large:

> This idea has multiple parts. Should it be:
> 1. **Single idea** - process together as one feature
> 2. **Staged idea** - track as separate entries with different priorities
> 3. **Split ideas** - create separate idea files

### 3. Validate Idea File Format

Ensure the idea file has:
- Priority tag: `priority [level]` or `[level]` at the start
- Clear description of what's needed
- Any relevant context or examples

If missing priority, ask user to confirm and update the file.

### 4. Add to PRIORITY-LISTING.md

After questions are answered:

1. Open `${aiDir}/ideas/PRIORITY-LISTING.md`
2. Find the correct priority section
3. If the priority section doesn't exist, create it following the existing format
4. Check whether an existing entry covers the same idea — if so, warn user and ask whether to merge or keep separate
5. Add a new row to the table:

```markdown
| [ ] | Idea Name | `filename.md` | Dependencies | Brief notes |
```

6. Update the dependency graph if needed
7. Update Quick Stats count

### 5. Confirm Addition

Report back to user:

> Added **[Idea Name]** to the queue:
> - **Priority**: [LEVEL]
> - **Dependencies**: [list or "None"]
> - **Position in queue**: #[number] of [total]

## Rules

- **Always ask before adding**: Never add an idea to the queue without user confirmation on priority
- **One idea per file**: If an idea contains multiple features, ask user about splitting (Step 2 scope questions)
- **Preserve existing queue order**: Only insert into the correct priority section, never reorder existing entries
- **Dependencies must be explicit**: If a dependency is unclear, ask — never assume "None"

## Verification Checklist

- [ ] Idea file has priority tag
- [ ] Priority level confirmed with user (if was missing)
- [ ] Dependencies identified (asked if unclear)
- [ ] No duplicate entry added without user decision
- [ ] Added to correct section in PRIORITY-LISTING.md (created section if missing)
- [ ] Quick Stats updated
- [ ] Confirmed addition to user
