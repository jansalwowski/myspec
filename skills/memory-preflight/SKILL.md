---
name: "memory-preflight"
description: "Use when starting implementation work, before writing code, to surface relevant past memories. Keywords: preflight, memory check, pre-work scan, load memory, memory pre-flight. Do NOT use for research-only tasks, documentation updates, or answering questions."
allowed-tools: [Read, Grep, Glob, Bash]
---

# Memory Preflight

## Workflow

### 1. Load Layer 1

Read `${aiDir}/memory/index.md` (always-loaded global index).

→ **Verify**: At least 1 relevant critical entry identified.

### 2. Scan Procedural Index

Read `${aiDir}/memory/procedural/index.md`.

Scan the Hook column for keyword matches against the current task. The index shape is `| ID | Hook | Anchor |` everywhere (episodic: `Date`).

→ If match: read the full memory file (the link in the ID cell) and check its `not_for:` before applying
→ Focus on "Procedure (Do This)" section.

### 3. Scan Semantic Index

Read `${aiDir}/memory/semantic/index.md`.

Match the Hook column against the current task domain/feature.
The Anchor column names the file that proves the fact.

→ If match: read full memory file at `${aiDir}/memory/semantic/{id}-{slug}.md`
→ If ⚠️ stale: verify anchor before relying on the fact.

### 4. Scan Episodic Index

Read `${aiDir}/memory/episodic/index.md`.

Check for recent episodes (< 30 days) related to current feature.

→ If match: read full memory file for context.

### 5. Check Episodic Consolidation

For each episodic entry where `persistent: false` and date is > 30 days old:

1. Check if the episode has already produced procedural or semantic memories (check its `related` field for P/S references)
2. If not yet consolidated: Flag to user: "Episode {id} ({title}) is > 30 days old. Consolidate into semantic fact, mark persistent, or archive?"
3. If already consolidated: The episode can be removed from the index (the knowledge lives in the related procedural/semantic memories)

### 6. Run Staleness Checks

For any loaded memory with anchors:

- Does the anchored file exist? (`ls {file}`)
- Does the anchored pattern exist? (`grep -l "{pattern}" {file}`)
- If either fails: flag memory as ⚠️ stale in its type index. Warn before applying.

### 7. Check for Active Session

List `.claude/state/sessions/*.md` (the primary checkout's, gitignored).

→ If your own session exists (its `## Files touched` lists a path you edited): resume it.
→ If other sessions are > 6h stale: note them and suggest `/myspec:session-clean` — do not archive them yourself. 1–6h is ambiguous (a sibling agent may still be working): report only.
→ If none exist: proceed (one is auto-created on first code edit).

### 8. Ready to Start Work

After completing all steps, proceed with implementation.

## Verification Checklist

- [ ] Layer 1 index loaded (can name 1 relevant entry)
- [ ] All 3 type indexes scanned
- [ ] Episodic consolidation checked (episodes > 30 days reviewed)
- [ ] Staleness checks run on anchored memories
- [ ] No active session conflict

## When NOT to Use

- Research-only tasks (reading code, answering questions)
- Documentation updates in `${aiDir}/` or `docs/`
- Responding to user questions without code changes
- Single-file trivial fixes (typos, config, formatting) — read `${aiDir}/memory/index.md` directly instead
