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
jq '{aiDir, topologyFile, name: .project.name, techStack: .project.techStack}' .myspec.json
```

No `jq`? Use `python3 -c "import json;d=json.load(open('.myspec.json'));print({k:d.get(k) for k in ('aiDir','topologyFile')}, d.get('project'))"`.

Fields used: `project.name` / `project.techStack` (summary), `aiDir` (doc directory —
the key is required since 2.0; when it is absent the tooling uses `.ai` and the setup doctor reports it), `topologyFile`. If
`topologyFile` is set, read that file.

If `topologyFile` is not set, check for common topology files at project root: `backbone.yml`, `topology.yml`, `project.yml`. If found, read it and note: suggest the user add `"topologyFile": "{filename}"` to `.myspec.json`.

From the topology file, identify:
- Which areas/apps are relevant to the current task
- Key paths for the relevant area
- Any protected or never-modify boundaries from `boundaries.never_modify`
- Available commands (dev, test, lint, etc.) from `commands`
- `branches.integration` and `branches.release`, for step 4

### 2. Read Memory Index

Read `${aiDir}/memory/index.md` (Layer 1, the global index).

Scan its three sections:
- Critical Procedural (What NOT to Do)
- Must-Know Facts relevant to the current task
- Recent Significant Events

### 3. Scan Layer 2 Indexes, only with a task in hand

**With a task** (`/myspec:bootstrap <task>`, or the user has already stated one): read
`${aiDir}/memory/procedural/index.md`, `${aiDir}/memory/semantic/index.md`,
`${aiDir}/memory/episodic/index.md`. Match the Hook column against keywords from that
task (the index shape is `| ID | Hook | Anchor |`, episodic `Date`).

→ If match found: read the full memory file before proceeding.

**Without a task** (plain session-start orientation): do NOT read them. A keyword scan
with no keywords cannot match, and these tables grow about a row per session. Step 4
counts their rows instead, and `/myspec:memory-preflight` runs the real scan once the
task is known. Layer 1 (step 2) loads either way.

### 4. Run the Scan

One read-only command does the mechanical checks and prints the summary lines:

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/bootstrap-scan.sh"
```

When the topology file sets `branches.integration` and `branches.release` to different
branches, add `--integration <integration> --release <release>`: a release fix merged into
the release branch but not the integration branch leaves every plan written against stale
code. Add `--no-fetch` when offline.

| Line | What it checks |
|------|----------------|
| `**Memory**` | Entries in Layer 1 and rows in each Layer 2 index; a `**Layer 1**` line follows when Layer 1 is empty while Layer 2 has rows |
| `**Memory health**` | `memory-doctor.mjs --quiet`. Errors mean `/myspec:memory-create` will refuse to allocate an ID until they are fixed |
| `**Setup health**` | `setup-doctor.mjs --quiet`: framework files that differ from the plugin copy, hooks wired twice or broken, schema breaks. An error means part of the harness is inert |
| `**Active sessions**`, `**Dangling**`, `**Stale sessions**` | Live logs in the main checkout's session directory: under 6h listed, 1 to 6h dangling, over 6h stale |
| `**Worktree health**` | Non-main worktrees older than 3 days, missing on disk or prunable; no line without worktrees |
| `**Branch lag**` | Only with the two flags, and only when the integration branch lags or the check could not run |
| `**myspec version**` | `.myspec.json` `frameworkVersion` against the plugin manifest; no line when equal or unreadable |

Fix nothing here, and do not run `/myspec:update`, `/myspec:session-clean` or the
`worktree-clean` skill: name them in the summary. Stale logs belong to
`/myspec:session-clean`, which reads each one and asks before it archives or deletes. These
files belong to every session in the checkout, so never take a session id from one for
`"${CLAUDE_PLUGIN_ROOT}/lib/set-isolation.sh"`: that id comes only from the isolation hook's
block message.

### 5. Print Orientation Summary

```
## Bootstrap Complete

**Project**: {project name from .myspec.json, or inferred from the repo name}
**Stack**: {tech stack from .myspec.json, or "not configured"}
**Relevant area(s)**: [which apps/modules based on task context]
**Key paths**: [2-3 most relevant paths from project structure]
**Matches**: [entries that matched the task / "none" / omit this line when no task was given]
**Topology**: [{filename} loaded / not configured, use the `setup` skill with `backbone` to create one]
**Boundaries**: [any never_modify paths relevant to task, or "none relevant"]
{the lines bootstrap-scan.sh printed, as printed, except the **Memory** line}
```

Paste every script line unchanged except `**Memory**`: end that one line with `, scanned against "{task}"` or `, not scanned, no task yet: run /myspec:memory-preflight when the task is known`. When the script exits non-zero (2: outside a git work tree and any myspec project; it prints nothing on stdout), print `**Scan**: not run, bootstrap-scan.sh exited {code}: {its stderr line}` in place of its lines.

**Note**: Bootstrap satisfies the `memory-preflight` prerequisite for `session-start` **only when it was given a task**. A no-task bootstrap defers the Layer 2 scan, so `/myspec:memory-preflight` is still required before significant work. Sessions for code-editing work are auto-created by the `mark-code-changed.sh` hook on first code edit. Manual `session-start` is only useful for non-code sessions (pure debugging, discovery, doc-only work). Bootstrap creates, moves and archives no session file.

## Verification Checklist

- [ ] `.myspec.json` was checked (or its absence noted)
- [ ] Topology file was loaded if configured or found at root
- [ ] Layer 1 index was read; Layer 2 indexes were scanned if a task was given, and only counted if not
- [ ] `bootstrap-scan.sh` ran once, with the branch flags when the topology file names distinct integration and release branches
- [ ] Orientation summary printed with the script's lines as printed (only the **Memory** line gets the scan suffix), or the `**Scan**: not run` line on a non-zero exit
- [ ] No file was created, moved or fixed

## When NOT to Use

- Mid-task (bootstrap is for session start only)
- Multiple times in one session
- When task is a quick one-off question with no code changes
