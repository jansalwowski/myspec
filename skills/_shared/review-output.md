# Review Output Conventions

Shared format for all review skills (feature-spec-review, feature-tech-spec-review, feature-implement-review, skill-verify). Each skill defines its own severity *definitions* and gate ("must fix before") — the output shapes below are common.

## Findings Table

One row per finding, grouped Critical → High → Medium → Low:

```markdown
| Severity | Dimension | Issue | File | Line(s) | Finding |
|----------|-----------|-------|------|---------|---------|
| High | {dimension} | {short issue} | {file} | {n-m or —} | {one-sentence finding with the concrete evidence} |
```

(skill-verify reviews a single file — it uses `Category` for `Dimension` and drops the `File` column.)

## Fix Proposals

One block per proposed fix:

```markdown
## Fix {N}: {short title} ({Severity}) [auto-fix | requires confirmation]

**File**: {file}:{lines}
**Issue**: {one sentence}

- {current text/code}
+ {proposed text/code}

**Rationale**: {one sentence — why this fix, not what it does}
```

## Tagging and application rules

This is the one definition of `[auto-fix]` for every review skill. A skill may list its own examples, never a wider scope.

- `[auto-fix]` — mechanical, meaning-preserving (typos, formatting, frontmatter dates, an empty heading for a missing required section): apply immediately without asking.
- `[requires confirmation]` — anything changing meaning, scope, structure, or strategy: show the proposal and WAIT for explicit approval. Adding content (an edge case, a requirement, a step, a file inventory row) or rewording unclear text changes meaning, so it belongs here. When in doubt, use this tag. End such proposals with `**ACTION REQUIRED**: Confirm or reject before proceeding.`
- Never downgrade a severity to make a verdict look cleaner.
- Findings without a locatable line use `—` in Line(s), never a guessed number.
