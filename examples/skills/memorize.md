# `/myspec:memorize` — examples

`/memorize` is the single-shot capture skill: the user hands over the exact thing to remember, and the skill turns it into a properly-classified memory entry. Each section below is a different scenario, ordered from simplest to most involved.

**Contents**

- [Simple procedural rule](#simple-procedural-rule) — zero-question happy path
- [Semantic fact with anchor](#semantic-fact-with-anchor) — one targeted question to capture a re-verification anchor
- [Anti-pattern (negative polarity)](#anti-pattern-negative-polarity) — "never do this" with explicit `not_for` carve-outs
- [Critical decision with Layer 1 promotion](#critical-decision-with-layer-1-promotion) — episodic memory pinned to the always-loaded index

In every scenario, the internal classification (*procedural / semantic / episodic*) is shown in *italic side-notes* so you can see how the skill reasons. In real usage those terms never reach the user.

---

## Simple procedural rule

The smallest useful flow: user states a clear rule, the skill captures it with one round of confirmation.

### Setup

Earlier in the conversation, the user noticed Claude forgot to regenerate Prisma types after a schema change. They want to lock the habit in.

### Invocation

```
/memorize after editing prisma/schema.prisma always run pnpm db:generate before continuing
```

### Skill flow

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

### User confirms

```
yes
```

### Result

- Wrote `${aiDir}/memory/procedural/P014-regenerate-prisma-client.md`.
- Appended row to `${aiDir}/memory/procedural/index.md` and bumped `updated: 2026-04-30`.
- No Layer 1 promotion offered — the rule is useful but not session-critical.

### Why this example matters

Demonstrates the **happy path**: user input is unambiguous, the skill infers all required fields, asks zero clarifying questions, and ships in one round-trip.

---

## Semantic fact with anchor

Capture a stable fact about a system. The interesting bit: the skill asks one targeted question to get an anchor so the fact can be re-verified later.

### Setup

The user just finished investigating why a Redis-backed cache silently dropped large session blobs. They learned the cluster has a 512-byte key limit configured at the proxy layer.

### Invocation

```
/memorize our redis cluster rejects keys longer than 512 bytes — it's a proxy-level limit, not a redis default
```

### Skill flow

*(Silent classification: stable fact about an environment → **semantic**.)*

The input is a clear fact, but there's no code reference yet. The skill asks one question:

> "Is there a file or config I can point to so a future check can re-verify this is still true?"

**User answers:**

```
yeah, infra/redis/proxy.conf — the key_max_length directive
```

**Agent renders the draft:**

```markdown
---
id: S007
type: semantic
topic: redis
anchor:
  file: infra/redis/proxy.conf
  pattern: "key_max_length"
verified: 2026-04-30
---

# Redis key length capped at 512 bytes by proxy

The Redis cluster enforces a 512-byte maximum key length at the proxy
layer, not in Redis itself. Keys longer than this are silently
rejected by the proxy before reaching Redis.

## Source
`infra/redis/proxy.conf` — `key_max_length` directive.

## Implication
Session keys, cache namespaces, and any composed keys (e.g.
`tenant:{uuid}:user:{uuid}:cart`) must stay under 512 bytes including
the namespace prefix. Use hashed keys for anything user-controlled.
```

**Proposed index row** (`memory/semantic/index.md`):

```
| S007 | redis, key-length, proxy | 2026-04-30 |
```

> Save this? Reply **yes** to write it, or tell me what to change.

### User confirms

```
yes
```

### Result

- Wrote `${aiDir}/memory/semantic/S007-redis-key-length-cap.md`.
- Appended row to `${aiDir}/memory/semantic/index.md`.

### Why this example matters

Shows the skill **asking exactly one** clarifying question — the anchor — and nothing more. The user supplied the fact, the rationale, and the layer of enforcement; only the verification target was missing. The skill never said the word "semantic" or "anchor" out loud.

---

## Anti-pattern (negative polarity)

A "never do this" rule. Demonstrates the skill probing for explicit `not_for` exclusions so the future agent doesn't apply the rule too broadly.

### Setup

The user just reverted a PR where Claude had wrapped a long-running export job inside a database transaction. The transaction blocked replication for 40 minutes during an incident.

### Invocation

```
/memorize never wrap export or backfill jobs in a single transaction — they hold locks too long and block replication
```

### Skill flow

*(Silent classification: rule with "never" → **procedural**, polarity **negative**. The user named the harm but not the boundary.)*

The skill needs the carve-out. It asks:

> "Got it — and is there a case where wrapping a job in a transaction IS still the right call? Anything I should treat as an exception?"

**User answers:**

```
yeah, short atomic batches under like 1000 rows are fine in a tx, and anything that has to be all-or-nothing for correctness still needs one
```

**Agent renders the draft:**

```markdown
---
id: P015
type: procedural
polarity: negative
triggers: [export, backfill, batch-job, transaction, BEGIN, long-running]
not_for:
  - short atomic batches under ~1000 rows
  - jobs with strict all-or-nothing correctness requirements
anchors: []
validated: 2026-04-30
---

# Don't wrap long-running jobs in a single transaction

## Procedure (Do This)
For exports, backfills, and any job processing more than a few
thousand rows, commit in chunks (e.g. 500-row batches inside their
own short transactions) instead of one outer `BEGIN`/`COMMIT`.

## Why This Works
Long transactions hold row and predicate locks for their full
duration and prevent vacuum from reclaiming dead tuples. On
replicated setups, the WAL position can't advance past the
transaction's start, so replicas fall behind.

## What Fails
A single transaction around a 30-minute export blocks autovacuum,
holds locks across the table, and can stall replication entirely.
This already caused a production incident — a 40-minute replication
lag during a customer-facing export.

## Verification
`pg_stat_activity` should not show this job's query running for more
than a couple of seconds at a time. `pg_stat_replication.lag` should
stay flat while the job runs.
```

**Proposed index row** (`memory/procedural/index.md`):

```
| P015 | export, backfill, transaction, replication-lag | 2026-04-30 |
```

> Save this? Reply **yes** to write it, or tell me what to change.

### User edits

```
edit — also mention this applies to the analytics warehouse exports specifically, that's where it bit us
```

The agent revises the **What Fails** section to mention the analytics warehouse export, re-renders, and asks again.

```
yes
```

### Result

- Wrote `${aiDir}/memory/procedural/P015-no-long-transactions-on-jobs.md`.
- Appended row to `${aiDir}/memory/procedural/index.md`.

### Why this example matters

Three things to notice:

1. **Negative polarity** — the rule is about *not* doing something. The body still describes the *correct* behavior (chunked commits) so the next agent has somewhere to land.
2. **`not_for` is non-empty** — the skill insisted on at least one exception so the rule isn't applied to short atomic batches where it would be wrong.
3. **One revision round** — the user added context after seeing the draft. The skill loops on edits before writing.

---

## Critical decision with Layer 1 promotion

The most involved memorize flow: a dated decision that the user wants surfaced in **every** future session. Demonstrates the optional Layer 1 promotion step.

### Setup

After a long architecture discussion, the team decided to drop server-side rendering from the marketing site and go fully static. The decision is irreversible-ish (CDN config, build pipeline, hiring assumptions all key off it) and several months of future work depend on remembering *why*.

### Invocation

```
/memorize on 2026-04-22 we dropped SSR from the marketing site — going fully static via the build pipeline. reason was hosting cost and the SEO win from edge-cached HTML. this is really important, future agents need to know
```

### Skill flow

*(Silent classification: dated event with lasting consequence → **episodic**. The "really important" phrasing is a strong Layer 1 signal.)*

Required fields are mostly present (date, context, decision, reason). The skill asks one question to confirm scope:

> "Was this decision tied just to the marketing site, or does it apply to the whole product suite?"

**User answers:**

```
just marketing — the app itself stays SSR
```

**Agent renders the draft:**

```markdown
---
id: E009
type: episodic
date: 2026-04-22
outcome: success
persistent: true
feature: marketing-site
related: []
verified: 2026-04-30
---

# Dropped SSR from the marketing site

## Context
The marketing site had been served via a Node SSR layer fronted by
Cloudflare. As traffic grew, hosting cost climbed and the SSR layer
became the slowest hop in the request path. SEO audits also showed
edge-cached static HTML scored materially better than dynamically
rendered pages.

## Decision
On 2026-04-22 we dropped SSR for the marketing site and moved to a
fully static build deployed to the edge. Scope is **marketing site
only** — the product app keeps its SSR setup.

## Outcome
Hosting cost on the marketing surface dropped, and Core Web Vitals
improved across the board. No regressions surfaced in the first week.

## Consequence
- The Node SSR runtime, its Dockerfile, and the related deploy job
  are gone from the marketing repo.
- Any future "make this page dynamic" request needs an explicit
  carve-out (client-side fetch, edge function, or a dedicated route
  outside the static build) — don't quietly reintroduce SSR.
- Hiring and ops planning for the marketing surface assumes static
  hosting; revisiting that needs a real reason.
```

**Proposed index row** (`memory/episodic/index.md`):

```
| E009 | marketing-site, ssr, static, hosting-cost, seo | 2026-04-30 |
```

> Save this? Reply **yes** to write it, or tell me what to change.

**User confirms:**

```
yes
```

### Layer 1 promotion

Because the user flagged this as critical ("future agents need to know"), the skill asks:

> "Should this also live in the always-loaded memory index so I see it every session?"

**User:**

```
yes please
```

The agent appends a one-line summary under the **Decisions** section of `${aiDir}/memory/index.md`:

```markdown
- **E009** Marketing site is fully static (no SSR) since 2026-04-22 — don't reintroduce SSR without an explicit carve-out.
```

### Result

- Wrote `${aiDir}/memory/episodic/E009-drop-ssr-marketing.md`.
- Appended row to `${aiDir}/memory/episodic/index.md`.
- Added one-line summary to Layer 1 `${aiDir}/memory/index.md`.

### Why this example matters

- **Episodic** memory carries the *why* a decision was made, which doesn't live in any commit.
- **`persistent: true`** keeps it from being archived during normal memory pruning.
- **Layer 1 promotion** is reserved for things that change how *every* session should reason — not for ordinary rules. The skill only offers it when the user signals criticality.
