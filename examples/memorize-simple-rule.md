# memorize — simple procedural rule

The smallest useful flow: user states a clear rule, the skill captures it with one round of confirmation.

## Setup

Earlier in the conversation, the user noticed Claude forgot to regenerate Prisma types after a schema change. They want to lock the habit in.

## Invocation

```
/memorize after editing prisma/schema.prisma always run pnpm db:generate before continuing
```

## Skill flow

*(Silent classification: rule → **procedural**, polarity positive, trigger is editing the schema file.)*

The skill has enough to draft directly — no clarifying questions needed.

**Agent renders the draft:**

```markdown
---
id: P014
type: procedural
polarity: positive
triggers: [prisma, schema, db:generate, pnpm]
not_for: [migrations-only changes that don't touch the schema file]
anchors:
  - file: prisma/schema.prisma
    pattern: "^model "
validated: 2026-04-30
---

# Regenerate Prisma client after schema edits

## Procedure (Do This)
After any edit to `prisma/schema.prisma`, run `pnpm db:generate` before
continuing with implementation or running tests.

## Why This Works
Prisma's TypeScript client is generated from the schema. Stale types
silently compile but fail at runtime when the new column is queried.

## What Fails
Skipping the regen leaves IDE autocomplete and `tsc` agreeing with the
old shape, so type errors only appear in test runs or production.

## Verification
`pnpm db:generate` exits 0 and `node_modules/.prisma/client` mtime
updates.
```

**Proposed index row** (`memory/procedural/index.md`):

```
| P014 | prisma, schema, db:generate | 2026-04-30 |
```

> Save this? Reply **yes** to write it, or tell me what to change.

## User confirms

```
yes
```

## Result

- Wrote `${aiDir}/memory/procedural/P014-regenerate-prisma-client.md`.
- Appended row to `${aiDir}/memory/procedural/index.md` and bumped `updated: 2026-04-30`.
- No Layer 1 promotion offered — the rule is useful but not session-critical.

## Why this example matters

Demonstrates the **happy path**: user input is unambiguous, the skill infers all required fields, asks zero clarifying questions, and ships in one round-trip.
