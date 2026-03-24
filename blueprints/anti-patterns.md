# Blueprint: Anti-Patterns

## Purpose
Guide the user through creating project-specific anti-patterns that supplement the universal framework anti-patterns.

## Framework Defaults (auto-included)
The framework section of anti-patterns.md already includes universal patterns:
1. Description leakage (workflow details in skill descriptions)
2. Conceptual over procedural (explanations instead of commands)
3. Ambiguous decisions (no clear accept/reject criteria)
4. Missing negative triggers (skills without "Do NOT use for")
5. Verification gap (no explicit pass/fail commands)

## Discovery Questions (ask one at a time)

1. "What recurring mistakes do AI agents make in this codebase? For example: using wrong patterns, touching files they shouldn't, choosing wrong approaches."

2. "Are there areas of the codebase the agent should never modify directly? (e.g., 'never edit migration files directly', 'never modify the auth module without review')"

3. "What framework-specific gotchas exist? (e.g., React hooks rules, Rails N+1 queries, Laravel facade misuse)"

4. "Are there architectural patterns the agent must follow? (e.g., 'always use service classes, never put logic in controllers')"

5. "Any other anti-patterns from past experience with AI agents?" (or "skip" to finish)

## Output Format
Generate entries under the `<!-- myspec:project-start -->` section:

### Project Anti-Patterns

| # | Pattern | Why | Detection |
|---|---------|-----|-----------|
| AP1 | [pattern name] | [why it's harmful] | [how to detect it] |

## Output Location
Write to `${aiDir}/anti-patterns.md` — append to existing project section if file exists.
