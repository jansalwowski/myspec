---
name: "setup"
description: "Use to generate project-specific files from guided wizards. Blueprints: backbone, claude-md, conventions, code-review, mockup, index-md, workflow, pre-flight, anti-patterns. Do NOT use for first-time init (init)."
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
| `code-review` | Reviewer goals, standards, and run behavior | `.claude/rules/code-review.md` + `.myspec.json` |
| `mockup` | Mockup stack, tooling commands, and hard guards for the feature-mockup skills | `${aiDir}/conventions/mockup-design.md` + `.myspec.json` |
| `index-md` | Documentation navigation index | `${aiDir}/INDEX.md` |
| `workflow` | Development workflow definition | `${aiDir}/workflow.md` |
| `pre-flight` | Project-specific pre-flight checks | `${aiDir}/pre-flight.md` |
| `anti-patterns` | Project-specific anti-patterns | `${aiDir}/anti-patterns.md` |

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

**If the blueprint defines a Post-generation section** (e.g. `code-review` updates the `.myspec.json` `codeReview` block): follow those steps after writing the primary file.

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
- Do not modify any framework-owned files (anti-patterns.md framework section, pre-flight.md framework section)

## Verification Checklist

- [ ] Blueprint name resolved against the Available Blueprints table (asked the user if missing or unmatched)
- [ ] `.myspec.json` read before running; stopped with the init warning if absent
- [ ] Checked whether the output file exists; asked before overwriting
- [ ] Discovery questions asked one at a time, each answer awaited
- [ ] Output generated using the blueprint's Output Format and written to its Output Location
- [ ] `${aiDir}` placeholders replaced with the configured value
- [ ] Post-generation steps applied (`backbone` → `topologyFile`; blueprint-defined sections like `code-review` → `.myspec.json` block)
- [ ] Confirmation printed with the relevant next step
