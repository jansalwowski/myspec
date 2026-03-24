# Blueprint: Pre-Flight

## Purpose
Guide the user through creating project-specific pre-flight checks that supplement the universal framework pre-flight checklist.

## Framework Defaults (auto-included)
The framework section of pre-flight.md already includes universal checks:
1. Read anti-patterns before starting
2. Check active implementation plans
3. Verify task routing (read correct docs first)
4. Confirm scope with user before implementation

## Discovery Questions (ask one at a time)

1. "What verification commands should run before implementation? (e.g., lint, type-check, test commands — provide exact commands like `npm run lint`, `pnpm type-check`)"

2. "What environment checks are needed before starting work? (e.g., env vars that must be set, services that must be running, database state requirements)"

3. "Are there feature-flag or deployment considerations the agent should check before making changes?"

4. "Any manual checks specific to this project? (e.g., 'check if the dev server is already running', 'verify you are on the correct branch')"

5. "What should the agent verify after implementation? (e.g., 'run the full test suite', 'check for TypeScript errors', 'verify no console.log statements')" (or "skip" to finish)

## Output Format
Generate entries under the `<!-- myspec:project-start -->` section:

### Before Implementation

| # | Check | Command / Action | Why |
|---|-------|-----------------|-----|
| PC1 | [check name] | `[command]` or [manual action] | [why it matters] |

### After Implementation

| # | Check | Command / Action | Why |
|---|-------|-----------------|-----|
| PC1 | [check name] | `[command]` or [manual action] | [why it matters] |

## Output Location
Write to `${aiDir}/pre-flight.md` — append to existing project section if file exists.
