---
name: "memory-create"
description: "Use when creating a new memory entry from a completed session, direct capture, or user-approved insight. Handles procedural (how-to), semantic (facts), and episodic (events) memory types. Triggers: save memory, record insight, capture learning, log finding. Do NOT use without user approval, for trivial insights (typos, obvious config), or if first approach worked without surprises."
---

# Memory Create

## Prerequisites

- Completed session log with `status: completed`, OR direct capture with user approval.

## Constraints

- Index entries contain keywords/topics ONLY — never solutions or procedures
- Memory files use type-appropriate format:
  - **Procedural**: Steps (do this, verify that)
  - **Semantic**: Facts (what is true, source, implication)
  - **Episodic**: Narrative (context, decision, outcome, consequence)
- Code-specific memories MUST include file + grep pattern anchors for staleness detection
- Always set `related` field to cross-reference other memory types

## Workflow

### 1. Determine Memory Type

Based on caller input or session analysis:

- **Procedural**: A reusable pattern for how to do (or not do) something
- **Semantic**: A fact about the codebase, API, dependency, or environment
- **Episodic**: A significant event, decision, or outcome worth recording

### 2. Find Next ID

Read `${aiDir}/memory/{type}/index.md`:
- Find highest existing ID number
- Increment by 1 (e.g., P008 -> P009, S001, E001)

### 3. Draft Memory File

Use the type-appropriate template from `${aiDir}/.templates/memory-{type}.md`:

**If procedural:**
- Extract: problem, failed approaches, successful approach, root cause
- Structure as: Procedure (Do This) -> Why -> What Fails -> Verification
- Set `polarity`: positive (pattern to follow) or negative (anti-pattern)
- Set `triggers`: keywords from the problem space (error messages, component names, symptoms)
- Set `not_for`: 2-3 specific exclusions
- Set `anchors`: file + grep pattern if code-specific
- Set `related`: IDs of related semantic/episodic memories (e.g., ["S001", "E003"])

**If semantic:**
- Extract: the factual statement, source, implication
- Keep concise -- 1-3 sentences for the fact
- Set `topic`: domain keyword (e.g., google-maps, prisma, auth)
- Set `anchor`: file + pattern to check staleness
- Set `related`: IDs of related procedural/episodic memories (e.g., ["P009", "E001"])

**If episodic:**
- Extract: context, decision, outcome, consequence
- Set `outcome`: success | failure | partial | abandoned
- Set `persistent: true` only if this has indefinite relevance
- Default `persistent: false` -- will auto-archive after 30 days
- Set `related`: IDs of related procedural/semantic memories (e.g., ["P009", "S001"])

### 4. Update Type-Specific Index

Add a row to `${aiDir}/memory/{type}/index.md`:

**Procedural row**: `| {id} | {keywords} | {capability} | {exclusions} |`
**Semantic row**: `| {id} | {topic} | {one-line fact} | {verified date} | {anchor file or "---"} |`
**Episodic row**: `| {id} | {date} | {event summary} | {feature} | {outcome} |`

**CRITICAL**: Index shows keywords/topics/summaries ONLY, never solutions or procedures.
Set `updated` date in index frontmatter.

### 5. Present to User for Refinement

Show the drafted memory. Ask:
"Does this capture the key insight? Any adjustments?"

### 6. Write Final Files

Save memory file and updated index.
Update `validated`/`verified` date in memory frontmatter.

### 7. Consider Layer 1 Promotion

If the memory is critical enough to always be in context:
- Ask user: "Should this be promoted to the global index (${aiDir}/memory/index.md)?"
- If yes: add a one-line summary to the appropriate section.

## Verification Checklist

- [ ] Memory type correctly identified (procedural/semantic/episodic)
- [ ] Memory file uses correct template from `${aiDir}/.templates/memory-{type}.md`
- [ ] ID incremented correctly from highest existing in type index
- [ ] Index row contains keywords/topics only — no solutions leaked
- [ ] `anchors` field set for code-specific memories
- [ ] `related` field cross-references other memory types
- [ ] User approved the drafted memory before final write
- [ ] `validated`/`verified` date set in frontmatter

## When NOT to Use

- Session didn't reveal non-obvious insights
- Problem was a simple typo or configuration
- User declined memory creation
