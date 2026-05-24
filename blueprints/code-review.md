# Blueprint: Code Review

## Purpose
Configure the `/myspec:code-review` reviewer for this project — set its goals, the standards it enforces, what it should stay silent about, and its default run behavior. The reviewer's dimensions are universal; this blueprint captures everything repo-specific.

## Discovery Questions (ask one at a time)

### Goals & Emphasis

1. "What should code review focus on most in this repo? Rank or pick the top concerns (e.g. correctness, security, performance, maintainability, test coverage, API/contract stability)."

2. "Are there areas that need stricter scrutiny than others? (e.g. 'anything under src/payments/** or auth/**')" (or "skip")

### Standards (positive rules)

3. "What project-specific standards should the reviewer enforce? Phrase as rules, scope to paths where it helps. Examples:
   - 'Repository methods must handle the not-found case explicitly.'
   - 'In src/api/**: every handler validates its request body before use.'
   - 'Public functions need a doc comment.'
   (List as many as you like, or 'skip'.)"

4. "Any naming, structure, or pattern conventions the reviewer should hold code to that aren't already in your linter or `${aiDir}/conventions/`?" (or "skip")

### Suppress (stay silent)

5. "What should the reviewer NOT comment on — owned by tooling or intentional in this repo? Examples:
   - 'Formatting and import order — the linter owns it.'
   - 'console logging in scripts/**.'
   - 'Test files under **/*.test.* for coverage of the tests themselves.'
   (List items, or 'skip'.)"

### Run Behavior

6. "How noisy should reviews be by default?
   - `chill` — only blocking issues (Critical + High)
   - `standard` — Critical + High + Medium (recommended default)
   - `thorough` — everything, including minor polish"

7. "What should the reviewer look at by default when run with no arguments?
   - `feature` — the current feature branch's changes (recommended)
   - `working` — uncommitted changes only
   - `ask` — prompt for scope each run"

8. "Should the reviewer ever apply fixes automatically?
   - `off` — only propose fixes, never apply without asking (recommended)
   - `style-only` — auto-apply mechanical fixes (rename, dead-code, obvious guards); still confirm behavior changes"

## Output Format

### `.claude/rules/code-review.md` (required)

```markdown
# Code Review Rules

Project-specific rules for `/myspec:code-review`. The reviewer's universal
dimensions (correctness, error handling, input/trust, resources, maintainability,
tests, consistency, YAGNI) always apply — this file adds repo-specific intent.

## Focus
<one or two lines from Q1–Q2: what matters most, which paths get extra scrutiny>

## Standards
<each rule from Q3–Q4 as a bullet; scope to paths in prose where given>
- ...

## Suppress
<each item from Q5 as a bullet>
- ...
```

If the user answers "skip" to a whole section, omit that section's bullets but keep the header with a one-line note (e.g. "- (none configured)").

## Post-generation

After writing `.claude/rules/code-review.md`, update `.myspec.json` — add or update the `codeReview` block from Q6–Q8:

```json
{
  "codeReview": {
    "verbosity": "<Q6 answer>",
    "scope": "<Q7 answer>",
    "autoFix": "<Q8 answer>"
  }
}
```

## Output Location
- `.claude/rules/code-review.md` (project root `.claude/rules/`)
- `.myspec.json` `codeReview` block (project root)
