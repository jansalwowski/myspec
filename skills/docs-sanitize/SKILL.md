---
name: "docs-sanitize"
description: "Use when the ${aiDir} documentation tree needs maintenance — naming-convention violations, misplaced session files, or references to renamed/moved files. Keywords: cleanup, naming conventions, session archiving, documentation maintenance, sanitize docs. Do NOT use for code formatting or linting."
---

# Docs Sanitize

## Workflow

### 1. Naming Violations

Find and fix files that violate naming conventions:

```bash
# Find SCREAMING_CASE or PascalCase files (except README, INDEX)
find "${aiDir}/" -name "*.md" -type f | grep -E "[A-Z].*\.md$" | grep -v -E "(README|INDEX)\.md$"
```

**Fix**: Rename to kebab-case using `git mv`, update internal references.

### 2. Misplaced Session Files

Session lifecycle (staleness triage, archiving of dangling sessions) belongs to `/myspec:session-clean` — do not re-implement it here. This step only fixes files in the wrong **place**:

- Live logs under `.claude/state/sessions/` whose `status:` is already terminal (`completed` | `abandoned`) — they were finished but never moved. **Fix**: `mv` to `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md` and `git add`.
- Session files left under `${aiDir}/memory/sessions/active/` (the pre-2.0 location; `/myspec:update` moves them) or any file named `session-log.md` / `active.md` under `${aiDir}`. **Fix**: live ones (`status: active`) → `mv` to `.claude/state/sessions/`; finished ones → `git mv` into `${aiDir}/memory/sessions/archive/YYYY-MM-DD-{slug}.md`, setting a terminal `status:` if missing (`completed` if the log has an Outcome, else `abandoned`).

### 3. Broken References

After renames/moves, search for broken references:

```bash
# Search for references to old file names
grep -r "OLD_FILE_NAME.md" ${aiDir}/ --include="*.md"
```

**Fix**: Update references to new paths using Edit tool.

### 4. Report

Output summary in this format:

```
## Sanitization Complete

### Renamed (N)
- old/path.md → new/path.md

### Archived (N)
- .claude/state/sessions/{id}.md → ${aiDir}/memory/sessions/archive/YYYY-MM-DD-slug.md

### References Updated (N)
- file:line - description of change
```

### Example Output

```
## Sanitization Complete

### Renamed (3)
- ${aiDir}/MEMORY-SYSTEM.md → ${aiDir}/memory-system.md
- ${aiDir}/features/maps/NOTES.md → ${aiDir}/features/maps/notes.md

### Archived (1)
- ${aiDir}/session-log.md → ${aiDir}/memory/sessions/archive/2026-03-18-streetview-fix.md

### References Updated (2)
- ${aiDir}/INDEX.md:45 - updated link to memory-system.md
- ${aiDir}/pre-flight.md:12 - updated link to memory-system.md
```

## Verification Checklist

After running:

- [ ] Run project documentation sanitize command if configured
- [ ] Check git status - all renames should use `git mv`
- [ ] Verify no broken links in documentation
- [ ] No terminal-status files left under `.claude/state/sessions/`; no session files under `${aiDir}` outside `memory/sessions/archive/`