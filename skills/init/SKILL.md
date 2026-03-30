---
name: "init"
description: "Use when setting up myspec in a new project for the first time. Keywords: initialize, setup, init, install myspec, new project setup, scaffold AI documentation. Creates .myspec.json, scaffolds ${aiDir}/ directory, copies framework files, sets up hooks and rules. Do NOT use to update framework files in an existing setup (use /myspec:update instead)."
---

# Init

**Announce at start:** "Initializing myspec in this project."

Interactive setup wizard. Run this once per project.

## Workflow

### Step 1: Check for Existing Setup

Check if `.myspec.json` already exists in the project root.

→ If it exists: warn user — "myspec is already initialized in this project. Run `/myspec:update` to update framework files. Continue anyway? (y/n)"
→ If no: proceed.

### Step 2: Discovery Questions

Ask these **one at a time** and wait for each answer:

1. **Project name and description**
   "What is the project name and a one-line description?"

2. **Tech stack**
   "What is the tech stack? (e.g., 'Node.js + TypeScript, PostgreSQL, REST API' or 'Python + Django, MySQL, GraphQL')"

3. **AI documentation directory**
   "Where should the AI documentation directory live? (default: `ai/`, alternatives: `.ai/`, `docs/ai/`, `spec/`)"
   → Default to `ai/` if user presses Enter.

4. **Verification commands** (ask in one message)
   "What are your project's verification commands? Leave empty to configure later.
   - Lint command (e.g., `npm run lint`, `pnpm lint`, `ruff check .`):
   - Type-check command (e.g., `npx tsc --noEmit`, `pnpm typecheck`, or leave empty):
   - Test command (e.g., `npm test`, `pnpm test`, `pytest`):"

5. **Hooks**
   "Set up Claude Code hooks? (y/n, default: y)
   This configures:
   - Git branch guard (prevents branch mutations on main checkout)
   - Frontmatter validation (enforces YAML frontmatter on AI docs)
   - Verification on stop (runs lint/tests before agent completes)"

### Step 3: Create `.myspec.json`

Write `.myspec.json` at project root:

```json
{
  "aiDir": "{aiDir from step 3}",
  "frameworkVersion": "1.0.0",
  "project": {
    "name": "{name from step 1}",
    "description": "{description from step 1}",
    "techStack": "{techStack from step 2}"
  },
  "frameworkFiles": {
    "memory-index.md": { "version": "1.0.0", "lastUpdated": "{TODAY}" },
    "pre-flight.md": { "version": "1.0.0", "lastUpdated": "{TODAY}" },
    "memory-system.md": { "version": "1.0.0", "lastUpdated": "{TODAY}" }
  }
  // "topologyFile": "backbone.yml"  ← added by /myspec:setup backbone
}
```

### Step 4: Scaffold Documentation Directory

Create the `${aiDir}/` directory structure. For each item below, create an empty placeholder if the file doesn't exist:

```
${aiDir}/
  features/
    index.yaml         ← copy from scaffolding/features/index.yaml
  memory/
    index.md           ← create with basic Layer 1 template
    procedural/
      index.md         ← copy from framework-files/templates/index-procedural.md
    semantic/
      index.md         ← copy from framework-files/templates/index-semantic.md
    episodic/
      index.md         ← copy from framework-files/templates/index-episodic.md
    sessions/
      .gitkeep
  .templates/
    session-log.md     ← copy from framework-files/templates/session-log.md
    memory-procedural.md
    memory-semantic.md
    memory-episodic.md
    feature-pre-flight.md
    README.md
  ideas/
    INTAKE-INSTRUCTIONS.md   ← copy from scaffolding/ideas/
    PRIORITY-LISTING.md
    PROCESSING-INSTRUCTIONS.md
  conventions/
    .gitkeep
  decisions/
    .gitkeep
  plans/
    .gitkeep
```

Also create these framework files in `${aiDir}/`:
- `memory-index.md` ← copy from `framework-files/memory-index.md`
- `pre-flight.md` ← copy from `framework-files/pre-flight.md`
- `memory-system.md` ← copy from `framework-files/memory-system.md`

Replace `${aiDir}` placeholders in all copied files with the configured value.

### Step 5: Set Up Hooks (if user said yes)

Create `.claude/hooks/` directory. Copy these files from the plugin's `hooks/` directory:
- `guard-git-branch.sh`
- `validate-frontmatter.sh`
- `mark-code-changed.sh`
- `verify-before-stop.sh`

Make them executable: `chmod +x .claude/hooks/*.sh`

Copy `.claude/rules/` framework rules from `framework-files/rules/`:
- `workflow.md`
- `memory-system.md`
- `ideas.md`
- `skill-optimization.md`

Create `.claude/settings.json` using `templates/settings-hooks.json` as the base.

Create `.claude/verification.json` using `templates/verification.json` as the base, substituting verification commands from Step 2 question 4.

If commands were left empty, write the placeholder structure and note: "Edit `.claude/verification.json` to add your verification commands."

### Step 6: Offer Blueprint Runs

Ask:
"Would you like to set up project files now? I can guide you through any of these:

1. **Backbone** — project topology file for agent orientation (`/myspec:setup backbone`) ← recommended first
2. **CLAUDE.md** — project context file for Claude (`/myspec:setup claude-md`)
3. **Conventions** — coding standards and testing patterns (`/myspec:setup conventions`)
4. **INDEX.md** — documentation navigation index (`/myspec:setup index-md`)
5. **Workflow** — development workflow definition (`/myspec:setup workflow`)
6. **Pre-flight** — project-specific pre-flight checks (`/myspec:setup pre-flight`)
7. **Anti-patterns** — project-specific anti-patterns (`/myspec:setup anti-patterns`)
8. **Skip** — do it manually later with `/myspec:setup <name>`

Which would you like? Enter numbers separated by commas, `all`, or `skip`."

For each selected blueprint, invoke `/myspec:setup <name>` in order.

### Step 7: Print Summary

```
✅ myspec initialized

Project: {name}
AI dir:  {aiDir}/
Hooks:   {enabled / skipped}

Created:
  .myspec.json
  ${aiDir}/ (features, memory, ideas, templates)
  {if hooks: .claude/hooks/ (4 hooks), .claude/rules/ (4 rules)}
  {if hooks: .claude/settings.json, .claude/verification.json}

Next steps:
  1. Run `/myspec:bootstrap` to verify the setup
  2. Add your first feature: `/myspec:feature-spec`
  3. Or process an existing idea: `/myspec:idea-process`
```

## Rules

- Ask one question at a time — do not batch questions
- Default to `ai/` for aiDir if user is uncertain
- Skip empty verification commands gracefully (write placeholder, note it needs filling)
- Never overwrite existing `.myspec.json` without explicit confirmation
- If `.claude/settings.json` already exists, merge hooks — do not replace it

## Verification Checklist

- [ ] `.myspec.json` created with project name, description, techStack, aiDir
- [ ] `${aiDir}/features/index.yaml` created
- [ ] `${aiDir}/memory/` directory structure created with all 3 type indexes
- [ ] `${aiDir}/ideas/` directory with instructions files
- [ ] `${aiDir}/memory-index.md` created (framework memory index)
- [ ] `${aiDir}/pre-flight.md` created
- [ ] If hooks enabled: `.claude/hooks/` has 4 scripts, all executable
- [ ] If hooks enabled: `.claude/rules/` has 4 framework rules
- [ ] If hooks enabled: `.claude/settings.json` and `.claude/verification.json` created
