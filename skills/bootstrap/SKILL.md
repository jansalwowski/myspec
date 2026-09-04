---
name: "bootstrap"
description: "Use when a session starts and the agent needs project orientation before answering or changing anything. Keywords: orient, where am I, what is this project, what's the state. Do NOT use mid-task or twice in one session."
---

# Bootstrap

## Workflow

### 1. Read Project Config

Extract only the fields needed — do NOT `cat` the whole file. `.myspec.json` may carry a
`frameworkFiles` pin block and a `migrations` list, neither of which matters here:

```bash
jq '{aiDir, topologyFile, frameworkVersion, name: .project.name, techStack: .project.techStack}' .myspec.json
```

No `jq`? Use `python3 -c "import json;d=json.load(open('.myspec.json'));print({k:d.get(k) for k in ('aiDir','topologyFile','frameworkVersion')}, d.get('project'))"`.

Fields used: `project.name` / `project.techStack` (summary), `aiDir` (doc directory —
the key is required since 2.0; when it is absent the tooling uses `.ai` and the setup doctor reports it), `frameworkVersion` (step 6), `topologyFile`. If
`topologyFile` is set, read that file.

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

### 3. Scan Layer 2 Indexes — only with a task in hand

**With a task** (`/myspec:bootstrap <task>`, or the user has already stated one): read
`${aiDir}/memory/procedural/index.md`, `${aiDir}/memory/semantic/index.md`,
`${aiDir}/memory/episodic/index.md`. Match the Hook column against keywords from that
task (the index shape is `| ID | Hook | Anchor |`, episodic `Date`).

→ If match found: read the full memory file before proceeding.

**Without a task** (plain session-start orientation): do NOT read them. A keyword scan
with no keywords cannot match, and these three tables are the largest read in this skill —
they grow about a row per session, so the cost climbs for the life of the project. Count
the rows instead. Rows are `| [P001](…) |`, either case; `grep -c` prints `0` itself on no
match, so no `|| echo 0` fallback:

```bash
for t in procedural semantic episodic; do
  c=$(grep -ciE '^\| *\[[pse][0-9]+' "${aiDir}/memory/$t/index.md" 2>/dev/null) || true
  printf '%s: %s\n' "$t" "${c:-0}"
done
```

Report the counts and route the real scan to `/myspec:memory-preflight`, which runs once
the task is known. Layer 1 (step 2) loads either way — that is what it is budgeted for.

If Layer 1 holds no entries while Layer 2 has rows, say so: the layering is costing a file
read and returning nothing. Suggest promoting the handful of genuinely critical entries.

### 3b. Memory Health

If `.claude/lib/memory-doctor.mjs` exists and `node` is available:

```bash
node .claude/lib/memory-doctor.mjs --quiet
```

It prints `ERROR` lines and a summary (`memory doctor: clean` or `N error(s), M warning(s)`)
in about a second. Report the summary in step 7; do not fix anything here. Errors mean the
tooling cannot read the project as it is — memories without `hook:`,
duplicate IDs across branches — and `/myspec:memory-create` will refuse to allocate an ID
until they are fixed. `memory-index.mjs --backfill` derives the first; the rest are per-file. If the
script is missing, the project predates it: report `memory health: not checked — run
/myspec:update`.

### 3c. Setup Health

If `.claude/lib/setup-doctor.mjs` exists and `node` is available:

```bash
node .claude/lib/setup-doctor.mjs --quiet
```

The deterministic install check, about a second. It covers framework files whose content
no longer matches the plugin copy (not just the version scalar step 6 compares), hooks
registered but missing or not executable, hook scripts on disk that no settings file
wires, `bash -n` failures under `.claude/hooks/` and `.claude/lib/`, schema breaks in
`.myspec.json` and `.claude/verification.json`, and entries in `${aiDir}/features/index.yaml`
that the manifest parser cannot read. Every finding carries a literal `run:` command or a
one-line `fix:`.

Report the summary in step 7 and fix nothing here. An `ERROR` means part of the harness is
inert — a hook that never fires, a gate that approves without running anything — which is
invisible from the outside; that is the reason for the check. Drop `--quiet` when the count
is non-zero and the user wants the detail; add `--json` when another skill consumes it.

`$CLAUDE_PLUGIN_ROOT` unset means the framework-drift checks have no reference copy: the
run says so in a `NOTE` and the rest still applies. Pass `--plugin-root <dir>` (resolved
the way step 6 does) to include them. If the script itself is missing, the project predates
it: report `setup health: not checked — run /myspec:update`.

### 4. Check for Active Sessions

List `.claude/state/sessions/*.md` — the primary checkout's, gitignored. Your own session, if one exists yet, is the file whose `## Files touched` lists a path you edited.

For each file, compare its mtime to the current epoch.

