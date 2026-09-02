---
name: "update"
description: "Use when updating myspec framework files in an existing project after the plugin has been updated. Keywords: update myspec, upgrade framework, sync framework files, update rules, update templates. Do NOT use for first-time setup (use init instead)."
---

# Update

**Announce at start:** "Updating myspec framework files."

Updates framework-owned files in an existing project while preserving project customizations.

## Prerequisites

- `.myspec.json` exists in project root (project is initialized)
- myspec plugin has been updated in the host tool

→ If `.myspec.json` does not exist: stop and tell user to run the `init` skill first.

## Workflow

### Step 1: Read Current Version

Read `.myspec.json` from project root. Extract `frameworkVersion` and `aiDir`.

Read `framework-files/manifest.json` from the plugin directory. Extract `frameworkVersion`.

Resolve the plugin directory in this order:
1. `$CLAUDE_PLUGIN_ROOT` if set.
2. The directory containing this `SKILL.md`, walking up until a sibling `framework-files/manifest.json` is found (typically `…/myspec/{version}/framework-files/manifest.json`).
3. If neither resolves, stop and tell the user: "Cannot locate plugin manifest. Verify the myspec plugin is installed."

Compare versions. If they match, tell the user: "Already up to date (v{version}). No changes needed." and stop.

### Step 2: Inventory Files to Update

From `manifest.json`, collect all files. Each file has a `type`:

- **`overwrite`** — replace the destination file entirely with the plugin's version
- **`marker-merge`** — replace only the content between `<!-- myspec:framework-start -->` and `<!-- myspec:framework-end -->` markers, preserving everything outside the markers

For `files` entries: destination is `{aiDir}/{filename}` — **except** `templates/{name}` entries, which install to `{aiDir}/.templates/{name}` (the dot-directory `init` creates; skills read templates from there — never create `{aiDir}/templates/`).
For `rules` entries: source is `framework-files/rules/{filename}`, destination is the `dest` path (e.g., `.claude/rules/workflow.md`).
For `hooks` entries: source is `hooks/{filename}`, destination is the `dest` path (e.g., `.claude/hooks/guard-git-branch.sh`).
For `lib` entries: source is `lib/{filename}`, destination is the `dest` path (e.g., `.claude/lib/path-normalize.sh`).

**Pinned files — skip, never overwrite.** A project may carry a locally-customized copy of a framework file. `.myspec.json` records that as `frameworkFiles["<manifest key>"].pinned`, whose value is a short reason string. Before applying any entry, look up its key (`rules/workflow.md`, `hooks/guard-git-branch.sh`, `lib/branch-cleanup.sh`, `templates/session-log.md`, …) and skip it if `pinned` is set. Collect these for the summary; do not bump their `version`/`lastUpdated`.

Without this, a sync silently reverts local edits: the file carries no marker distinguishing "customized" from "stale", so `overwrite` treats deliberate local content as drift. That has happened — a sync reverted four rules whose upstream copies had not changed at all, costing ~690 tokens of always-loaded context until it was noticed.

Pinning is the project's call, not the skill's. Never add or remove a pin on the project's behalf; report pinned files and let the user decide whether the local reason still holds.

For `hooks` and `lib`: only process if `.claude/hooks/` directory exists (hooks and their helper lib travel together). If it doesn't exist, skip all hooks AND lib entries and note: "Hooks directory not found — skipping Claude hook + lib updates. Run the `init` skill with Claude hooks enabled to set them up."

### Step 3: Apply Updates

For each file in the manifest:

**`overwrite` strategy:**
1. Read the source file from `framework-files/{filename}` (or `framework-files/rules/{filename}` for rules, `hooks/{filename}` for hooks, `lib/{filename}` for lib)
2. Replace `${aiDir}` placeholders with the configured `aiDir` value
3. Write to destination, replacing the existing file entirely
4. For hooks and lib: run `chmod +x {dest}` after writing. Some helpers are sourced and some are invoked directly (`branch-cleanup.sh`, `memory-claim-id.sh`) — setting the bit on all of them is harmless for the sourced ones and required for the rest.

**`marker-merge` strategy:**
1. Read the source file from `framework-files/{filename}`
2. Extract content between `<!-- myspec:framework-start -->` and `<!-- myspec:framework-end -->` markers
3. Read the destination file
4. Replace the content between those same markers in the destination with the new framework content
5. Write the merged result back

If a destination file doesn't exist for `marker-merge`, create it from the source (treat as overwrite for missing files).

**Hook-wiring check (only if hooks were processed):** copying a hook file does nothing until it is registered in `.claude/settings.json`, and a registered hook without `+x` never runs either. Both are mechanical, so run them rather than reading for them:

```bash
node .claude/lib/setup-doctor.mjs --plugin-root "${CLAUDE_PLUGIN_ROOT}" wiring
```

