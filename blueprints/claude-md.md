# Blueprint: CLAUDE.md

## Purpose
Guide the user through creating a project-root CLAUDE.md that gives Claude Code the context it needs to work effectively in this codebase.

## Discovery Questions (ask one at a time)

1. "What is the project name and a one-line description?"

2. "What is the tech stack? (e.g., 'Vue 3 + TypeScript | GraphQL | Prisma | PostgreSQL')"

3. "What is the repository structure? Is it a monorepo? List the main directories and their purpose."

4. "Are there any active implementation plans the agent should follow? (e.g., a migration plan, a refactor in progress)"

5. "Are there additional task routing rules? (e.g., 'for auth changes, always read auth.md first', 'for database changes, check migration guide')"

6. "Any additional rules or principles the agent must follow in this project?" (or "skip" to finish)

## Output Format

Generate `CLAUDE.md` at project root with this structure:

```markdown
# {Project Name}

## Core Principles

1. **Retrieval-led reasoning**: Always read project docs before generating code
2. **Documentation is source of truth**: Read ${aiDir}/ docs before any implementation
3. **No code changes without explicit user request**
4. **Follow existing patterns**: Check similar features before creating new ones
5. **Follow active implementation plans** (see below)
{additional principles from user input}

## Quick Context

**Tech Stack**: {from user input}

**Repo Structure**:
{directory tree from user input}

## Active Implementation Plans

| Feature | Plan | Command |
|---------|------|---------|
{from user input, or "None currently" if none}

## Documentation Index

### Always Loaded (.claude/rules/)
{list of rule files if they exist}

### Features (${aiDir}/features/)
index.yaml (manifest) | {name}/spec.md | {name}/tech-spec.md | {name}/dependencies.md

### Architecture (${aiDir}/plans/)
{list based on what exists}

### Conventions (${aiDir}/conventions/)
coding-standards.md | testing.md | error-handling.md

### Complete Index
See `${aiDir}/INDEX.md` for full documentation map

## Task Routing

| Task | Read First |
|------|------------|
| **Any work** | `${aiDir}/memory-index.md` -> `${aiDir}/pre-flight.md` |
| New feature | `${aiDir}/features/index.yaml` -> `${aiDir}/workflow.md` |
| Feature work | `${aiDir}/features/{name}/spec.md` -> `tech-spec.md` |
{additional routing from user input}
```

## Output Location
Write to `CLAUDE.md` at the project root.
