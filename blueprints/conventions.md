# Blueprint: Conventions

## Purpose
Guide the user through creating project-specific coding conventions, testing standards, and error handling patterns.

## Discovery Questions (ask one at a time)

### Coding Standards

1. "What programming languages and frameworks does this project use? (e.g., 'TypeScript + React', 'Python + Django', 'Go + gRPC')"

2. "What are your naming conventions? Cover:
   - File names (kebab-case, camelCase, PascalCase?)
   - Classes/components
   - Functions/methods
   - Variables/constants
   - Database tables/columns (if applicable)"

3. "How is code organized? What directories hold what? (e.g., 'services/ for business logic, controllers/ for HTTP handlers, models/ for data')"

4. "What error handling approach do you use? (e.g., custom error classes, error codes, Result types, try/catch patterns)"

### Testing

5. "What test framework do you use? What's the test file naming convention? (e.g., 'Vitest, *.test.ts next to source files')"

6. "What are your testing requirements? (e.g., 'unit tests for all services', 'integration tests for API routes', 'minimum coverage percentage')"

### Code Review

7. "Any code review expectations the agent should follow? (e.g., 'never submit files over 300 lines', 'always add JSDoc to public functions')" (or "skip" to finish)

## Output Format

### coding-standards.md
Generate with sections:
- Naming Conventions (table format)
- File Organization (directory tree)
- Code Style Rules (bulleted list)
- Import Order (if applicable)

### testing.md (optional — generate if user provides testing details)
Generate with sections:
- Test Framework & Setup
- File Naming & Organization
- Test Structure (describe/it patterns, arrange/act/assert)
- Coverage Requirements
- What to Test (happy paths, edge cases, security)

### error-handling.md (optional — generate if user provides error handling details)
Generate with sections:
- Error Classes / Types
- Error Handling Patterns
- Error Response Format
- Logging Requirements

## Output Location
Write to `${aiDir}/conventions/coding-standards.md` (required).
Optionally write `${aiDir}/conventions/testing.md` and `${aiDir}/conventions/error-handling.md`.
