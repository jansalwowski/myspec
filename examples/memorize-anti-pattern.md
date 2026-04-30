# memorize — anti-pattern (negative polarity)

A "never do this" rule. Demonstrates the skill probing for explicit `not_for` exclusions so the future agent doesn't apply the rule too broadly.

## Setup

The user just reverted a PR where Claude had wrapped a long-running export job inside a database transaction. The transaction blocked replication for 40 minutes during an incident.

## Invocation

```
/memorize never wrap export or backfill jobs in a single transaction — they hold locks too long and block replication
```

## Skill flow

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

## User edits

```
edit — also mention this applies to the analytics warehouse exports specifically, that's where it bit us
```

The agent revises the **What Fails** section to mention the analytics warehouse export, re-renders, and asks again.

```
yes
```

## Result

- Wrote `${aiDir}/memory/procedural/P015-no-long-transactions-on-jobs.md`.
- Appended row to `${aiDir}/memory/procedural/index.md`.

## Why this example matters

Three things to notice:

1. **Negative polarity** — the rule is about *not* doing something. The body still describes the *correct* behavior (chunked commits) so the next agent has somewhere to land.
2. **`not_for` is non-empty** — the skill insisted on at least one exception so the rule isn't applied to short atomic batches where it would be wrong.
3. **One revision round** — the user added context after seeing the draft. The skill loops on edits before writing.
