---
name: "setup"
description: "Use when generating project-specific files from guided wizards. Invokes blueprints by name: backbone (topology file), claude-md (CLAUDE.md), conventions (coding standards), index-md (documentation index), workflow (dev workflow), pre-flight (pre-flight checklist), anti-patterns (project anti-patterns). Keywords: setup backbone, setup claude-md, setup conventions, generate project files, create topology file, run blueprint. Do NOT use for first-time project init (use /myspec:init)."
---

# Setup

**Announce at start:** "Running setup: {blueprint name}."

Dispatches guided blueprint wizards to generate project-specific files. Each blueprint asks discovery questions and generates a file tailored to the project.

## Available Blueprints

| Blueprint | Generates | Output |
|-----------|-----------|--------|
| `backbone` | Project topology file for agent orientation | `backbone.yml` (project root) |
| `claude-md` | CLAUDE.md project context file | `CLAUDE.md` (project root) |
| `conventions` | Coding standards and testing patterns | `${aiDir}/conventions/` |
| `index-md` | Documentation navigation index | `${aiDir}/INDEX.md` |
| `workflow` | Development workflow definition | `${aiDir}/workflow.md` |
| `pre-flight` | Project-specific pre-flight checks | `${aiDir}/pre-flight.md` |
| `anti-patterns` | Project-specific anti-patterns | `${aiDir}/memory-index.md` |

## Workflow

### Step 1: Resolve Blueprint

If no blueprint name was given: print the table above and ask "Which blueprint would you like to run?"

If a name was given: match it to the table. If no match, list available names and ask the user to choose.

### Step 2: Pre-flight Check

Read `.myspec.json` to get `aiDir` and project metadata.

→ If `.myspec.json` does not exist: warn "myspec is not initialized in this project. Run `/myspec:init` first." and stop.

Check if the output file already exists.

→ If it exists: ask "This file already exists. Overwrite? (y/n)"
→ If user says no: stop.

### Step 3: Execute Blueprint

Read the blueprint file from the plugin's `blueprints/{name}.md`.

Follow the blueprint's **Discovery Questions** exactly — ask one at a time, wait for each answer.

Generate the output using the blueprint's **Output Format**.

Write to the **Output Location** specified by the blueprint.

### Step 4: Post-generation

**For `backbone` blueprint only**: After writing the file, update `.myspec.json` by adding or updating the `topologyFile` key with the generated filename.

For all blueprints: print a brief confirmation:
```
✅ {filename} created

Next: {relevant next step — e.g., "Run /myspec:bootstrap to load the topology" or "Run /myspec:setup claude-md next"}
```

## Rules

- Ask one discovery question at a time — never batch all questions at once
- Always read `.myspec.json` before running a blueprint (needed for `${aiDir}` substitution)
- Replace `${aiDir}` placeholders in all generated output with the configured value
- Respect existing files — always ask before overwriting
- Do not modify any framework-owned files (memory-index.md framework section, pre-flight.md framework section)
