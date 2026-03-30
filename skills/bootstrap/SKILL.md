---
name: "bootstrap"
description: "Use at the start of any work session to orient Claude. Reads project config, memory index (past decisions and mistakes), and pre-flight checklist. Run this before asking questions or starting implementation. Do NOT use mid-task or multiple times in one session."
---

# Bootstrap

Orients Claude to the project at the start of a session. Single command replacing manual invocation of project config reading, memory index, and pre-flight.

## Procedure

### 1. Read Project Config

Read `.myspec.json` (if it exists) to get:
- `project.name` and `project.techStack`
- `aiDir` (the configured AI documentation directory, default: `ai/`)

Check `.myspec.json` for a `topologyFile` key. If set, read that file.

If `topologyFile` is not set, check for common topology files at project root: `backbone.yml`, `topology.yml`, `project.yml`. If found, read it and note: suggest the user add `"topologyFile": "{filename}"` to `.myspec.json`.

From the topology file, identify:
- Which areas/apps are relevant to the current task
- Key paths for the relevant area
- Any protected or never-modify boundaries from `boundaries.never_modify`
- Available commands (dev, test, lint, etc.) from `commands`

### 2. Read Memory Index

Read `${aiDir}/memory/index.md` (Layer 1 — global index).

Scan for:
- Critical procedural entries (What NOT to Do)
- Must-Know Facts relevant to current task
- Recent Significant Events

### 3. Scan Full Memory Indexes

Read `${aiDir}/memory/procedural/index.md`, `${aiDir}/memory/semantic/index.md`, `${aiDir}/memory/episodic/index.md`.

For each: check "Use When" / "Topic" columns for keyword matches against the current task.

→ If match found: read the full memory file before proceeding.

### 4. Check for Active Session

Check if `${aiDir}/memory/sessions/active.md` exists.

→ If exists and `status: active`: ask user — resume this session or archive it?
→ If not exists: proceed.

### 5. Check for Stale Worktrees

Run `git worktree list` and count non-main worktrees. For each:
- Check last commit date: `git log -1 --format=%ct <sha>` vs current epoch
- Flag as **stale** if last commit >3 days ago
- Flag as **orphaned** if path does not exist on disk

Run `git worktree prune --dry-run` to detect pruneable references.

→ If issues found: include warning in Step 6 summary — "**Worktree health**: WARNING — N stale/orphaned worktrees. Run `/myspec:worktree-cleanup`"
→ If clean: include "**Worktree health**: clean (N active worktrees)"
→ If no worktrees: omit the line entirely.

This step is informational only — do not auto-cleanup.

### 6. Print Orientation Summary

Output a brief structured summary so the user can confirm Claude is properly oriented:

```
## Session Ready

**Project**: {project name from .myspec.json, or inferred from package.json/repo name}
**Stack**: {tech stack from .myspec.json, or "not configured"}
**Relevant area(s)**: [which apps/modules based on task context]
**Key paths**: [2-3 most relevant paths from project structure]
**Memory loaded**: [count] procedural | [count] semantic | [count] episodic entries checked
**Matches**: [list any memory entries that matched current task, or "none"]
**Topology**: [{filename} loaded / not configured — run `/myspec:setup backbone` to create one]
**Active session**: [yes (slug) / no]
**Worktree health**: [clean (N active) / WARNING — N stale/orphaned. Run `/myspec:worktree-cleanup`]
**Boundaries**: [any never_modify paths relevant to task, or "none relevant"]
```

## When NOT to Use

- Mid-task (bootstrap is for session start only)
- Multiple times in one session
- When task is a quick one-off question with no code changes
