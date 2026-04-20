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

Compare versions. If they match, tell the user: "Already up to date (v{version}). No changes needed." and stop.

### Step 2: Inventory Files to Update

From `manifest.json`, collect all files. Each file has a `type`:

- **`overwrite`** — replace the destination file entirely with the plugin's version
- **`marker-merge`** — replace only the content between `<!-- myspec:framework-start -->` and `<!-- myspec:framework-end -->` markers, preserving everything outside the markers

For `files` entries: destination is `{aiDir}/{filename}`.
For `rules` entries: source is `framework-files/rules/{filename}`, destination is the `dest` path (e.g., `.claude/rules/workflow.md`).
For `hooks` entries: source is `hooks/{filename}`, destination is the `dest` path (e.g., `.claude/hooks/guard-git-branch.sh`).

For `hooks`: only process if `.claude/hooks/` directory exists. If it doesn't exist, skip all hooks and note: "Hooks directory not found — skipping Claude hook updates. Run the `init` skill with Claude hooks enabled to set them up."

### Step 3: Apply Updates

For each file in the manifest:

**`overwrite` strategy:**
1. Read the source file from `framework-files/{filename}` (or `framework-files/rules/{filename}` for rules, or `hooks/{filename}` for hooks)
2. Replace `${aiDir}` placeholders with the configured `aiDir` value
3. Write to destination, replacing the existing file entirely
4. For hooks: run `chmod +x {dest}` after writing

**`marker-merge` strategy:**
1. Read the source file from `framework-files/{filename}`
2. Extract content between `<!-- myspec:framework-start -->` and `<!-- myspec:framework-end -->` markers
3. Read the destination file
4. Replace the content between those same markers in the destination with the new framework content
5. Write the merged result back

If a destination file doesn't exist for `marker-merge`, create it from the source (treat as overwrite for missing files).

### Step 4: Update `.myspec.json`

Update `frameworkVersion` to the new version from `manifest.json`.

Update `frameworkFiles` entries — set `lastUpdated` to today's date for each file that was updated.

### Step 5: Print Summary

```
✅ myspec updated to v{newVersion}

Updated files:
  {list each file updated, with strategy used}

Preserved (project-customized sections):
  {list marker-merge files where project content was kept}

Hooks: {updated N scripts / skipped — hooks directory not found}

Next: Run the `bootstrap` skill to verify the setup is still correct.
```

## Rules

- Never overwrite content outside `<!-- myspec:framework-start/end -->` markers for `marker-merge` files
- Never modify files not listed in `manifest.json`
- Never update `.myspec.json` project fields (`name`, `description`, `techStack`, `aiDir`)
- If a source file is missing from the plugin, skip it and warn the user — do not delete the destination
