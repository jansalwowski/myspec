---
name: "init"
description: "Use when setting up myspec in a project for the first time. Keywords: initialize, install myspec, new project setup, scaffold AI documentation. Do NOT use on an existing setup (update)."
---

# Init

**Announce at start:** "Initializing myspec in this project."

Interactive setup wizard. Run this once per project.

## Workflow

### Step 1: Check for Existing Setup

Check if `.myspec.json` already exists in the project root.

→ If it exists: warn user — "myspec is already initialized in this project. Run the `update` skill to update framework files. Continue anyway? (y/n)"
→ If no: proceed.

### Step 2: Discovery Questions

Ask these **one at a time** and wait for each answer:

1. **Project name and description**
   "What is the project name and a one-line description?"

2. **Tech stack**
   "What is the tech stack? (e.g., 'Node.js + TypeScript, PostgreSQL, REST API' or 'Python + Django, MySQL, GraphQL')"

3. **AI documentation directory**
   "Where should the AI documentation directory live? (default: `.ai`, alternatives: `ai`, `docs/ai`, `spec`)"
   → Default to `.ai` if user presses Enter. Store it without a trailing slash.

4. **Verification commands** (ask in one message)
   "What are your project's verification commands? Leave empty to configure later.
   - Lint command (e.g., `npm run lint`, `pnpm lint`, `ruff check .`):
   - Type-check command (e.g., `npx tsc --noEmit`, `pnpm typecheck`, or leave empty):
   - Test command (e.g., `npm test`, `pnpm test`, `pytest`):"

5. **Harness config**
   "Set up the framework rules and the verification config under `.claude/`? (y/n, default: y)
   This writes `.claude/rules/` (the always-loaded framework rules) and `.claude/verification.json` (what the stop gate runs), and gitignores `.claude/state/`.

   The hooks themselves need no setup: the plugin runs them from its own `hooks.json` wherever it is enabled —
   - Work-isolation gate (asks develop vs worktree before the first source edit; blocks main-checkout builds and branch mutations while a session works in a worktree)
   - Session tracking (creates a live log in `.claude/state/sessions/` on the first code edit)
   - Frontmatter validation (enforces YAML frontmatter on AI docs)
   - Verification on stop (runs lint/tests before agent completes)
   - Field metrics on session end (per-skill counts and timings in gitignored `.claude/state/metrics/`, never uploaded; opt out with `"feedback": { "metrics": false }` or `DO_NOT_TRACK=1`)

   A teammate without the plugin gets none of them (and none of the skills)."

### Step 3: Create `.myspec.json`

First resolve the plugin directory (needed here and in Steps 4–5):
1. `$CLAUDE_PLUGIN_ROOT` if set.
2. Else the directory containing this `SKILL.md`, walking up until a sibling `framework-files/manifest.json` is found.

Read `framework-files/manifest.json` from the plugin directory. Let `{VERSION}` be its `frameworkVersion`.

Write `.myspec.json` at project root:

```json
{
  "aiDir": "{aiDir from step 2}",
  "frameworkVersion": "{VERSION}",
  "project": {
    "name": "{name from step 2}",
    "description": "{description from step 2}",
    "techStack": "{techStack from step 2}"
  },
  "migrations": {the manifest's `migrations` array, copied verbatim}
}
```

A fresh install already has the shape every one-shot migration produces, so recording them all is what stops `update` from running them here. Do not write a `frameworkFiles` block: since 2.0 it holds pins only, and a project adds a pin by hand when it customizes a framework file. The `setup` skill may later add a `"topologyFile"` key (blueprint `backbone`) — do not add it here.

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
      archive/
        .gitkeep            ← create empty file   (live logs go to .claude/state/sessions/, created by the hook)
  .templates/
    session-log.md          ← copy from framework-files/templates/session-log.md
    memory-procedural.md    ← copy from framework-files/templates/memory-procedural.md
    memory-semantic.md      ← copy from framework-files/templates/memory-semantic.md
    memory-episodic.md      ← copy from framework-files/templates/memory-episodic.md
  ideas/
    INTAKE-INSTRUCTIONS.md      ← copy from scaffolding/ideas/INTAKE-INSTRUCTIONS.md
    PRIORITY-LISTING.md         ← copy from scaffolding/ideas/PRIORITY-LISTING.md
    PROCESSING-INSTRUCTIONS.md  ← copy from scaffolding/ideas/PROCESSING-INSTRUCTIONS.md
    processed/
      .gitkeep              ← create empty file
  conventions/
    .gitkeep
  decisions/
    .gitkeep
  plans/
    .gitkeep
```

Also create these framework files in `${aiDir}/`:
- `anti-patterns.md` ← copy from `framework-files/anti-patterns.md`
- `pre-flight.md` ← copy from `framework-files/pre-flight.md`
- `work-isolation.md` ← copy from `framework-files/work-isolation.md` (the procedure the isolation hooks' block messages cite; the always-loaded rule of the same name is only its contract)

Replace `${aiDir}` placeholders with the configured value in the documents copied above — the `${aiDir}/` tree and `.claude/rules/`. Nothing else is copied: the hooks and their lib run from the plugin and resolve `aiDir` at runtime.

### Step 4.5: Announce `${aiDir}` binding to project context

So other myspec skills can resolve `${aiDir}/...` paths in their instructions, write the binding to the project's always-loaded agent context. Determine the target file:

- If `AGENTS.md` exists at project root: target it.
- Else if `CLAUDE.md` exists at project root: target it.
- Else: create `AGENTS.md` at project root.

Append (or replace, if a marker section already exists) the following block to the target file. Use the markers exactly — they make the block idempotent on re-runs and on subsequent `update` runs.

```markdown
<!-- BEGIN myspec:paths -->
## myspec paths

