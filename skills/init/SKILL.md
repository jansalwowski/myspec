---
description: "Initialize myspec in a project. Creates .myspec.json, scaffolds AI documentation directory, copies framework files. Use when setting up SDD for a new project. Do NOT use in already-initialized projects (use /myspec:update instead)."
---

# Init — Project Setup Wizard

## Pre-checks

1. Check if `.myspec.json` already exists in the project root. If it does, STOP and tell the user: "Project already initialized. Use `/myspec:update` to update framework files or delete `.myspec.json` to reinitialize."
2. Resolve `${CLAUDE_PLUGIN_ROOT}` — this is the directory containing the plugin's `plugin.json` (i.e., the `.claude-plugin/` directory of the myspec plugin installation).
3. Verify `${CLAUDE_PLUGIN_ROOT}/framework-files/` and `${CLAUDE_PLUGIN_ROOT}/scaffolding/` directories exist. If not, report which directories are missing and stop.

## Step 1: Gather Project Information

Ask the user these questions **one at a time**, waiting for each answer:

1. "What should the AI documentation directory be called? Options: `.ai` (default, hidden), `ai` (visible), or a custom name."
   - Default: `.ai` if user presses enter or says "default"
2. "What is the project name?"
3. "One-line project description:"
4. "What is the tech stack? (e.g., PHP 8.3, Laravel 11, PostgreSQL)"

Store answers as: `aiDir`, `projectName`, `projectDescription`, `techStack`.

## Step 2: Create .myspec.json

Write `.myspec.json` to the project root with this exact schema:

```json
{
  "aiDir": "<aiDir>",
  "frameworkVersion": "1.0.0",
  "project": {
    "name": "<projectName>",
    "description": "<projectDescription>",
    "techStack": "<techStack>"
  },
  "frameworkFiles": {}
}
```

## Step 3: Create Directory Structure

Create all directories under `${PROJECT_ROOT}/${aiDir}/`:

```
${aiDir}/
├── features/
├── memory/
│   ├── procedural/
│   ├── semantic/
│   ├── episodic/
│   ├── sessions/
│   │   └── archive/
├── templates/
├── ideas/
├── decisions/
├── conventions/
├── plans/
├── specs/
```

For empty directories (`decisions/`, `conventions/`, `plans/`, `specs/`), create a `.gitkeep` file in each.

## Step 4: Copy Scaffolding Files

1. Copy `${CLAUDE_PLUGIN_ROOT}/scaffolding/features/index.yaml` to `${aiDir}/features/index.yaml`
2. Copy all files from `${CLAUDE_PLUGIN_ROOT}/scaffolding/ideas/` to `${aiDir}/ideas/`:
   - `INTAKE-INSTRUCTIONS.md`
   - `PRIORITY-LISTING.md`
   - `PROCESSING-INSTRUCTIONS.md`

## Step 5: Create Memory Index Files

Create these files with minimal content:

**`${aiDir}/memory/index.md`**:
```markdown
---
title: Memory System Index
purpose: Central index for all memory types
---

# Memory System

| Type | Path | Purpose |
|------|------|---------|
| Procedural | procedural/ | How-to knowledge, patterns, processes |
| Semantic | semantic/ | Facts, concepts, domain knowledge |
| Episodic | episodic/ | Event-specific memories, incidents |
| Sessions | sessions/ | Active and archived work sessions |
```

**`${aiDir}/memory/procedural/index.md`**:
```markdown
---
title: Procedural Memory Index
purpose: How-to knowledge and patterns
---

# Procedural Memories

No memories yet. Use `/myspec:memory-create` to add procedural memories.
```

**`${aiDir}/memory/semantic/index.md`**:
```markdown
---
title: Semantic Memory Index
purpose: Facts, concepts, domain knowledge
---

# Semantic Memories

No memories yet. Use `/myspec:memory-create` to add semantic memories.
```

**`${aiDir}/memory/episodic/index.md`**:
```markdown
---
title: Episodic Memory Index
purpose: Event-specific memories and incidents
---

# Episodic Memories

No memories yet. Use `/myspec:memory-create` to add episodic memories.
```

## Step 6: Copy Framework Files

Copy these files from `${CLAUDE_PLUGIN_ROOT}/framework-files/` to `${aiDir}/`:

| Source | Destination |
|--------|-------------|
| `framework-files/anti-patterns.md` | `${aiDir}/anti-patterns.md` |
| `framework-files/pre-flight.md` | `${aiDir}/pre-flight.md` |
| `framework-files/memory-system.md` | `${aiDir}/memory-system.md` |

## Step 7: Copy Template Files

Copy all files from `${CLAUDE_PLUGIN_ROOT}/framework-files/templates/` to `${aiDir}/templates/`.

## Step 8: Update .myspec.json frameworkFiles

After all copies, update the `frameworkFiles` object in `.myspec.json` with each copied framework file. Use relative paths from the aiDir as keys and include the source version:

```json
{
  "frameworkFiles": {
    "anti-patterns.md": { "version": "1.0.0", "type": "framework" },
    "pre-flight.md": { "version": "1.0.0", "type": "framework" },
    "memory-system.md": { "version": "1.0.0", "type": "framework" }
  }
}
```

## Step 9: Output Summary

Print a summary in this format:

```
## myspec initialized

**Project:** <projectName>
**AI Directory:** <aiDir>/
**Framework Version:** 1.0.0

### Created
- <aiDir>/.myspec.json
- <aiDir>/features/index.yaml
- <aiDir>/memory/ (with index files)
- <aiDir>/templates/ (with template files)
- <aiDir>/ideas/ (with intake/priority/processing instructions)
- <aiDir>/decisions/ (empty)
- <aiDir>/conventions/ (empty)
- <aiDir>/plans/ (empty)
- <aiDir>/specs/ (empty)
- <aiDir>/anti-patterns.md
- <aiDir>/pre-flight.md
- <aiDir>/memory-system.md

### Next Steps
Run these commands to complete setup:
1. `/myspec:setup anti-patterns` — customize anti-patterns for your project
2. `/myspec:setup conventions` — define coding conventions
3. `/myspec:setup claude-md` — generate your CLAUDE.md file
```

## Verification Checklist

- [ ] `.myspec.json` exists in project root with valid JSON
- [ ] `${aiDir}/` directory exists with all subdirectories
- [ ] `${aiDir}/features/index.yaml` exists and is valid YAML
- [ ] `${aiDir}/memory/index.md` exists
- [ ] `${aiDir}/ideas/INTAKE-INSTRUCTIONS.md` exists
- [ ] `${aiDir}/anti-patterns.md` exists
- [ ] `${aiDir}/pre-flight.md` exists
- [ ] `${aiDir}/memory-system.md` exists
- [ ] `${aiDir}/templates/` contains copied template files
- [ ] `.myspec.json` frameworkFiles has 3 entries
- [ ] Empty directories have `.gitkeep` files
