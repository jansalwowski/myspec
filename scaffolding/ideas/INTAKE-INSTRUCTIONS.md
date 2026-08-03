# Idea Intake Instructions

> Guide for analyzing new ideas and adding them to the priority queue.

**Use this when**: A new idea file is added to `${aiDir}/ideas/` directory.

---

## Workflow

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
> - Existing features: [check `${aiDir}/features/index.yaml` for current features]
> - Pending ideas: [check `${aiDir}/ideas/PRIORITY-LISTING.md` for queued ideas]

#### Scope Questions

If the idea seems large or has multiple components:

> This idea seems to have multiple parts. Should it be:
> 1. **Single idea** - process together as one feature
> 2. **Staged idea** - track as separate entries with different priorities
> 3. **Split ideas** - create separate idea files

#### Clarity Questions

If anything is ambiguous:

> I have some questions about [topic]:
> - [Specific question 1]
> - [Specific question 2]

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
5. Update the processing order if the new idea affects it

### Step 5: Confirm Addition

Report back to user:

> Added **[Idea Name]** to the queue:
> - **Priority**: [LEVEL]
> - **Dependencies**: [list or "None"]
> - **Position in queue**: #[number] of [total]

---

## Question Templates

### For Unclear Priority

```
I've read the new idea: **[idea name]**

Before adding it to the queue, I need to determine its priority.

Based on my analysis:
- It relates to: [related features]
- Complexity appears: [low/medium/high]
- Dependencies: [identified dependencies]

What priority should this have?
1. HIGHEST - Core functionality, blocks other features
2. HIGH - Important, should be done soon
3. MEDIUM - Nice to have
4. LOW - Future consideration
5. LOWEST - Long-term vision
```

### For Large Ideas

```
This idea appears to cover multiple concerns:

1. [Component A] - [brief description]
2. [Component B] - [brief description]
3. [Component C] - [brief description]

How should we handle this?
1. **Single feature** - Implement all together
2. **Staged** - Same file, different priorities
3. **Split** - Create separate idea files for each
```

### For Missing Context

```
I have questions about **[idea name]** before adding to queue:

**Scope:**
- [Question about boundaries]

**Users:**
- [Question about who uses this]

**Integration:**
- [Question about how it connects to existing features]
```

---

## Examples

### Example 1: Clear Idea with Priority

**Input file** `new-feature.md`:
```
priority [high]
Description of the feature...
```

**Action**:
- Read and confirm understanding
- Ask about dependencies
- Add to HIGH section in PRIORITY-LISTING.md

### Example 2: Idea Without Priority

**Input file** `vague-idea.md`:
```
We should add some way to do X...
```

**Action**:
- Read and summarize understanding
- Ask for priority level
- Ask clarifying questions about scope
- After answers: add priority to file, add to PRIORITY-LISTING.md

### Example 3: Large Multi-Part Idea

**Input file** `big-feature.md`:
```
priority [medium]
This feature should do A, B, and C...
Part 1: ...
Part 2: ...
```

**Action**:
- Identify the parts
- Ask if it should be staged or split
- If staged: add multiple entries with different priorities
- If split: create separate files, add each to queue

---

## Checklist Before Completing Intake

- [ ] Idea file has priority tag
- [ ] Priority level confirmed with user (if was missing)
- [ ] Dependencies identified
- [ ] Added to correct section in PRIORITY-LISTING.md
- [ ] Dependency graph updated (if needed)
- [ ] Processing order updated (if needed)
- [ ] Confirmed addition to user

---

## Quick Reference: Priority Levels

| Level | Use When |
|-------|----------|
| HIGHEST | Core feature, MVP requirement, blocks other work |
| HIGH | Important feature, clear value, do soon |
| MEDIUM | Good to have, can wait, no urgency |
| LOW | Future consideration, nice but not needed |
| LOWEST | Vision/dream feature, may never happen |