Skill instructions reference `${aiDir}/`. Resolve to **`{aiDir from step 2}/`** (configured in `.myspec.json`).
<!-- END myspec:paths -->
```

If the markers already exist in the file, replace everything between them. Do not modify content outside the markers.

### Step 5: Set Up the Harness Config (if user said yes)

Do not copy anything from the plugin's `hooks/` or `lib/`, and do not write a `hooks` key into `.claude/settings.json`: since 3.0 the plugin's `hooks.json` runs the framework hooks, and a settings entry would run a copy a second time (`/myspec:doctor` reports one as `hook-wired-locally`).

Append `.claude/state/` to `.gitignore` (create the file if absent). The hooks keep per-checkout state there (session logs, isolation decisions, the memory ID registry — committing it would make one clone's claims another clone's stale floor), and the field metrics in `.claude/state/metrics/` are not recorded until the line exists.

Copy `.claude/rules/` framework rules from `framework-files/rules/`:
- `workflow.md`
- `memory-system.md`
- `auto-memory-style.md`
- `ideas.md`
- `skill-optimization.md`
- `paths.md`
- `skill-self-test.md`
- `work-isolation.md`

Create `.claude/verification.json` using `templates/verification.json` as the base, substituting verification commands from Step 2 question 4.

If commands were left empty, write the placeholder structure and note: "Edit `.claude/verification.json` to add your verification commands."

Then run each supplied command once. Any that already fails on a clean tree is measuring pre-existing debt, and as a gate it blocks every stop over failures no session caused. For those, tell the user which command failed and offer to fill in its `diffCommand` — the variant the gate runs instead, scoped to `$MYSPEC_BASE_REF` (the merge base with the default branch, exported by the stop hook) and guarded against an empty file set. Leave `command` as the full-repo run.

### Step 6: Offer Blueprint Runs

Ask:
"Would you like to set up project files now? I can guide you through any of these:

1. **Backbone** — project topology file for agent orientation (`setup` with blueprint `backbone`) ← recommended first
2. **CLAUDE.md** — project context file for Claude (`setup` with blueprint `claude-md`)
3. **Conventions** — coding standards and testing patterns (`setup` with blueprint `conventions`)
4. **INDEX.md** — documentation navigation index (`setup` with blueprint `index-md`)
5. **Workflow** — development workflow definition (`setup` with blueprint `workflow`)
6. **Pre-flight** — project-specific pre-flight checks (`setup` with blueprint `pre-flight`)
7. **Anti-patterns** — project-specific anti-patterns (`setup` with blueprint `anti-patterns`)
8. **Skip** — do it manually later with the `setup` skill

Which would you like? Enter numbers separated by commas, `all`, or `skip`."

For each selected blueprint, invoke the `setup` skill with that blueprint name in order.

### Step 7: Print Summary

```
✅ myspec initialized

Project: {name}
AI dir:  {aiDir}/
Hooks:   run from the plugin (nothing copied)
Harness config: {written / skipped}

Created:
  .myspec.json
  ${aiDir}/ (features, memory, ideas, templates)
  {if harness config: .claude/rules/ (8 rules), .claude/verification.json, .gitignore line for .claude/state/}
  {if base agents installed: list each ~/.{harness}/agents/{file} that was installed or updated, grouped by harness}

Next steps:
  1. Run the `bootstrap` skill to verify the setup
  2. Add your first feature with the `feature-spec` skill
  3. Or process an existing idea with the `idea-process` skill
```

## Rules

- Ask one question at a time — do not batch questions
- Default to `.ai` for aiDir if user is uncertain; never store a trailing slash
- Skip empty verification commands gracefully (write placeholder, note it needs filling)
- Never overwrite existing `.myspec.json` without explicit confirmation
- Never write to `.claude/settings.json`, `.claude/hooks/` or `.claude/lib/`: the plugin runs the framework hooks and lib itself
- Base subagents (`skills/feature-implement/agents/`) install to user scope only. Never copy to project-scope `.claude/agents/`, `.cursor/agents/`, `.codex/agents/` in the repo root.
- Skip a harness entirely if `~/.{harness}/` does not exist — the user does not use that tool.
- Never silently overwrite a locally-customized agent file; always diff + prompt.

## Verification Checklist

- [ ] `.myspec.json` created with project name, description, techStack, aiDir
- [ ] `.myspec.json` `frameworkVersion` matches `manifest.json`'s (no hardcoded literal), `migrations` copied from the manifest, no `frameworkFiles` block, `aiDir` without a trailing slash
- [ ] `${aiDir}/features/index.yaml` created
- [ ] `${aiDir}/memory/` directory structure created with all 3 type indexes
- [ ] `${aiDir}/memory/sessions/archive/` created (no `active/` — live logs live in `.claude/state/sessions/`)
- [ ] `${aiDir}/ideas/` directory with instructions files and `processed/`
- [ ] `${aiDir}/anti-patterns.md` created (framework anti-pattern index — distinct from `${aiDir}/memory/index.md`, the Layer 1 memory index)
- [ ] `${aiDir}/pre-flight.md` and `${aiDir}/work-isolation.md` created
- [ ] `${aiDir}` binding written to `AGENTS.md` (or `CLAUDE.md`) between `myspec:paths` markers
- [ ] If harness config enabled: `.claude/rules/` has 8 framework rules and `.claude/verification.json` exists; `.gitignore` has a `.claude/state/` line
- [ ] Nothing written under `.claude/hooks/`, `.claude/lib/` or `.claude/settings.json`
