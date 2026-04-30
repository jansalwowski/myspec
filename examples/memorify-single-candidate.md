# memorify — single candidate from a debugging session

Simple sweep: one memorable thing happened, the skill surfaces it, the user approves.

## Setup

The user spent 45 minutes chasing a flaky test. The eventual root cause: the test was creating users via the Prisma client directly, bypassing the auth service that normally sets a default `tenant_id`. Once they switched to the factory, it passed. The fix is in the diff, but the *lesson* (don't bypass the auth service in tests) isn't.

## Invocation

```
/memorify
```

## Skill flow

### 1. Sweep

The agent re-reads the recent turns and identifies one strong candidate. The flaky-test diagnosis itself is in the diff and not worth saving. The *rule* — always go through the auth service factory — is.

### 2. Candidate list

```
I found 1 thing worth saving from this session:

  1. The rule that test users should be created through the auth-service
     factory, not directly via Prisma — bypassing it skips tenant_id
     defaults and produces flaky tests.

Which should I capture? Reply with the numbers (e.g. "1"), "all", or "none".
```

**User:**

```
1
```

### 3. Targeted question

*(Silent classification: actionable rule → **procedural**, polarity positive.)*

The skill needs a clear `not_for`:

> "Got it. Is there any test scenario where creating users directly via Prisma is still the right call — for example, tests that exercise the data layer itself?"

**User:**

```
yeah, repository-layer tests that explicitly want to bypass the service should still go straight to prisma
```

### 4. Draft

```markdown
---
id: P016
type: procedural
polarity: positive
triggers: [test, factory, user, tenant_id, prisma, auth-service]
not_for:
  - repository-layer tests that intentionally bypass the auth service
  - migration / data-fix scripts (not tests)
anchors:
  - file: tests/factories/user.ts
    pattern: "createUser"
validated: 2026-04-30
---

# Create test users through the auth-service factory

## Procedure (Do This)
In application and integration tests, create users via
`tests/factories/user.ts::createUser()`, which routes through the
auth service. Do not call `prisma.user.create()` directly.

## Why This Works
The auth service applies tenant defaults (`tenant_id`, role
defaults, audit fields) that the rest of the app assumes are
present. Going through the factory keeps tests aligned with what
production code sees.

## What Fails
Direct `prisma.user.create()` calls produce users with NULL
`tenant_id`. Code paths that filter by tenant skip those rows
non-deterministically depending on test ordering, surfacing as
flakes that look unrelated to user creation.

## Verification
Grep tests for `prisma.user.create` — outside of repository-layer
tests, there should be no hits.
```

**Proposed index row:**

```
| P016 | test, factory, user, tenant_id | 2026-04-30 |
```

> Save this one? **yes** to write, **edit** with changes, or **skip**.

### 5. User confirms

```
yes
```

## Result

- Wrote `${aiDir}/memory/procedural/P016-test-user-factory.md`.
- Appended row to `${aiDir}/memory/procedural/index.md`.
- No Layer 1 promotion — the rule is local to the test layer.
- Final tally: **Saved 1 memory: P016. Skipped 0.**

## Why this example matters

This is the **mode you'll use most often** — finish a task, run `/memorify`, save the one lesson the diff doesn't capture, move on. The skill correctly **discarded** the bug-fix narrative itself (visible in the commit) and kept only the reusable rule.
