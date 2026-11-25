---
name: "memory-preflight"
description: "Use when code work is about to start and relevant past memories should surface first. Keywords: preflight, memory check. Do NOT use for research-only tasks, doc updates, or answering questions."
allowed-tools: [Read, Grep, Glob, 'Bash(node "${CLAUDE_PLUGIN_ROOT}/lib/memory-anchor.mjs":*)']
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

### 4. Scan Episodic Index

Read `${aiDir}/memory/episodic/index.md`.

Check for recent episodes (< 30 days) related to current feature. Older episodes are `/myspec:memory-optimize`'s to consolidate or expire.

→ If match: read full memory file for context.

### 5. Run Staleness Checks

For any loaded memory with anchors:

- Does the anchored file still hold the pattern? (`node "${CLAUDE_PLUGIN_ROOT}/lib/memory-anchor.mjs" {file} "{pattern}"` exits 0; a missing file exits 1 too)
- If it fails: warn in the reply before applying the memory, and suggest `/myspec:memory-optimize`, which re-anchors or retires it. Do not edit any index: the tables are generated.

### 6. Check for Active Session

List `.claude/state/sessions/*.md` (the primary checkout's, gitignored).

→ If your own session exists (its `## Files touched` lists a path you edited): resume it.
→ If other sessions are > 6h stale: note them and suggest `/myspec:session-clean` — do not archive them yourself. 1–6h is ambiguous (a sibling agent may still be working): report only.
→ If none exist: proceed (one is auto-created on first code edit).

### 7. Ready to Start Work

After completing all steps, proceed with implementation.

## Verification Checklist

- [ ] Layer 1 index loaded (can name 1 relevant entry)
- [ ] All 3 type indexes scanned
- [ ] Staleness checks run on anchored memories; failures warned in the reply, no index edited
- [ ] No active session conflict

## When NOT to Use

- Research-only tasks (reading code, answering questions)
- Documentation updates in `${aiDir}/` or `docs/`
- Responding to user questions without code changes
- Single-file trivial fixes (typos, config, formatting) — read `${aiDir}/memory/index.md` directly instead
