---
description: "Use when debugging, encountering errors, or researching past decisions. Searches across all memory types (procedural, semantic, episodic) in ${aiDir}/memory/. Do NOT use for first-time implementation with no prior context, research without a specific problem, or features with no existing memories."
---

# Memory Lookup

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## When to Use

Invoke this skill when:
- You're debugging a problem
- You've encountered an error or unexpected behavior
- You're about to repeat an approach that might have been tried before
- You've made 2+ attempts without success
- You're researching why a past decision was made

## Procedure

### 1. Identify Search Context

Determine what you're looking for:
- Error messages or symptoms → search procedural (Use When column)
- Facts about a system/API → search semantic (Topic column)
- Past decisions or events → search episodic (Event column)
- Unsure → search all three

### 2. Scan Procedural Index

Read `${aiDir}/memory/procedural/index.md`:
- Match "Use When" column against: error message keywords, component/API names, symptoms
- Check "Not For" column to confirm applicability
- Memories with `validation_count >= 3` are proven patterns — prioritize these

### 3. Scan Semantic Index

Read `${aiDir}/memory/semantic/index.md`:
- Match "Topic" column against current domain
- Check for ⚠️ stale flags — verify anchor before trusting

### 4. Scan Episodic Index

Read `${aiDir}/memory/episodic/index.md`:
- Check for events related to current feature/component
- Recent episodes (< 30 days) may have relevant context

### 5. Load Matched Memories

Read full memory files for matches:
- Procedural: focus on "Procedure (Do This)" section
- Semantic: note facts and implications
- Episodic: note consequences and lasting decisions

### 6. Apply and Verify

Follow procedures exactly as written. Check semantic facts still hold (verify anchors). Consider episodic consequences.

### 7. Update Tracking

On successful application:
- Procedural: increment `validation_count`, update `validated` date
- Semantic: update `verified` date if fact confirmed still true

If the memory didn't help or was inaccurate:
1. Flag for user review: "Memory {id} may be stale - it didn't apply to this situation"
2. Don't update validation tracking

### 8. Log in Session

If a session is active, log which memory was used, whether it helped, and the result.

## Memory Effectiveness

Memories with `validation_count >= 3` are proven patterns. Prioritize these when multiple memories match.

If a memory has `validation_count = 0` and seems outdated, ask user before applying.

## When NOT to Use

- First-time implementation (no debugging yet)
- Research tasks (reading code, understanding architecture)
- Working on features without memory files
- Problem is obviously different from existing memories
