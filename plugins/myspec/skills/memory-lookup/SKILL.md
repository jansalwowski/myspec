---
name: "memory-lookup"
description: "Use when debugging, encountering errors, or researching past decisions. Searches across all memory types (procedural, semantic, episodic) in ${aiDir}/memory/. Do NOT use for first-time implementation with no prior context, research without a specific problem, or features with no existing memories."
---

# Memory Lookup

## Workflow

### 1. Classify Search Target

Classify the search target:
- Error messages or symptoms → search procedural (Use When column)
- Facts about a system/API → search semantic (Topic column)
- Past decisions or events → search episodic (Event column)
- Unsure → search all three

### 2. Scan Procedural Index

If search context excludes procedural (e.g., pure fact lookup), skip to step 3.

Read `${aiDir}/memory/procedural/index.md`:
- Match "Use When" column against: error message keywords, component/API names, symptoms
- Check "Not For" column to confirm applicability
- Memories with `validation_count >= 3` are proven patterns — prioritize these

### 3. Scan Semantic Index

If search context excludes semantic (e.g., pure debugging), skip to step 4.

Read `${aiDir}/memory/semantic/index.md`:
- Match "Topic" column against current domain
- Check for ⚠️ stale flags — verify anchor before trusting

### 4. Scan Episodic Index

If search context excludes episodic, skip to step 5.

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

## Verification Checklist

- [ ] Search context classified (procedural/semantic/episodic/all)
- [ ] Relevant index files scanned (procedural, semantic, episodic)
- [ ] Matched memories loaded and read in full
- [ ] Procedures followed exactly as written; semantic facts verified against current state
- [ ] Tracking updated: `validation_count` incremented or staleness flagged
- [ ] Session log updated (if session active)

## When NOT to Use

- First-time implementation (no debugging yet)
- Research tasks (reading code, understanding architecture)
- Working on features without memory files
- Problem is obviously different from existing memories
