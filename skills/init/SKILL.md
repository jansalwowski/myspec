---
name: "init"
description: "Use when setting up myspec in a new project for the first time. Keywords: initialize, setup, init, install myspec, new project setup, scaffold AI documentation. Do NOT use to update framework files in an existing setup (use update instead)."
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
   "Where should the AI documentation directory live? (default: `ai/`, alternatives: `.ai/`, `docs/ai/`, `spec/`)"
   → Default to `ai/` if user presses Enter.

4. **Verification commands** (ask in one message)
   "What are your project's verification commands? Leave empty to configure later.
   - Lint command (e.g., `npm run lint`, `pnpm lint`, `ruff check .`):
   - Type-check command (e.g., `npx tsc --noEmit`, `pnpm typecheck`, or leave empty):
   - Test command (e.g., `npm test`, `pnpm test`, `pytest`):"

5. **Hooks**
   "Set up Claude-compatible repo hooks and rules under `.claude/`? (y/n, default: y)
   This configures:
   - Git branch guard (prevents branch mutations on main checkout)
   - Frontmatter validation (enforces YAML frontmatter on AI docs)
   - Verification on stop (runs lint/tests before agent completes)

   Note: Codex can use the plugin's built-in `hooks.json` directly. This option is for keeping project-local Claude compatibility."

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
  "frameworkFiles": {
    "{one entry per key}": { "version": "{VERSION}", "lastUpdated": "{TODAY}" }
  }
}
```

Build `frameworkFiles` from the manifest — never hardcode the list:
- one entry per key in the manifest's `files` block (e.g. `"memory-index.md"`, `"templates/session-log.md"`), and
- one `"rules/{filename}"` entry per key in its `rules` block.

Each entry's value is `{ "version": "{VERSION}", "lastUpdated": "{TODAY}" }`. The `setup` skill may later add a `"topologyFile"` key (blueprint `backbone`) — do not add it here.

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
      active/
        .gitkeep            ← create empty file
      archive/
        .gitkeep            ← create empty file
  .templates/
    session-log.md          ← copy from framework-files/templates/session-log.md
    memory-procedural.md    ← copy from framework-files/templates/memory-procedural.md
    memory-semantic.md      ← copy from framework-files/templates/memory-semantic.md
    memory-episodic.md      ← copy from framework-files/templates/memory-episodic.md
    feature-pre-flight.md   ← copy from framework-files/templates/feature-pre-flight.md
    example-usage.md        ← copy from framework-files/templates/example-usage.md
    README.md               ← copy from framework-files/templates/README.md
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
- `memory-index.md` ← copy from `framework-files/memory-index.md`
- `pre-flight.md` ← copy from `framework-files/pre-flight.md`
- `memory-system.md` ← copy from `framework-files/memory-system.md`

Replace `${aiDir}` placeholders in all copied files with the configured value.

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

### Step 5: Set Up Hooks (if user said yes)

Create `.claude/hooks/` directory. Copy these files from the plugin's `hooks/` directory:
- `guard-git-branch.sh`
- `validate-frontmatter.sh`
- `mark-code-changed.sh`
- `verify-before-stop.sh`
- `no-absolute-paths.sh`
- `require-reuse-audit.sh`

Make them executable: `chmod +x .claude/hooks/*.sh`

Create `.claude/lib/` and copy the lib files listed in `manifest.json`'s `lib` block from the plugin's `lib/` directory, then `chmod +x .claude/lib/*.sh` (some are sourced, some are invoked directly). Use the manifest as the source of truth — do not glob the directory (it also holds plugin-internal helpers like `lib/features-status-audit/` and `lib/brainstorm-server/`, which run from the plugin root and are never copied into projects). These back skills and hooks (e.g. `<repo_root>`/`<encoded_cwd>` placeholders; the reuse-audit table validator; the branch-guard command scanner; sanctioned branch cleanup; memory ID allocation, index generation, and the memory conformance check).

Append `.claude/state/` to `.gitignore` (create the file if absent). `memory-claim-id.sh` keeps its per-checkout ID registry there; committing it would make one clone's claims another clone's stale floor.

Copy `.claude/rules/` framework rules from `framework-files/rules/`:
- `workflow.md`
- `memory-system.md`
- `auto-memory-style.md`
- `ideas.md`
- `skill-optimization.md`
- `paths.md`
- `skill-self-test.md`

Create `.claude/settings.json` using `templates/settings-hooks.json` as the base.

Create `.claude/verification.json` using `templates/verification.json` as the base, substituting verification commands from Step 2 question 4.

If commands were left empty, write the placeholder structure and note: "Edit `.claude/verification.json` to add your verification commands."

### Step 5.5: Install Base Subagents (user scope)

The `feature-implement` orchestrator dispatches via two reusable subagents (`worker-base`, `reviewer-base`) installed at **user scope**, available across every project. The canonical source ships in the plugin at `skills/feature-implement/agents/{claude,cursor,codex}/`.

Ask:
"Install the `worker-base` and `reviewer-base` subagents to your user-scope agent directories? (y/n, default: y)

This copies six files (no project-scope footprint):
  - `~/.claude/agents/worker-base.md`, `~/.claude/agents/reviewer-base.md`
  - `~/.cursor/agents/worker-base.md`, `~/.cursor/agents/reviewer-base.md`
  - `~/.codex/agents/worker-base.toml`, `~/.codex/agents/reviewer-base.toml`

Harnesses you do not use will be skipped automatically (if `~/.{harness}/` does not exist)."

If user said no: skip this step entirely.

If user said yes, for each harness in `[claude, cursor, codex]`:

1. **Source dir:** plugin's `skills/feature-implement/agents/{harness}/`
2. **Target dir:** `~/.{harness}/agents/`
3. **Skip condition:** if `~/.{harness}/` does NOT exist as a directory, skip this harness silently (user does not use it).
4. **Per file** (`worker-base.{md|toml}`, `reviewer-base.{md|toml}` — choose extension by harness: `.md` for claude/cursor, `.toml` for codex):
   - `mkdir -p ~/.{harness}/agents`
   - If destination does not exist: copy source → destination. Note as installed.
   - If destination exists and content matches source byte-for-byte: skip silently. Note as up-to-date.
   - If destination exists and differs: show a short diff (or note that the file has been locally customized) and ask: "Overwrite `~/.{harness}/agents/{file}`? (y/n, default: n)". On `y`: copy. On `n`: skip and warn that the local version may diverge from the plugin's `<verdict>` / `<result>` contract.

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
Hooks:   {enabled / skipped}

Created:
  .myspec.json
  ${aiDir}/ (features, memory, ideas, templates)
  {if hooks: .claude/hooks/ (6 hooks), .claude/lib/ (N helpers, per manifest), .claude/rules/ (7 rules)}
  {if hooks: .claude/settings.json, .claude/verification.json}
  {if base agents installed: list each ~/.{harness}/agents/{file} that was installed or updated, grouped by harness}

Next steps:
  1. Run the `bootstrap` skill to verify the setup
  2. Add your first feature with the `feature-spec` skill
  3. Or process an existing idea with the `idea-process` skill
```

## Rules

- Ask one question at a time — do not batch questions
- Default to `ai/` for aiDir if user is uncertain
- Skip empty verification commands gracefully (write placeholder, note it needs filling)
- Never overwrite existing `.myspec.json` without explicit confirmation
- If `.claude/settings.json` already exists, deep-merge the `hooks` key only:
  - For each hook type (`PreToolUse`, `PostToolUse`, `Stop`), append new hook entries that don't already exist (match by `command` field)
  - Do not modify or remove existing hook entries or any other settings keys
  - If no `hooks` key exists in the existing file, add it
- Base subagents (`skills/feature-implement/agents/`) install to user scope only. Never copy to project-scope `.claude/agents/`, `.cursor/agents/`, `.codex/agents/` in the repo root.
- Skip a harness entirely if `~/.{harness}/` does not exist — the user does not use that tool.
- Never silently overwrite a locally-customized agent file; always diff + prompt.

## Verification Checklist

- [ ] `.myspec.json` created with project name, description, techStack, aiDir
- [ ] `.myspec.json` `frameworkVersion` and every `frameworkFiles` version match `manifest.json`'s `frameworkVersion` (no hardcoded literals); entries cover all manifest `files` + `rules` keys
- [ ] `${aiDir}/features/index.yaml` created
- [ ] `${aiDir}/memory/` directory structure created with all 3 type indexes
- [ ] `${aiDir}/memory/sessions/active/` and `${aiDir}/memory/sessions/archive/` created
- [ ] `${aiDir}/ideas/` directory with instructions files and `processed/`
- [ ] `${aiDir}/memory-index.md` created (framework memory index)
- [ ] `${aiDir}/pre-flight.md` created
- [ ] `${aiDir}` binding written to `AGENTS.md` (or `CLAUDE.md`) between `myspec:paths` markers
- [ ] If hooks enabled: `.claude/hooks/` has 6 scripts, all executable
- [ ] If hooks enabled: `.claude/lib/` has every helper in `manifest.json`'s `lib` block, all executable
- [ ] If hooks enabled: `.claude/rules/` has 7 framework rules
- [ ] If hooks enabled: `.claude/settings.json` and `.claude/verification.json` created
- [ ] If base agents installed: for each harness with an existing `~/.{harness}/` dir, both `worker-base` and `reviewer-base` exist at `~/.{harness}/agents/` and match the plugin source (or user explicitly opted to keep a divergent local version)