It compares the project's `settings.json` against `templates/settings-hooks.json` per event→command pair, and adds executability, existence, and `bash -n`. Report every finding with the `run:` / `fix:` line it carries and do NOT edit `settings.json` — it is user-owned and not in `manifest.json`. For each `wiring-incomplete` finding, cite `templates/settings-hooks.json` as the reference for the exact structure (deep-merge: append to existing `hooks` arrays, do not replace). If `.claude/settings.json` has no `hooks` key at all, instruct the user to copy the whole `hooks` block from the template.

If the doctor is not on disk yet (the project predates it, and this run is what installs it), do the comparison by hand this once: for each `command` in the template, check whether that exact string appears anywhere under the project's `settings.json` `hooks` key, and report the absent ones.

### Step 3.5: Sync Base Subagents (user scope)

The plugin ships `worker-base` and `reviewer-base` source under `skills/feature-implement/agents/{claude,cursor,codex}/`. They install to **user scope** (`~/.{harness}/agents/`) — never project scope. This step keeps the user-scope copies in sync with the plugin source while preserving any local customizations.

For each harness in `[claude, cursor, codex]`:

1. **Skip condition:** if `~/.{harness}/` does NOT exist as a directory, skip this harness silently (user does not use it).
2. `mkdir -p ~/.{harness}/agents` if needed.
3. **For each file** (`worker-base.{md|toml}`, `reviewer-base.{md|toml}` — `.md` for claude/cursor, `.toml` for codex):
   - **Source:** plugin's `skills/feature-implement/agents/{harness}/{file}`.
   - **Destination:** `~/.{harness}/agents/{file}`.
   - If destination missing: copy source → destination. Note as "installed (was missing)".
   - If destination identical to source: skip silently. Note as "up-to-date".
   - If destination differs from source: show a short diff (or note that the file has been locally customized) and ask: "Sync `~/.{harness}/agents/{file}` to plugin version? (y/n, default: n)". On `y`: copy. On `n`: skip and warn that the local version may diverge from the plugin's `<verdict>` / `<result>` contract.

Do not write anywhere outside `~/.{harness}/agents/`. Never install as project-scope (`.claude/agents/`, `.cursor/agents/`, `.codex/agents/` in the repo root).

### Step 3.6: Migrate memory indexes and check memory health

Only when lib entries were processed and `{aiDir}/memory/` exists. Since v1.23.0 the index tables are generated from the memory files, and the generator refuses to run on a memory without `hook:`. Projects that predate it carry hand-written tables in the legacy column shape (`Use When` / `Topic` / `Event`); on those, a plain regeneration would drop every row. This step migrates them. Never skip it — `memory-claim-id.sh` refuses to allocate IDs until the doctor passes.

1. Dry run, and show the output to the user:
   ```bash
   node .claude/lib/memory-index.mjs --backfill --dry-run
   ```
   Per index it lists the header migration, how many `hook:` lines would be written and from where, and row deltas. `from heading (review)` means a memory had neither `hook:` nor an index row, so its H1 becomes the hook — list those for the user to review afterwards.
2. Apply:
   ```bash
   node .claude/lib/memory-index.mjs --backfill
   ```
3. Verify — must print `memory indexes are up to date`:
   ```bash
   node .claude/lib/memory-index.mjs --check
   ```
4. Health:
   ```bash
   node .claude/lib/memory-doctor.mjs
   ```
   Report its summary line in Step 6. Remaining errors (duplicate IDs across branches, malformed anchors) are project content: list them, do not fix them silently.
5. Ensure `.gitignore` contains a `.claude/state/` line — the ID registry is per-checkout state and must never be committed. Append it if missing (create `.gitignore` if absent).

If `node` is unavailable, print: "Memory index migration skipped — node not found. Run `node .claude/lib/memory-index.mjs --backfill` when it is available; ID allocation is blocked until then."

### Step 3.7: Verify the install

Everything above wrote files; this reads them back. Run the full doctor from the project root:

```bash
node .claude/lib/setup-doctor.mjs --plugin-root "${CLAUDE_PLUGIN_ROOT}"
```

Step 5 is about to stamp `frameworkVersion` to the new version, so run this **before** it — while the versions still differ, content drift is reported as a warning ("update pending"). After the stamp the same drift is an error, which is the point: a `framework-drift` or `framework-missing` error on the next run means this update half-applied.

Read the result as a checklist of this run:

- `framework-missing` / `framework-drift` → a manifest entry did not get written. Re-apply that entry, do not stamp over it.
- `marker-missing` → a `marker-merge` file lost its `<!-- myspec:framework-start -->` / `<!-- myspec:framework-end -->` markers; restore them from the plugin copy before the next update silently skips the file forever.
- `shipped-drift` / `shipped-missing` on `.claude/hooks/*` or `.claude/lib/*` → a hook or helper is stale or absent; these are `overwrite` entries, so re-copy.
- Anything in the `schema` group → fix before finishing; an unparseable `.myspec.json` or `verification.json` silently disables the surfaces that read it.

Report the summary line in Step 6. `framework-unlisted` warnings are expected on a project that predates `frameworkFiles` tracking — Step 5 clears them by writing the missing entries.

### Step 4: Refresh `${aiDir}` binding in project context

Skills written in v1.10.0+ reference `${aiDir}/...` as a placeholder. Ensure the project's always-loaded context defines it. Determine target file:

