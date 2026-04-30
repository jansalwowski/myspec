# memorify — multiple candidates with cross-links

A long, productive session that produced several lessons. Demonstrates per-candidate confirmation, mixed types, partial selection, and cross-linking with `related`.

## Setup

The user just shipped a webhook integration with Stripe. Across the conversation:

- They discovered Stripe's webhook signing secret rotates per environment and that the staging secret had drifted out of sync (caused 4 hours of confusion).
- The agent originally suggested verifying signatures inside the controller; the user redirected: signature verification belongs in middleware so unsigned requests never reach business logic.
- They decided to keep the raw request body in audit logs for 90 days for replay debugging — chose 90 days because Stripe's max retry window is 3 days but compliance asked for the buffer.
- They renamed `webhook_events` to `stripe_events` mid-PR to make room for upcoming GitHub webhooks.

The rename is in the diff. The other three are not.

## Invocation

```
/memorify
```

## Skill flow

### 1. Candidate list

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

### 2. Per-candidate clarifications

The skill processes the three sequentially.

#### Candidate 1 — middleware rule

*(Silent: procedural, positive.)*

> "Any case where putting verification inside a controller is still acceptable — for example, a one-off endpoint with non-Stripe semantics?"

**User:**

```
no, all webhook endpoints go through the middleware. controllers should assume the signature is already verified.
```

#### Candidate 2 — per-env signing secret

*(Silent: semantic — stable fact about Stripe + our deploy.)*

> "Is there a config file or secrets reference I can point at so a future check can verify this is still set up correctly?"

**User:**

```
infra/secrets/stripe.yaml — keys are STRIPE_WEBHOOK_SECRET_STAGING and STRIPE_WEBHOOK_SECRET_PROD
```

#### Candidate 3 — 90-day retention

*(Silent: episodic — dated decision with a compliance driver.)*

> "Was 90 days a hard compliance number, or is there flexibility if storage cost becomes a concern?"

**User:**

```
compliance asked for 30 minimum, we picked 90 to give ourselves breathing room. so flexible down to 30, hard floor.
```

### 3. Drafts (one at a time)

The skill renders each draft and waits for **yes / edit / skip** before moving on.

#### Draft 1 — `P017-webhook-signature-in-middleware.md`

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

#### Draft 2 — `S008-stripe-webhook-secret-per-env.md`

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

#### Draft 3 — `E010-webhook-body-retention-90d.md`

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

### 4. Cross-linking

After all three are written, the skill edits each file's `related:` field so they reference the others (already shown in the drafts above for clarity — in practice the linking happens after all approvals).

### 5. Layer 1 promotion

The agent flags one of these as a candidate for the always-loaded index — Candidate 1 (the middleware rule) — because misapplying it is a security issue. It asks:

> "Want the middleware rule (P017) in the always-loaded index so it shows up every session?"

**User:**

```
yes
```

A one-line summary lands in `${aiDir}/memory/index.md` under **Rules**.

## Result

- Wrote `${aiDir}/memory/procedural/P017-webhook-signature-in-middleware.md`.
- Wrote `${aiDir}/memory/semantic/S008-stripe-webhook-secret-per-env.md`.
- Wrote `${aiDir}/memory/episodic/E010-webhook-body-retention-90d.md`.
- All three index files updated, `updated: 2026-04-30` bumped.
- P017 promoted to Layer 1.
- Final tally: **Saved 3 memories: P017, S008, E010. Skipped 0.**

## Why this example matters

- Three different types from one conversation, classified silently.
- The skill **filtered out** the table rename (already in the diff) — important: the bar for saving is "non-obvious from code/git", not "happened recently."
- **Per-candidate confirmation** lets the user veto any single one without aborting the whole run.
- **Cross-linking via `related`** lets the next agent pull the whole cluster when any one of them surfaces in a search.
