---
description: "Update myspec framework files to latest version. Compares versions, updates framework-owned content while preserving project customizations between markers. Use after updating the myspec plugin. Do NOT use for initial setup (use /myspec:init)."
---

# Update — Framework File Updater

## Pre-checks

1. Read `.myspec.json` from project root. If not found, STOP and tell user: "No `.myspec.json` found. Run `/myspec:init` first."
2. Resolve `${CLAUDE_PLUGIN_ROOT}` — the directory containing the plugin's `plugin.json`.
3. Read `${CLAUDE_PLUGIN_ROOT}/framework-files/manifest.json` to get the latest framework version and file list.
4. Read `frameworkVersion` from `.myspec.json`.
5. Read `aiDir` from `.myspec.json` to resolve project file paths.

## Step 1: Compare Versions

Compare `.myspec.json` `frameworkVersion` with `manifest.json` `version`.

- If versions are identical, report: "Framework files are already up to date (version X.Y.Z)." and STOP.
- If manifest version is newer, proceed to Step 2.
- If `.myspec.json` version is newer than manifest (should not happen), warn: "Project framework version (X) is newer than plugin version (Y). This is unexpected — verify your plugin installation."

## Step 2: Build Change List

Read `manifest.json` `files` array. Each entry has:

```json
{
  "path": "anti-patterns.md",
  "type": "overwrite | marker-merge",
  "description": "Short description of the file"
}
```

For each file in the manifest:

1. Resolve source path: `${CLAUDE_PLUGIN_ROOT}/framework-files/${file.path}`
2. Resolve destination path: `${PROJECT_ROOT}/${aiDir}/${file.path}`
3. Check if destination exists
4. Determine action:
   - **New file** (destination missing): will be created
   - **Overwrite type**: entire file will be replaced
   - **Marker-merge type**: only content between markers will be replaced

## Step 3: Preview Changes

Display a summary table before making any changes:

```
## Framework Update: v<old> → v<new>

| File | Action | Type |
|------|--------|------|
| anti-patterns.md | update | overwrite |
| pre-flight.md | update | marker-merge |
| memory-system.md | create | new file |
```

For marker-merge files, show which sections will be updated (between markers) and confirm that project content outside markers will be preserved.

## Step 4: Ask for Confirmation

Ask: "Apply these updates? (yes/no)"

If user declines, STOP and report: "Update cancelled. No files were modified."

## Step 5: Apply Updates

For each file in the change list:

### Overwrite Type

1. Read source file from `${CLAUDE_PLUGIN_ROOT}/framework-files/${file.path}`
2. Write entire contents to `${PROJECT_ROOT}/${aiDir}/${file.path}`

### Marker-Merge Type

1. Read source file from `${CLAUDE_PLUGIN_ROOT}/framework-files/${file.path}`
2. Read destination file from `${PROJECT_ROOT}/${aiDir}/${file.path}`
3. In the destination file, find the markers:
   ```
   <!-- myspec:framework-start -->
   ... framework-owned content ...
   <!-- myspec:framework-end -->
   ```
4. Extract the content between the same markers in the source file
5. Replace ONLY the content between markers in the destination file with the source content
6. Preserve everything outside the markers (project customizations)
7. If markers are not found in the destination file, warn: "Markers not found in `${file.path}`. Skipping marker-merge — file may have been manually restructured. To fix, re-run `/myspec:setup <file-type>` to regenerate with markers."

### New File

1. Read source file from `${CLAUDE_PLUGIN_ROOT}/framework-files/${file.path}`
2. Create any missing parent directories
3. Write contents to `${PROJECT_ROOT}/${aiDir}/${file.path}`

## Step 6: Update .myspec.json

1. Set `frameworkVersion` to the new version from manifest
2. Update `frameworkFiles` object: for each processed file, set or update:
   ```json
   {
     "<file.path>": {
       "version": "<new version>",
       "type": "framework"
     }
   }
   ```
3. Write updated `.myspec.json`

## Step 7: Report Results

Print a summary:

```
## Framework Updated: v<old> → v<new>

### Updated Files
- anti-patterns.md (overwrite)
- pre-flight.md (marker-merge, project content preserved)

### New Files
- memory-system.md

### Skipped
- <file> (markers not found)

### Next Steps
- Review updated files for any project-specific adjustments needed
- If marker-merge files were skipped, run `/myspec:setup <file-type>` to regenerate them
```

## Verification Checklist

- [ ] `.myspec.json` `frameworkVersion` matches manifest version
- [ ] All overwrite files match their source in `${CLAUDE_PLUGIN_ROOT}/framework-files/`
- [ ] All marker-merge files have preserved content outside `<!-- myspec:framework-start/end -->` markers
- [ ] No marker-merge files were silently corrupted (content outside markers unchanged)
- [ ] `.myspec.json` `frameworkFiles` has entries for all updated files
- [ ] New files were created in correct locations
