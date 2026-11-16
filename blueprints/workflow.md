# Blueprint: Workflow

## Purpose
Guide the user through creating a project-specific development workflow that defines code generation policies, feature workflow phases, and documentation requirements.

## Discovery Questions (ask one at a time)

1. "What should require explicit user instruction before the agent does it? (Default: writing/modifying source code, creating components, database migrations. Anything else?)"

2. "What should the agent always be allowed to do without asking? (Default: reading code, answering questions, creating/updating docs in the AI directory. Anything else?)"

3. "Do you want the full feature workflow (feature-spec → feature-spec-review → feature-tech-spec → feature-tech-spec-review → feature-plan → feature-implement → feature-complete) or a simplified version? Any customizations to the phases?"

4. "What documentation should be required for different change types? For example:
   - New feature -> feature spec
   - Database change -> migration notes
   - API change -> API docs update
   - Bug fix -> nothing extra"

5. "Any project-specific workflow rules? (e.g., 'always create a branch before starting work', 'run migrations after schema changes')" (or "skip" to finish)

## Output Format

Generate `${aiDir}/workflow.md` with this structure:

```markdown
# Development Workflow

## Code Generation Policy

### Requires Explicit User Instruction
- Writing new source code files
- Modifying existing source code
- Creating components, functions, modules
- Any changes outside `${aiDir}/` and `docs/`
{additional items from user input}

**Triggers:** "implement this", "write the code", "create the file", "make these changes"

### Always Allowed
- Reading and analyzing code
- Answering questions
- Creating/updating documentation in `${aiDir}/` or `docs/`
- Proposing plans
- Research and exploration
{additional items from user input}

## Feature Workflow

| Phase | When | Skill |
|-------|------|-------|
| 1. Specification | Starting new feature | `/myspec:feature-spec` |
| 1a. Decompose | Feature too large for single tech-spec | `/myspec:feature-decompose` |
| 1b. Review | Validate spec before tech-spec | `/myspec:feature-spec-review` |
| 2. Technical Design | Spec approved, ready to plan implementation | `/myspec:feature-tech-spec` |
| 2a. Review | Validate tech-spec before implementation | `/myspec:feature-tech-spec-review` |
| 3. Implementation Plan | Tech-spec approved, ready to create tasks | `/myspec:feature-plan` |
| 4. Execution | Implementation plan approved, ready to build | `/myspec:feature-implement` |
| 5. Feature Completion | All tasks done, tests pass | `/myspec:feature-complete` |

> **Pipeline:** `feature-spec` → `feature-spec-review` → `feature-tech-spec` → `feature-tech-spec-review` → `feature-plan` → `feature-implement` → `feature-complete`
> **Modification:** `feature-update` → `feature-plan` → `feature-implement` → `feature-complete`
> **Optional:** `/myspec:feature-decompose` (large features), `/myspec:feature-spec scenarios` (test scenarios)

{customizations from user input}

## Documentation Requirements

| Change Type | Documentation Location |
|-------------|----------------------|
| New feature | `${aiDir}/features/{feature}/` |
| Feature changes | Update `${aiDir}/features/{feature}/` |
{additional mappings from user input}
```

## Output Location
Write to `${aiDir}/workflow.md`.
