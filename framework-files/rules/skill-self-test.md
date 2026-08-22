---
title: "Skill Self-Test Reference"
purpose: "The optional dependencies: frontmatter field and how to sweep skills for dependency drift"
paths:
  - .claude/skills/**
updated: 2026-08-22
---

# Skill Self-Test

A skill whose body or description names a library or filesystem path is making a claim that the library is installed / the path exists. When that claim goes stale (dependency removed, file renamed), the skill silently emits non-compiling or non-functional output. The `dependencies:` field makes the claim checkable.

## The `dependencies:` field

Optional, Convention tier (ignored by agents — only tooling reads it). Declare what the skill assumes:

```yaml
dependencies:
  packages:
    - "@vuelidate/core"        # must appear in some package.json under the repo
  paths:
    - apps/web/src/composables/useFormState.ts   # must exist on disk
```

- `packages`: each must appear as a key in some `package.json` under the project root.
- `paths`: repo-relative; each must exist in the working tree.
- Explicit only — do not list transitive deps.

`/myspec:skill-verify` step 4.5 validates the block: a missing package or path is a **Critical** finding (never auto-fixed — the fix is human judgment: install the dependency, or repair/delete the skill).

## Sweep recipe (no separate skill)

When auditing all skills at once, do NOT run one verification in a single conversation — context balloons and the signal degrades. Instead:

1. List every skill whose `SKILL.md` has a `dependencies:` block.
2. Dispatch one Agent per skill (clean context). Each agent runs `/myspec:skill-verify <skill-name>` against that single skill and reports pass/fail.
3. The controller aggregates the pass/fail set; it does not re-derive the findings.

Per-skill subagent isolation keeps each verification in a focused context window and lets the sweep parallelize.

## When to add the field

Add `dependencies:` opportunistically when touching a skill that references a concrete package or path. There is no requirement to backfill every skill at once; the field is dormant until declared, and the verifier only checks skills that opt in.