**Auto-archive policy** (>6 hours stale = orphaned; 1–6h is ambiguous — a sibling agent may still be working, so report those instead of touching them; see the Session Lifecycle table in `.claude/rules/memory-system.md`):

```bash
NOW=$(date +%s)
# Use find, not a bare glob: an unmatched `*.md` glob is a hard error under zsh
# ("no matches found") and aborts the sweep before the loop body ever runs.
find .claude/state/sessions -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null |
while IFS= read -r -d '' f; do
  MTIME=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
  AGE=$(( NOW - MTIME ))
  if [ "$AGE" -gt 21600 ]; then
    SLUG=$(basename "$f" .md | head -c 8)
    DATE=$(date '+%Y-%m-%d')
    mkdir -p "${aiDir}/memory/sessions/archive"
    sed -i.bak 's/^status: active/status: abandoned/' "$f" && rm "$f.bak"
    mv "$f" "${aiDir}/memory/sessions/archive/${DATE}-orphaned-${SLUG}.md"
  fi
done
```

After cleanup, count remaining active sessions and report in summary:
- `Active sessions: 0` → no active work
- `Active sessions: N` → list each as `{session_id_first8} — {topic}`
- If sessions were auto-archived: `Auto-archived M orphaned sessions`
- If sessions are 1–6h stale: `M sessions possibly dangling — run /myspec:session-clean to triage`

Sessions are auto-created by `mark-code-changed.sh` (PostToolUse hook) on first code edit, so manual `/myspec:session-start` is rarely needed for code-editing work.

### 5. Check for Stale Worktrees

Run `git worktree list` and count non-main worktrees. For each:
- Check last commit date: `git log -1 --format=%ct <sha>` vs current epoch
- Flag as **stale** if last commit >3 days ago
- Flag as **orphaned** if path does not exist on disk

Run `git worktree prune --dry-run` to detect pruneable references.

→ If issues found: include warning in Step 6 summary — "**Worktree health**: WARNING — N stale/orphaned worktrees. Use the `worktree-clean` skill."
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
**Memory**: Layer 1 [N entries] | Layer 2 [P procedural, S semantic, E episodic rows] — [scanned against "{task}" / not scanned, no task yet: run /myspec:memory-preflight when the task is known]
**Matches**: [entries that matched the task / "none" / omit this line entirely when no task was given]
**Memory health**: [clean / N errors, M warnings — run `node .claude/lib/memory-doctor.mjs` for details / not checked — run /myspec:update]
**Setup health**: [clean / N errors, M warnings — run `node .claude/lib/setup-doctor.mjs` for details / not checked — run /myspec:update]
**Topology**: [{filename} loaded / not configured — use the `setup` skill with `backbone` to create one]
**Active sessions**: [N (list of session_id prefixes + topics) / 0]
**Auto-archived**: [M orphaned sessions / 0 (omit line if 0)]
**Dangling**: [M sessions 1–6h stale — run /myspec:session-clean (omit line if 0)]
**Worktree health**: [clean (N active) / WARNING — N stale/orphaned. Use the `worktree-clean` skill]
**myspec version**: [omit if versions match / plugin v{plugin} ahead of project v{project} — run /myspec:update / plugin v{plugin} behind project v{project} — update your plugin / project on v{project}, plugin has v{plugin} (non-semver)]
**Boundaries**: [any never_modify paths relevant to task, or "none relevant"]
```

**Note**: Bootstrap satisfies the `memory-preflight` prerequisite for `session-start` **only when it was given a task** — a no-task bootstrap defers the Layer 2 scan, so `/myspec:memory-preflight` is still required before significant work. Sessions for code-editing work are auto-created by the `mark-code-changed.sh` hook on first code edit — no skill invocation needed. Manual `session-start` is only useful for non-code sessions (pure debugging, discovery, doc-only work). Bootstrap itself does NOT create a session; it only orients the project context and archives orphaned sessions.

## Verification Checklist

- [ ] `.myspec.json` was checked (or its absence noted)
- [ ] Topology file was loaded if configured or found at root
- [ ] Layer 1 index was read; Layer 2 indexes were scanned if a task was given, counted and deferred if not
- [ ] Memory doctor run (or its absence reported); summary line in the output, nothing fixed
- [ ] Setup doctor run (or its absence reported); summary line in the output, nothing fixed
- [ ] `.claude/state/sessions/` was listed and orphans (> 6h) auto-archived; 1–6h only reported
- [ ] Worktree health was checked (or omitted if no worktrees)
- [ ] Framework version was compared (or omitted silently if unreadable)
- [ ] Orientation summary was printed with all required fields populated
- [ ] No session was created (bootstrap orients only — sessions auto-create on first code edit)

## When NOT to Use

- Mid-task (bootstrap is for session start only)
- Multiple times in one session
- When task is a quick one-off question with no code changes
