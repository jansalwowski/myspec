---
name: "bootstrap"
description: "Use when starting any work session and the agent needs project orientation before answering questions or making changes. Keywords: bootstrap, start session, orient, where am I, what is this project, project context, pre-flight, what's the state. Do NOT use mid-task, multiple times in one session, or for one-off questions with no code involvement."
---

# Bootstrap

## Workflow

### 1. Read Project Config

Read `.myspec.json` (if it exists) to get:
- `project.name` and `project.techStack`
- `aiDir` (the configured AI documentation directory, default: `ai/`)
- `frameworkVersion` (used in step 6 for version comparison; absent in older configs)

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

### 4. Check for Active Sessions

List `${aiDir}/memory/sessions/active/*.md` (excluding `.gitkeep`).

For each file, compare its mtime to the current epoch.

**Auto-archive policy** (>60 minutes stale = orphaned):

```bash
NOW=$(date +%s)
for f in ${aiDir}/memory/sessions/active/*.md; do
  [ -f "$f" ] || continue
  [[ "$f" == *.gitkeep ]] && continue
  MTIME=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
  AGE=$(( NOW - MTIME ))
  if [ "$AGE" -gt 3600 ]; then
    SLUG=$(basename "$f" .md | head -c 8)
    DATE=$(date '+%Y-%m-%d')
    sed -i.bak 's/^status: active/status: abandoned/' "$f" && rm "$f.bak"
    mv "$f" "${aiDir}/memory/sessions/archive/${DATE}-orphaned-${SLUG}.md"
  fi
done
```

After cleanup, count remaining active sessions and report in summary:
- `Active sessions: 0` → no active work
- `Active sessions: N` → list each as `{session_id_first8} — {topic}`
- If sessions were auto-archived: `Auto-archived M orphaned sessions`

Sessions are auto-created by `mark-code-changed.sh` (PostToolUse hook) on first code edit, so manual `/myspec:session-start` is rarely needed for code-editing work.

### 5. Check for Stale Worktrees

Run `git worktree list` and count non-main worktrees. For each:
- Check last commit date: `git log -1 --format=%ct <sha>` vs current epoch
- Flag as **stale** if last commit >3 days ago
- Flag as **orphaned** if path does not exist on disk

Run `git worktree prune --dry-run` to detect pruneable references.

→ If issues found: include warning in Step 6 summary — "**Worktree health**: WARNING — N stale/orphaned worktrees. Use the `worktree-cleanup` skill."
→ If clean: include "**Worktree health**: clean (N active worktrees)"
→ If no worktrees: omit the line entirely.

This step is informational only — do not auto-cleanup.

### 6. Check Framework Version

Compare `frameworkVersion` from `.myspec.json` (read in step 1) against `frameworkVersion` from the plugin's `framework-files/manifest.json`.

Resolve the plugin directory in this order:
1. `$CLAUDE_PLUGIN_ROOT` if set.
2. The directory containing this `SKILL.md`, walking up until a sibling `framework-files/manifest.json` is found (typically `…/myspec/{version}/framework-files/manifest.json`).
3. If neither resolves, treat the manifest as unreadable.

- If equal: omit the version line from the summary.
- If plugin version > project version: include `**myspec version**: plugin v{plugin} ahead of project v{project} — run /myspec:update`.
- If plugin version < project version: include `**myspec version**: plugin v{plugin} behind project v{project} — update your plugin`.
- If either file is unreadable or missing the field: omit the line silently — do not error.

Use semver ordering. If versions are not semver-parseable, fall back to string equality; on inequality, print `**myspec version**: project on v{project}, plugin has v{plugin}` without direction.

This step is informational only — do not auto-run `/myspec:update`.

### 7. Print Orientation Summary

Output a brief structured summary so the user can confirm the agent is properly oriented:

```
## Bootstrap Complete

**Project**: {project name from .myspec.json, or inferred from package.json/repo name}
**Stack**: {tech stack from .myspec.json, or "not configured"}
**Relevant area(s)**: [which apps/modules based on task context]
**Key paths**: [2-3 most relevant paths from project structure]
**Memory loaded**: [count] procedural | [count] semantic | [count] episodic entries checked
**Matches**: [list any memory entries that matched current task, or "none"]
**Topology**: [{filename} loaded / not configured — use the `setup` skill with `backbone` to create one]
**Active sessions**: [N (list of session_id prefixes + topics) / 0]
**Auto-archived**: [M orphaned sessions / 0 (omit line if 0)]
**Worktree health**: [clean (N active) / WARNING — N stale/orphaned. Use the `worktree-cleanup` skill]
**myspec version**: [omit if versions match / plugin v{plugin} ahead of project v{project} — run /myspec:update / plugin v{plugin} behind project v{project} — update your plugin / project on v{project}, plugin has v{plugin} (non-semver)]
**Boundaries**: [any never_modify paths relevant to task, or "none relevant"]
```

**Note**: Bootstrap satisfies the `memory-preflight` prerequisite for `session-start`. Sessions for code-editing work are auto-created by the `mark-code-changed.sh` hook on first code edit — no skill invocation needed. Manual `session-start` is only useful for non-code sessions (pure debugging, discovery, doc-only work). Bootstrap itself does NOT create a session; it only orients the project context and archives orphaned sessions.

## Verification Checklist

- [ ] `.myspec.json` was checked (or its absence noted)
- [ ] Topology file was loaded if configured or found at root
- [ ] All three memory indexes (procedural, semantic, episodic) were scanned
- [ ] `${aiDir}/memory/sessions/active/` was listed and orphans (>60min) auto-archived
- [ ] Worktree health was checked (or omitted if no worktrees)
- [ ] Framework version was compared (or omitted silently if unreadable)
- [ ] Orientation summary was printed with all required fields populated
- [ ] No session was created (bootstrap orients only — sessions auto-create on first code edit)

## When NOT to Use

- Mid-task (bootstrap is for session start only)
- Multiple times in one session
- When task is a quick one-off question with no code changes
