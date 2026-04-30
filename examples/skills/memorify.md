# `/myspec:memorify` — examples

`/memorify` sweeps the recent conversation, surfaces things worth remembering, and (after per-candidate confirmation) writes them as memories. A single run can produce zero, one, or many memories. Each section below shows a different shape of run.

**Contents**

- [Single candidate from a debugging session](#single-candidate-from-a-debugging-session) — one memory surfaces, standard happy path
- [Multiple candidates with cross-links](#multiple-candidates-with-cross-links) — three memories, mixed types, `related` linking, partial Layer 1 promotion
- [Nothing worth saving](#nothing-worth-saving) — sweep yields zero (a valid outcome)

In every scenario, the internal classification (*procedural / semantic / episodic*) is shown in *italic side-notes* so you can see how the skill reasons. In real usage those terms never reach the user.

---

## Single candidate from a debugging session

Simple sweep: one memorable thing happened, the skill surfaces it, the user approves.

### Setup

The user spent 45 minutes chasing a flaky test. The eventual root cause: the test was creating users via the Prisma client directly, bypassing the auth service that normally sets a default `tenant_id`. Once they switched to the factory, it passed. The fix is in the diff, but the *lesson* (don't bypass the auth service in tests) isn't.

### Invocation

```
/memorify
```

### Skill flow

#### 1. Sweep

The agent re-reads the recent turns and identifies one strong candidate. The flaky-test diagnosis itself is in the diff and not worth saving. The *rule* — always go through the auth service factory — is.

#### 2. Candidate list

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

#### 3. Targeted question

*(Silent classification: actionable rule → **procedural**, polarity positive.)*

The skill needs a clear `not_for`:

> "Got it. Is there any test scenario where creating users directly via Prisma is still the right call — for example, tests that exercise the data layer itself?"

**User:**

```
yeah, repository-layer tests that explicitly want to bypass the service should still go straight to prisma
```

#### 4. Draft

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

#### 5. User confirms

```
yes
```

### Result

- Wrote `${aiDir}/memory/procedural/P016-test-user-factory.md`.
- Appended row to `${aiDir}/memory/procedural/index.md`.
- No Layer 1 promotion — the rule is local to the test layer.
- Final tally: **Saved 1 memory: P016. Skipped 0.**

### Why this example matters

This is the **mode you'll use most often** — finish a task, run `/memorify`, save the one lesson the diff doesn't capture, move on. The skill correctly **discarded** the bug-fix narrative itself (visible in the commit) and kept only the reusable rule.

---

## Multiple candidates with cross-links

A long, productive session that produced several lessons. Demonstrates per-candidate confirmation, mixed types, partial selection, and cross-linking with `related`.

### Setup

The user just shipped a webhook integration with Stripe. Across the conversation:

- They discovered Stripe's webhook signing secret rotates per environment and that the staging secret had drifted out of sync (caused 4 hours of confusion).
- The agent originally suggested verifying signatures inside the controller; the user redirected: signature verification belongs in middleware so unsigned requests never reach business logic.
- They decided to keep the raw request body in audit logs for 90 days for replay debugging — chose 90 days because Stripe's max retry window is 3 days but compliance asked for the buffer.
- They renamed `webhook_events` to `stripe_events` mid-PR to make room for upcoming GitHub webhooks.

The rename is in the diff. The other three are not.

### Invocation

```
/memorify
```

### Skill flow

#### 1. Candidate list

```
I found 3 things worth saving from this session:

  1. The rule that webhook signature verification belongs in middleware,
     not in controllers — unsigned requests should never reach business
     logic.
  2. The fact that Stripe's webhook signing secret is per-environment,
     and staging vs prod drift caused a 4-hour outage today.
  3. The decision to retain raw webhook bodies for 90 days, driven by
     compliance + Stripe's 3-day retry window.

(I'm skipping the table rename — it's already in the diff.)

Which should I capture? Reply with the numbers (e.g. "1 and 3"),
"all", or "none".
```

**User:**

```
all
```

#### 2. Per-candidate clarifications

The skill processes the three sequentially.

**Candidate 1 — middleware rule** *(Silent: procedural, positive.)*

> "Any case where putting verification inside a controller is still acceptable — for example, a one-off endpoint with non-Stripe semantics?"

**User:**

```
no, all webhook endpoints go through the middleware. controllers should assume the signature is already verified.
```

**Candidate 2 — per-env signing secret** *(Silent: semantic — stable fact about Stripe + our deploy.)*

> "Is there a config file or secrets reference I can point at so a future check can verify this is still set up correctly?"

**User:**

```
infra/secrets/stripe.yaml — keys are STRIPE_WEBHOOK_SECRET_STAGING and STRIPE_WEBHOOK_SECRET_PROD
```

**Candidate 3 — 90-day retention** *(Silent: episodic — dated decision with a compliance driver.)*

> "Was 90 days a hard compliance number, or is there flexibility if storage cost becomes a concern?"

**User:**

```
compliance asked for 30 minimum, we picked 90 to give ourselves breathing room. so flexible down to 30, hard floor.
```

#### 3. Drafts (one at a time)

The skill renders each draft and waits for **yes / edit / skip** before moving on.

**Draft 1 — `P017-webhook-signature-in-middleware.md`**

```markdown
---
id: P017
type: procedural
polarity: positive
triggers: [webhook, signature, middleware, stripe, verification]
not_for: []
anchors:
  - file: app/middleware/verify-webhook-signature.ts
    pattern: "verifySignature"
related: [S008, E010]
validated: 2026-04-30
---

# Verify webhook signatures in middleware, not controllers

## Procedure (Do This)
All inbound webhook routes mount the signature-verification
middleware. Controllers handling webhooks may assume the signature
is already valid and the raw body has been preserved on the
request object.

## Why This Works
Centralizing verification means an unsigned or replayed request
gets a 401 before any business logic runs. It's easier to audit
("does every webhook route have the middleware?") than to grep
controllers for verify calls.

## What Fails
If verification lives in controllers, one missed call quietly
opens an unauthenticated endpoint. The middleware approach turns
that class of bug into a routing mistake instead of a logic
mistake.

## Verification
Every route under `routes/webhooks/*` should have the middleware
in its chain. Add a test that asserts a 401 on an unsigned POST.
```

> Save this one? **yes** / **edit** / **skip**

`yes` → written.

**Draft 2 — `S008-stripe-webhook-secret-per-env.md`**

```markdown
---
id: S008
type: semantic
topic: stripe
anchor:
  file: infra/secrets/stripe.yaml
  pattern: "STRIPE_WEBHOOK_SECRET_"
related: [P017, E010]
verified: 2026-04-30
---

# Stripe webhook signing secret is per-environment

Stripe issues a separate webhook signing secret for each endpoint
configuration. Staging and production have distinct secrets that
must not be reused across environments.

## Source
`infra/secrets/stripe.yaml` —
`STRIPE_WEBHOOK_SECRET_STAGING` and `STRIPE_WEBHOOK_SECRET_PROD`.

## Implication
Rotating one environment's secret in the Stripe dashboard does
not affect the other. When secrets drift (e.g. someone updates
prod but not staging), staging webhooks 401 with no obvious
cause. Treat secret rotations as paired changes.
```

> Save this one? **yes** / **edit** / **skip**

`yes` → written.

**Draft 3 — `E010-webhook-body-retention-90d.md`**

```markdown
---
id: E010
type: episodic
date: 2026-04-30
outcome: success
persistent: false
feature: stripe-webhooks
related: [P017, S008]
verified: 2026-04-30
---

# Retain raw webhook bodies for 90 days

## Context
Stripe retries failed webhook deliveries for up to 3 days.
Compliance review asked for a minimum 30-day retention of inbound
webhook payloads for audit and replay.

## Decision
We retain the raw HTTP body of every Stripe webhook for **90
days** in the audit log table. 30 days is the hard floor;
anything below requires re-engaging compliance.

## Outcome
Storage cost projected to be negligible at current webhook
volume. Replay tooling now has 90 days of payloads to draw from.

## Consequence
- A retention job purges audit log rows older than 90 days.
- Don't drop the retention below 30 days without compliance
  sign-off.
- If volume grows enough to make 90 days expensive, the lever to
  pull is "shorten retention toward 30," not "stop storing
  bodies."
```

> Save this one? **yes** / **edit** / **skip**

`yes` → written.

#### 4. Cross-linking

After all three are written, the skill edits each file's `related:` field so they reference the others (already shown in the drafts above for clarity — in practice the linking happens after all approvals).

#### 5. Layer 1 promotion

The agent flags one of these as a candidate for the always-loaded index — Candidate 1 (the middleware rule) — because misapplying it is a security issue. It asks:

> "Want the middleware rule (P017) in the always-loaded index so it shows up every session?"

**User:**

```
yes
```

A one-line summary lands in `${aiDir}/memory/index.md` under **Rules**.

### Result

- Wrote `${aiDir}/memory/procedural/P017-webhook-signature-in-middleware.md`.
- Wrote `${aiDir}/memory/semantic/S008-stripe-webhook-secret-per-env.md`.
- Wrote `${aiDir}/memory/episodic/E010-webhook-body-retention-90d.md`.
- All three index files updated, `updated: 2026-04-30` bumped.
- P017 promoted to Layer 1.
- Final tally: **Saved 3 memories: P017, S008, E010. Skipped 0.**

### Why this example matters

- Three different types from one conversation, classified silently.
- The skill **filtered out** the table rename (already in the diff) — important: the bar for saving is "non-obvious from code/git", not "happened recently."
- **Per-candidate confirmation** lets the user veto any single one without aborting the whole run.
- **Cross-linking via `related`** lets the next agent pull the whole cluster when any one of them surfaces in a search.

---

## Nothing worth saving

Sometimes the right answer is "no memory." This section demonstrates the skill stopping cleanly instead of forcing a save.

### Setup

The user spent the session renaming a few CSS classes for visual consistency, fixing two typos in copy, and bumping a minor dependency. No surprises, no corrections, no decisions — pure cleanup work that's fully captured in the diff.

### Invocation

```
/memorify
```

### Skill flow

#### 1. Sweep

The agent re-reads the conversation looking for:

- Reusable rules → none.
- Non-obvious facts → none; the renames are mechanical.
- Decisions or events → none; no architectural choice was made.
- User corrections → none; the user accepted every change as proposed.
- Validated approaches → nothing surprising; the changes were exactly what the diff implies.

Everything actionable from this session is *already* visible to a future agent reading the file or `git log`.

#### 2. Reports back honestly

```
Nothing in this conversation feels worth remembering. The CSS renames,
typo fixes, and dep bump are all visible in the diff and don't carry
hidden context. No memory written.
```

The skill stops.

### Result

- No files written.
- No index changes.
- Final tally: **Saved 0 memories. Skipped 0.**

### Why this example matters

This is a deliberately **boring** example, and the lesson is exactly that:

- A "successful" `/memorify` run can write **zero** memories. The skill is allowed — encouraged — to say "nothing here."
- Forcing a memory in a session like this would either restate the diff (useless) or invent a "lesson" the user didn't actually internalize (worse than useless: it pollutes future searches).
- The bar for memory is **non-obvious + reusable**. Mechanical work that any future agent can re-derive by reading code doesn't clear it.

If you find `/memorify` consistently returns nothing on your work, that's not a bug — it means your sessions are mostly direct execution. Save `/memorify` for sessions that involved corrections, surprises, or decisions.
