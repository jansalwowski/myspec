---
description: "Use to create a new memory from a completed session or direct capture. Supports three types: procedural, semantic, episodic. Creates memory file and updates type-specific index. Do NOT use without user approval, for trivial insights (typos, obvious config), or if first approach worked without surprises."
---

# Memory Create

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Prerequisites

- Completed session log with `status: completed`, OR direct capture with user approval.

## Design Principles

### 1. Progressive Disclosure
- **Type-specific index**: ~100 tokens per type, keywords only
- **Full memory file**: Loads on match with complete detail

### 2. No Description Leakage
- Index shows keywords/topics only, never solutions
- Agents must load the full memory file to get procedures/facts/narratives

### 3. Type-Appropriate Format
- **Procedural**: Steps (do this, verify that)
- **Semantic**: Facts (what is true, source, implication)
- **Episodic**: Narrative (context, decision, outcome, consequence)

### 4. Anchor Everything
- Code-specific memories get file + pattern anchors for staleness detection

## Procedure

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

Use the type-appropriate template from `${aiDir}/templates/memory-{type}.md`:

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
- Set `topic`: domain keyword (e.g., auth, caching, deployment)
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

## When NOT to Use

- Session didn't reveal non-obvious insights
- Problem was a simple typo or configuration
- User declined memory creation
