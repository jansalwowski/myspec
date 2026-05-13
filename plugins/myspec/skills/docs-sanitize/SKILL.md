---
name: "docs-sanitize"
description: "Automatically sanitize ${aiDir}/ documentation: fix naming, archive stale sessions, update references. Run after major documentation changes or periodically. Keywords: cleanup, naming conventions, session archiving, documentation maintenance. Do NOT use for code formatting or linting."
---

# Docs Sanitize

## Procedure

### 1. Naming Violations

Find and fix files that violate naming conventions:

```bash
# Find SCREAMING_CASE or PascalCase files (except README, INDEX)
# Replace "${aiDir}/" with your configured aiDir
find "${AI_DIR:-ai}/" -name "*.md" -type f | grep -E "[A-Z].*\.md$" | grep -v -E "(README|INDEX)\.md$"
```

**Fix**: Rename to kebab-case using `git mv`, update internal references.

### 2. Stale Sessions

Find sessions that need archiving:

- Files named `session-log.md` with `status: completed` in frontmatter
- Files named `session-log.md` older than 7 days with `status: active`

**Fix**: Move to `${aiDir}/sessions/YYYY-MM-DD-{slug}.md` format using `git mv`.

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
- ${aiDir}/feature/session-log.md → ${aiDir}/sessions/YYYY-MM-DD-slug.md

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
- ${aiDir}/session-log.md → ${aiDir}/sessions/2026-03-18-streetview-fix.md

### References Updated (2)
- ${aiDir}/INDEX.md:45 - updated link to memory-system.md
- ${aiDir}/pre-flight.md:12 - updated link to memory-system.md
```

## Verification Checklist

After running:

- [ ] Run project documentation sanitize command if configured
- [ ] Check git status - all renames should use `git mv`
- [ ] Verify no broken links in documentation
- [ ] All `session-log.md` files are either active (recent) or archived