- If `AGENTS.md` exists at project root: target it.
- Else if `CLAUDE.md` exists at project root: target it.
- Else: create `AGENTS.md` at project root.

Append (or replace, if a marker section already exists) this block:

```markdown
<!-- BEGIN myspec:paths -->
## myspec paths

Skill instructions reference `${aiDir}/`. Resolve to **`{aiDir}/`** (configured in `.myspec.json`).
<!-- END myspec:paths -->
```

If the markers already exist, replace everything between them with the current value. Do not modify content outside the markers.

### Step 5: Update `.myspec.json`

Update `frameworkVersion` to the new version from `manifest.json`.

Update `frameworkFiles` entries — set `lastUpdated` to today's date for each file that was updated.

### Step 6: Print Summary

```
✅ myspec updated to v{newVersion}

Updated files:
  {list each file updated, with strategy used}

Preserved (project-customized sections):
  {list marker-merge files where project content was kept}

Pinned (skipped — locally customized):
  {list each pinned file with its reason, or "none"}

Hooks: {updated N scripts / skipped — hooks directory not found}
Lib:   {updated N helpers / skipped — hooks directory not found}
Hook wiring: {all N hooks already wired in settings.json / M hook(s) need manual settings.json entries — see above}
Memory: {migrated N legacy index(es), backfilled M hook: lines (K from heading — review) / indexes already generated / skipped — no memory tree}
        doctor: {clean / N error(s), M warning(s) — see above}
Setup:  {clean / N error(s), M warning(s) — see above / skipped — node not found}

Base subagents (user scope, ~/.{harness}/agents/):
  {per harness: list each file as installed / up-to-date / synced / kept-local / skipped (~/.{harness}/ not present)}

Next: Run the `bootstrap` skill to verify the setup is still correct.
```

**Generated-config advisory (print only when `.myspec.json` has a `mockups` block):** blueprint-generated files are project-owned and never auto-updated. Read `{aiDir}/conventions/mockup-design.md` frontmatter `myspec_version` (treat a missing key as "unstamped") and append to the summary:

```
Generated config (project-owned, not auto-updated):
  {aiDir}/conventions/mockup-design.md — generated by myspec v{myspec_version | "unstamped"}, plugin now v{newVersion}.
  If release notes since then mention the mockup surface, re-run /myspec:setup mockup
  (it prompts before overwriting; port the Repeated user feedback log forward).
```

Do NOT modify the file — this is advisory only.

## Rules

- Never overwrite a file whose `frameworkFiles[...].pinned` is set, and never add or clear a pin yourself
- Never overwrite content outside `<!-- myspec:framework-start/end -->` markers for `marker-merge` files
- Never modify files not listed in `manifest.json`
- Never update `.myspec.json` project fields (`name`, `description`, `techStack`, `aiDir`)
- If a source file is missing from the plugin, skip it and warn the user — do not delete the destination
- Base subagents (`skills/feature-implement/agents/`) install to user scope only. Never copy to project-scope `.claude/agents/`, `.cursor/agents/`, `.codex/agents/` in the repo root.
- Skip a harness entirely if `~/.{harness}/` does not exist — the user does not use that tool.
- Never silently overwrite a locally-customized agent file; always diff + prompt.

## Verification Checklist

After running the skill:

- [ ] `.myspec.json` `frameworkVersion` read and compared to `manifest.json`; stopped early if already current
- [ ] Every `manifest.json` entry processed with its declared strategy (`overwrite` / `marker-merge`)
- [ ] Entries pinned in `.myspec.json` skipped, their versions left untouched, and listed in the summary
- [ ] `templates/*` entries written to `{aiDir}/.templates/` (no `{aiDir}/templates/` created)
- [ ] `marker-merge` files: content outside `<!-- myspec:framework-start/end -->` markers left untouched
- [ ] `hooks` and `lib` entries processed only when `.claude/hooks/` exists (else both skipped with the note)
- [ ] Each updated hook and lib helper had `chmod +x` applied
- [ ] Memory migration run when a memory tree exists: `--backfill --dry-run` shown, `--backfill` applied, `--check` clean, doctor summary reported, `.claude/state/` gitignored
- [ ] `${aiDir}` binding refreshed between `myspec:paths` markers; content outside markers unchanged
- [ ] `.myspec.json` `frameworkVersion` bumped and `frameworkFiles[*].lastUpdated` set; project fields (`name`, `description`, `techStack`, `aiDir`) untouched
- [ ] Hook-wiring check run via `setup-doctor.mjs wiring` (or by hand when the doctor was not yet installed): findings reported; `settings.json` NOT modified
- [ ] Full `setup-doctor.mjs` run in Step 3.7, before the Step 5 version stamp; every `install`- and `schema`-group error resolved or reported
- [ ] No file outside `manifest.json` was modified
- [ ] Summary printed with `Updated files`, `Preserved`, `Hooks`, `Lib`, and `Hook wiring` lines
- [ ] Generated-config advisory printed when a `mockups` block exists (`mockup-design.md` read, never modified)
