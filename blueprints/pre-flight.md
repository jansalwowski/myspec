# Blueprint: Pre-Flight

## Purpose
Guide the user through creating project-specific pre-flight checks that supplement the universal framework pre-flight checklist.

## Framework Defaults (auto-included)
The framework section of pre-flight.md already includes universal checks. Do not ask about these again:
1. Always: read the memory index and check for existing sessions
2. Before Implementation: spec is approved, feature dependencies, memory index scan, anchor checks
3. Before Risky Changes: offer a commit before refactors and other risky edits
4. During Work: session file and session log
5. Escalation Triggers: when to stop and ask the user after repeated failed attempts
6. Completing Work: verify before claiming, close and archive the session

## Discovery Questions (ask one at a time)

1. "What verification commands should run before implementation? (e.g., lint, type-check, test commands — provide exact commands like `npm run lint`, `vendor/bin/phpstan analyse`, `ruff check .`, `go vet ./...`)"

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
