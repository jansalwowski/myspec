---
description: "Use before ANY implementation work. Scans all memory types (procedural, semantic, episodic), runs anchor staleness checks, loads Layer 1 + matched Layer 2 entries. Do NOT use for research-only tasks, documentation updates, or answering questions."
---

# Memory Preflight

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Procedure

### 1. Load Layer 1

Read `${aiDir}/memory/index.md` (always-loaded global index).

> **Verify**: You can name at least 1 relevant critical entry.

### 2. Scan Procedural Index

Read `${aiDir}/memory/procedural/index.md`.

Scan "Use When" column for keyword matches against current task.
Check "Not For" column to confirm applicability.

> If match: read full memory file at `${aiDir}/memory/procedural/{id}-{slug}.md`
> Focus on "Procedure (Do This)" section.

### 3. Scan Semantic Index

Read `${aiDir}/memory/semantic/index.md`.

Match "Topic" column against current task domain/feature.
Check "Anchor" column for ⚠️ stale flags.

> If match: read full memory file at `${aiDir}/memory/semantic/{id}-{slug}.md`
> If ⚠️ stale: verify anchor before relying on the fact.

### 4. Scan Episodic Index

Read `${aiDir}/memory/episodic/index.md`.

Check for recent episodes (< 30 days) related to current feature.

> If match: read full memory file for context.

### 5. Check Episodic Consolidation

For each episodic entry where `persistent: false` and date is > 30 days old:

1. Check if the episode has already produced procedural or semantic memories (check `related` field or Outcome column for P/S references)
2. If not yet consolidated: Flag to user: "Episode {id} ({title}) is > 30 days old. Consolidate into semantic fact, mark persistent, or archive?"
3. If already consolidated: The episode can be removed from the index (the knowledge lives in the related procedural/semantic memories)

### 6. Run Staleness Checks

For any loaded memory with anchors:

- Does the anchored file exist? (`ls {file}`)
- Does the anchored pattern exist? (`grep -l "{pattern}" {file}`)
- If either fails: flag memory as ⚠️ stale in its type index. Warn before applying.

### 7. Check for Active Session

Check if `${aiDir}/memory/sessions/active.md` exists.

> If exists and status=active: Resume, archive (if >24h old), or ask user.
> If not exists: proceed.

### 8. Ready to Start Work

After completing all steps, you're ready to begin implementation.

## Verification Checkpoints

- [ ] Layer 1 index loaded (can name 1 relevant entry)
- [ ] All 3 type indexes scanned
- [ ] Episodic consolidation checked (episodes > 30 days reviewed)
- [ ] Staleness checks run on anchored memories
- [ ] No active session conflict

## When NOT to Use

- Research-only tasks (reading code, answering questions)
- Documentation updates
- Responding to user questions without code changes
- Single-file trivial fixes (typos, config, formatting) — read `${aiDir}/memory/index.md` directly instead
