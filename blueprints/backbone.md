# Blueprint: Backbone (Project Topology)

## Purpose
Guide the user through creating a project topology file (`backbone.yml`) that gives AI agents a structured map of the entire codebase — apps, paths, commands, boundaries, and conventions. The bootstrap skill reads this file at session start to orient the agent quickly without filesystem scanning.

## Discovery Questions (ask one at a time)

1. "Monorepo or single-app? Which package manager? (e.g., pnpm, npm, yarn)
   If monorepo: workspace config filename? (e.g., `pnpm-workspace.yaml`, `package.json` workspaces)"

2. "List each app and package:
   - name, path, one-line purpose, tech stack
   Example: `api | apps/api | GraphQL API | Express + Apollo + Prisma`
   (For single-app: just describe the one app)"

3. "For each app/package, list key source directories and their purpose. Or type 'skip' to leave as TODOs.
   Example:
   ```
   api:
     src/services/ — business logic, one file per domain
     src/schema/ — GraphQL types
   web:
     src/components/ — UI components by domain
     src/stores/ — Pinia state stores
   ```"

4. "Database? Provide: ORM/client, schema path, migrations path. Or 'none' to skip.
   Example: `Prisma | apps/api/prisma/schema.prisma | apps/api/prisma/migrations/`"

5. "Key commands — provide as many as apply:
   - dev (start dev server)
   - build
   - test
   - lint
   - typecheck
   - any db commands (migrate, seed, generate, studio)
   - any codegen commands
   Example: `dev: pnpm dev | test: pnpm test | lint: pnpm lint`"

6. "Files or directories the agent should NEVER modify directly? Or 'skip'.
   Examples: migration files, .env files, generated code directories"

7. "What filename? (default: `backbone.yml`)" — default to backbone.yml if user presses Enter.

## Output Format

### Monorepo template

```yaml
version: 1
project: {project name from .myspec.json}
description: {description from .myspec.json}
package_manager: {from Q1}
workspace_config: {from Q1, or omit if not provided}

# ── STRUCTURE ────────────────────────────────────────────────────────────────

apps:
{for each app from Q2/Q3:}
  {name}:
    path: {path}
    package: "@{project}/{name}"  # TODO: adjust if different
    purpose: {purpose}
    stack: [{stack items}]
    entry: src/index.ts  # TODO: verify
    src:
{if Q3 provided src dirs:}
      {dir}: {purpose}
{else:}
      # TODO: add key source directories
    tests:
      pattern: "src/**/*.test.ts"  # TODO: verify
      runner: vitest  # TODO: verify
    config:
      tsconfig: {path}/tsconfig.json  # TODO: verify

{if packages from Q2:}
packages:
  {for each package:}
  {name}:
    path: {path}
    package: "@{project}/{name}"
    purpose: {purpose}
    entry: src/index.ts  # TODO: verify
    used_by: []  # TODO: list consuming apps

{if database from Q4:}
# ── DATABASE ─────────────────────────────────────────────────────────────────

database:
  schema: {schema path}
  migrations: {migrations path}
  seed: # TODO: add seed file path if applicable
  client_singleton: # TODO: add prisma/db client singleton path

{endif}
# ── CROSS-APP RELATIONSHIPS ───────────────────────────────────────────────────

relationships:
  # TODO: describe how apps share code or communicate
  # Example:
  # shared_ui:
  #   package: "@{project}/uikit"
  #   consumers: [apps/web]

# ── AI DOCUMENTATION ─────────────────────────────────────────────────────────

ai_docs:
  index: {aiDir}/INDEX.md
  features:
    manifest: {aiDir}/features/index.yaml
    dir: {aiDir}/features/
  memory:
    index: {aiDir}/memory/index.md
    procedural: {aiDir}/memory/procedural/index.md
    semantic: {aiDir}/memory/semantic/index.md
    episodic: {aiDir}/memory/episodic/index.md
    sessions: {aiDir}/memory/sessions/
  plans: {aiDir}/plans/
  conventions: {aiDir}/conventions/
  pre_flight: {aiDir}/pre-flight.md

# ── AGENT CONFIGURATION ──────────────────────────────────────────────────────

agent:
  entry: CLAUDE.md
  rules: .claude/rules/
  hooks: .claude/hooks/
  verification: .claude/verification.json
  worktrees: .claude/worktrees/  # TODO: remove if not using git worktrees

# ── BOUNDARIES ───────────────────────────────────────────────────────────────

boundaries:
  never_modify:
{if Q6 provided:}
{for each boundary:}
    - {boundary}
{else:}
    - .env
    - .env.*
    - "**/node_modules/"
    # TODO: add migration files, generated code dirs, etc.
  generated_do_not_edit:
    # TODO: list auto-generated files/dirs (e.g., codegen output, ORM client)

# ── CONVENTIONS ──────────────────────────────────────────────────────────────

conventions:
  # TODO: add project-specific conventions
  # Examples:
  # language: TypeScript strict mode throughout
  # tests:
  #   pattern: "*.test.ts"
  #   placement: co-located with source

# ── COMMANDS ─────────────────────────────────────────────────────────────────

commands:
{for each command from Q5:}
  {name}: "{command}"

# ── ROOT CONFIG ───────────────────────────────────────────────────────────────

root_config:
  # TODO: list key config files at project root
  # Examples:
  # eslint: eslint.config.js
  # prettier: .prettierrc
  # typescript: tsconfig.json
```

### Single-app template

Same as monorepo but without the `packages` section, no `relationships` section, and with a single entry under `apps` (or use a top-level `app` key instead).

## Output Location

Write to project root as `{filename from Q7}` (default: `backbone.yml`).

After writing the file, update `.myspec.json` by adding:
```json
"topologyFile": "{filename}"
```
