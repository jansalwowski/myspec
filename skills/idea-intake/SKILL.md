---
description: "Use when a new idea file is added to the ideas directory. Analyzes idea, asks clarifying questions, adds to PRIORITY-LISTING.md. Do NOT use for converting ideas to features."
tags: [ideas, planning, intake, queue]
---

# Idea Intake

Process a new idea file and add it to the priority queue.

## Path Resolution
1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Prerequisites

- New idea file exists in `${aiDir}/ideas/` directory
- Read `${aiDir}/ideas/PRIORITY-LISTING.md` for current queue state

## Instructions

### Step 1: Read the New Idea

Read the idea file completely. Note:
- What problem does it solve?
- What features does it relate to?
- Is the priority specified? (look for `priority [level]` or `[level]`)
- Are there obvious dependencies?

### Step 2: Analyze and Ask Questions

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

### Step 3: Validate Idea File Format

Ensure the idea file has:
- Priority tag: `priority [level]` or `[level]` at the start
- Clear description of what's needed
- Any relevant context or examples

If missing priority, ask user to confirm and update the file.

### Step 4: Add to PRIORITY-LISTING.md

After questions are answered:

1. Open `${aiDir}/ideas/PRIORITY-LISTING.md`
2. Find the correct priority section
3. Add a new row to the table:

```markdown
| [ ] | Idea Name | `filename.md` | Dependencies | Brief notes |
```

4. Update the dependency graph if needed
5. Update Quick Stats count

### Step 5: Confirm Addition

Report back to user:

> Added **[Idea Name]** to the queue:
> - **Priority**: [LEVEL]
> - **Dependencies**: [list or "None"]
> - **Position in queue**: #[number] of [total]

## Checklist

- [ ] Idea file has priority tag
- [ ] Priority level confirmed with user (if was missing)
- [ ] Dependencies identified
- [ ] Added to correct section in PRIORITY-LISTING.md
- [ ] Quick Stats updated
- [ ] Confirmed addition to user

## Quick Reference: Priority Levels

| Level | Use When |
|-------|----------|
| HIGHEST | Core feature, MVP requirement, blocks other work |
| HIGH | Important feature, clear value, do soon |
| MEDIUM | Good to have, can wait, no urgency |
| LOW | Future consideration, nice but not needed |
| LOWEST | Vision/dream feature, may never happen |
