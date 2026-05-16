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

For `files` entries: destination is `{aiDir}/{filename}`.
For `rules` entries: source is `framework-files/rules/{filename}`, destination is the `dest` path (e.g., `.claude/rules/workflow.md`).
For `hooks` entries: source is `hooks/{filename}`, destination is the `dest` path (e.g., `.claude/hooks/guard-git-branch.sh`).
For `lib` entries: source is `lib/{filename}`, destination is the `dest` path (e.g., `.claude/lib/path-normalize.sh`).

For `hooks` and `lib`: only process if `.claude/hooks/` directory exists (hooks and their helper lib travel together). If it doesn't exist, skip all hooks AND lib entries and note: "Hooks directory not found — skipping Claude hook + lib updates. Run the `init` skill with Claude hooks enabled to set them up."

### Step 3: Apply Updates

For each file in the manifest:

**`overwrite` strategy:**
1. Read the source file from `framework-files/{filename}` (or `framework-files/rules/{filename}` for rules, `hooks/{filename}` for hooks, `lib/{filename}` for lib)
2. Replace `${aiDir}` placeholders with the configured `aiDir` value
3. Write to destination, replacing the existing file entirely
4. For hooks: run `chmod +x {dest}` after writing (lib helpers are sourced, not executed — no chmod needed)

**`marker-merge` strategy:**
1. Read the source file from `framework-files/{filename}`
2. Extract content between `<!-- myspec:framework-start -->` and `<!-- myspec:framework-end -->` markers
3. Read the destination file
4. Replace the content between those same markers in the destination with the new framework content
5. Write the merged result back

If a destination file doesn't exist for `marker-merge`, create it from the source (treat as overwrite for missing files).

**Hook-wiring check (only if hooks were processed):** copying a hook file does nothing until it is registered in `.claude/settings.json`. After writing hooks, compare the project's `.claude/settings.json` against `templates/settings-hooks.json` (the canonical event→matcher→command shape):

- For each `command` in the template, check whether that exact `command` string appears anywhere under the project's `settings.json` `hooks` key.
- Collect every template command that is absent (typically a hook added in this version — e.g. a fresh `require-reuse-audit.sh`).
- If any are missing, print — do NOT edit `settings.json` (it is user-owned and not in `manifest.json`):

  ```
  ⚠ Hooks copied but not wired. Add these to .claude/settings.json under the
    shown event/matcher (deep-merge: append to existing `hooks` arrays, do not
    replace), then they take effect:
    {for each missing: event → matcher → "command": "<path>"}
  ```

  Cite `templates/settings-hooks.json` as the reference for the exact structure. If `.claude/settings.json` has no `hooks` key at all, instruct the user to copy the whole `hooks` block from the template.

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

Hooks: {updated N scripts / skipped — hooks directory not found}
Lib:   {updated N helpers / skipped — hooks directory not found}
Hook wiring: {all N hooks already wired in settings.json / M hook(s) need manual settings.json entries — see above}

Next: Run the `bootstrap` skill to verify the setup is still correct.
```

## Rules

- Never overwrite content outside `<!-- myspec:framework-start/end -->` markers for `marker-merge` files
- Never modify files not listed in `manifest.json`
- Never update `.myspec.json` project fields (`name`, `description`, `techStack`, `aiDir`)
- If a source file is missing from the plugin, skip it and warn the user — do not delete the destination

## Verification Checklist

After running the skill:

- [ ] `.myspec.json` `frameworkVersion` read and compared to `manifest.json`; stopped early if already current
- [ ] Every `manifest.json` entry processed with its declared strategy (`overwrite` / `marker-merge`)
- [ ] `marker-merge` files: content outside `<!-- myspec:framework-start/end -->` markers left untouched
- [ ] `hooks` and `lib` entries processed only when `.claude/hooks/` exists (else both skipped with the note)
- [ ] Each updated hook had `chmod +x` applied; lib helpers left non-executable (sourced, not run)
- [ ] `${aiDir}` binding refreshed between `myspec:paths` markers; content outside markers unchanged
- [ ] `.myspec.json` `frameworkVersion` bumped and `frameworkFiles[*].lastUpdated` set; project fields (`name`, `description`, `techStack`, `aiDir`) untouched
- [ ] Hook-wiring check run: hooks absent from `.claude/settings.json` reported; `settings.json` NOT modified
- [ ] No file outside `manifest.json` was modified
- [ ] Summary printed with `Updated files`, `Preserved`, `Hooks`, `Lib`, and `Hook wiring` lines
