---
description: "Generate or regenerate a project file via guided questions. Usage: /myspec:setup anti-patterns, /myspec:setup conventions, /myspec:setup claude-md, /myspec:setup pre-flight, /myspec:setup index-md, /myspec:setup workflow. Reads blueprints, asks project-specific questions, generates tailored content. Do NOT use for framework-owned template files (use /myspec:update)."
---

# Setup — Guided File Generation

## Pre-checks

1. Read `.myspec.json` from project root. If not found, STOP and tell user: "No `.myspec.json` found. Run `/myspec:init` first."
2. Read `aiDir` from `.myspec.json` to resolve output paths.
3. Read `$ARGUMENTS` to determine the file type. Extract the first argument as `fileType`.
4. Validate `fileType` against the supported list (see below). If invalid or missing, print supported types and STOP.

## Supported File Types

| Argument | Blueprint | Output Path | Description |
|----------|-----------|-------------|-------------|
| `anti-patterns` | `blueprints/anti-patterns.md` | `${aiDir}/anti-patterns.md` | Project-specific anti-patterns and pitfalls |
| `pre-flight` | `blueprints/pre-flight.md` | `${aiDir}/pre-flight.md` | Pre-implementation checklist |
| `conventions` | `blueprints/conventions.md` | `${aiDir}/conventions/coding-standards.md` | Coding standards and conventions |
| `claude-md` | `blueprints/claude-md.md` | `CLAUDE.md` (project root) | Claude Code project instructions |
| `index-md` | `blueprints/index-md.md` | `${aiDir}/INDEX.md` | AI documentation index |
| `workflow` | `blueprints/workflow.md` | `${aiDir}/workflow.md` | Development workflow definition |

If no argument provided, print:
```
Usage: /myspec:setup <file-type>

Supported file types:
  anti-patterns  — Project-specific anti-patterns and pitfalls
  pre-flight     — Pre-implementation checklist
  conventions    — Coding standards and conventions
  claude-md      — Claude Code project instructions (CLAUDE.md)
  index-md       — AI documentation index
  workflow       — Development workflow definition
```

## Step 1: Resolve Paths

1. Set `blueprintPath` = `${CLAUDE_PLUGIN_ROOT}/blueprints/${fileType}.md`
2. Set `outputPath` based on the file type table above
3. Verify `blueprintPath` exists. If not, STOP and report: "Blueprint not found at `${blueprintPath}`. The myspec plugin installation may be incomplete."

## Step 2: Load Context

1. Read the blueprint file from `blueprintPath`
2. Read `.myspec.json` for project context:
   - `project.name`
   - `project.description`
   - `project.techStack`
   - `aiDir`
3. If the output file already exists, read it and note that this is a regeneration (existing content will be replaced)

## Step 3: Follow Blueprint Instructions

Each blueprint contains:

- **Header section**: metadata about what the file does
- **Discovery questions**: questions to ask the user, marked with `<!-- question -->` tags or listed in a `## Questions` section
- **Template**: the output template with placeholders
- **Framework markers**: sections that should be wrapped in `<!-- myspec:framework-start/end -->` markers

Execute the blueprint by:

1. Read all discovery questions from the blueprint
2. Ask the user each question **one at a time**, waiting for each answer
3. For questions with defaults, show the default: "Question text (default: X):"
4. Store all answers for template population

## Step 4: Generate the File

1. Use the blueprint's template as the base structure
2. Replace all placeholders with:
   - User answers from discovery questions
   - Project context from `.myspec.json`
3. Wrap framework-owned sections with markers:
   ```
   <!-- myspec:framework-start -->
   ... framework-managed content ...
   <!-- myspec:framework-end -->
   ```
4. Place project-specific content (from user answers) OUTSIDE the framework markers

## Step 5: Handle Existing Files

If the output file already exists:

1. Warn: "File `${outputPath}` already exists."
2. If the existing file has framework markers, offer: "Replace framework sections only, keeping your customizations? (yes/replace-all/cancel)"
   - **yes**: marker-merge (replace between markers, keep the rest)
   - **replace-all**: overwrite entire file
   - **cancel**: abort
3. If no markers exist, offer: "Overwrite entire file? (yes/cancel)"

## Step 6: Write the File

1. Create any missing parent directories for the output path
2. Write the generated content to `outputPath`
3. If `fileType` is not `claude-md` (which lives in project root), verify the file is inside `${aiDir}/`

## Step 7: Report Results

Print:

```
## Created: <outputPath>

<Brief description of what was generated>

### Content Summary
- <Section 1>: <brief description>
- <Section 2>: <brief description>
...

### Framework Markers
This file contains framework-managed sections between `<!-- myspec:framework-start/end -->` markers.
These sections will be updated by `/myspec:update`. Your customizations outside the markers are preserved.
```

If this was the last recommended setup step from `/myspec:init`, suggest:
"All recommended setup steps complete. Your project is ready for specification-driven development."

## Verification Checklist

- [ ] Output file exists at the expected path
- [ ] File contains `<!-- myspec:framework-start -->` and `<!-- myspec:framework-end -->` markers
- [ ] Project-specific content (from user answers) is present outside framework markers
- [ ] Placeholders are fully resolved (no remaining `<placeholder>` or `${variable}` tokens)
- [ ] File is valid markdown (no broken formatting)
- [ ] `.myspec.json` project context was correctly incorporated
