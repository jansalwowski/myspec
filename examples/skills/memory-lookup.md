# `/myspec:memory-lookup` — examples

Searches across procedural, semantic, and episodic memory indexes for relevant entries given a problem or topic. Loads matching memory files in full and reports what was found. Read-only — doesn't write or modify anything.

**Contents**

- [Direct procedural match](#direct-procedural-match) — error symptom finds a fix recipe
- [Partial match across types](#partial-match-across-types) — two memories of different types both relevant
- [No match — clean miss](#no-match--clean-miss) — agent reports honestly and proceeds

---

## Direct procedural match

The high-leverage case: you remember nothing, the system remembers everything. A symptom-driven search finds an exact prior solution.

### Setup

Build is failing on a fresh checkout: `Error: ENOENT: no such file or directory, open '.env.local'`. The user has seen this before, vaguely, but doesn't remember the fix.

### Invocation

```
/myspec:memory-lookup ENOENT .env.local fresh checkout build failing
```

### Skill flow

#### 1. Classify

Error message + symptom → procedural search.

#### 2. Scan procedural index

Reads `${aiDir}/memory/procedural/index.md`:

```
| ID   | Use When                                  | Not For        | Validations | Last Validated |
|------|-------------------------------------------|----------------|-------------|----------------|
| P003 | env files missing on fresh clone, ENOENT  | CI environments| 7           | 2026-04-12     |
| P019 | background jobs starving connection pool  | short jobs     | 1           | 2026-04-30     |
| ...  |                                           |                |             |                |
```

P003 matches strongly — same symptom, validation count of 7 (proven pattern). Skips semantic and episodic since the symptom is squarely procedural.

#### 3. Load full file

Reads `${aiDir}/memory/procedural/P003-env-bootstrap-on-fresh-checkout.md`:

```markdown
# Bootstrap env files on fresh clone

## Procedure (Do This)
After cloning the repo for the first time (or whenever `.env.local`
is missing):

  cp .env.example .env.local
  # If you need OAuth secrets, ask in #dev-onboarding for the
  # current values — they rotate quarterly and aren't in the example.

Then run `pnpm install && pnpm dev` as usual.

## Why This Works
`.env.local` is gitignored — every developer has their own. The
`.env.example` is a checked-in template with placeholders for the
required keys.

## What Fails
Build commands that read env via dotenv will throw ENOENT if
`.env.local` is missing. The fix is mechanical, but the message
doesn't point at it.

## Verification
`ls .env.local` shows the file, `pnpm dev` starts cleanly.
```

#### 4. Apply

The agent reports:

> Found a high-confidence match — **P003** (validated 7 times). Solution:
>
> ```bash
> cp .env.example .env.local
> ```
>
> If you need OAuth secrets, those rotate quarterly and aren't in `.env.example` — ask in `#dev-onboarding`. Then `pnpm install && pnpm dev`.

User runs the cp, `pnpm dev` starts cleanly.

#### 5. Update tracking

The skill increments P003's `validation_count` to 8 and updates `validated: 2026-04-30` in the file's frontmatter.

### Why this example matters

- **Validation count is a confidence signal.** A memory validated 7 times has stood up to repeated use — much higher trust than a one-shot capture.
- **The skill skips index scans it doesn't need.** Symptom-driven searches don't touch semantic/episodic — saves time and noise. The classification step is what enables this.
- **Validation tracking is automatic.** The skill bumps the count *and* the date — that's what keeps the index meaningful as memories age.
- **The fix recipe is concrete.** P003 is not "you might be missing env vars" — it's exact commands the user can copy. That's the procedural memory standard.

---

## Partial match across types

A search where multiple memories are tangentially relevant. The agent reports them with their applicability so the user can judge.

### Setup

The user is starting work on a new background job and wants to know if there's prior wisdom on background jobs in this codebase.

### Invocation

```
/myspec:memory-lookup background job patterns connection pool postgres
```

### Skill flow

#### 1. Classify

"Patterns" + "postgres" → could be procedural (rules), semantic (facts), or episodic (past decisions). Search all three.

#### 2. Scan all indexes

**Procedural**:
- `P019` — *Long-running background jobs need a dedicated DB connection pool*. `Use When: background-job, cron, connection-pool, postgres, starvation`. Direct match. Validation count: 1.
- `P015` — *Don't wrap long-running jobs in a single transaction*. Adjacent — about transactions, not pools. Possibly relevant.

**Semantic**:
- `S004` — *Staging Postgres has a connection pool sized at 5*. Topic match. Possibly the *reason* P019 exists.

**Episodic**:
- `E007` — *Migrated cleanup-job to Inngest, 2026-02-12*. Loosely related (job infrastructure history) but not specifically about pools.

#### 3. Load matched files

Reads P019, P015, S004 in full. E007 is too loose — skipped after reading the index entry.

#### 4. Reports back with applicability ranking

> Three memories worth knowing here:
>
> **Strongly applicable**
>
> - **P019** *(procedural, validated 1x)* — Long-running background jobs need a dedicated DB connection pool, separate from the application pool. Threshold: jobs holding a connection >5s. The exception list says short jobs (<5s) can share the main pool.
>
> **Possibly applicable**
>
> - **S004** *(semantic)* — Staging DB has a 5-connection pool, sized small to detect leaks early. Read this because it explains *why* P019 matters in staging specifically. Production pool is 50.
>
> **Adjacent — same problem space, different fix**
>
> - **P015** *(procedural, validated 1x)* — Don't wrap long-running jobs in a single transaction. Different concern (transaction lifetime vs. connection ownership), but the same shape of bug — long-held DB resource starves other work.
>
> If your new job will hold a connection more than ~5 seconds, P019 applies and you should configure a dedicated pool. If it'll do bulk inserts, P015 also applies (chunked transactions, not one big one).

User's job will run for several minutes — both apply.

#### 5. Tracking

P019, P015, and S004 get `verified` / `validated` date bumps.

### Why this example matters

- **Three results, each tagged with applicability.** Not a flat list — the user knows P019 is the must-read, S004 is context, P015 is parallel-but-different.
- **Cross-type composition is normal.** Procedural rules often have semantic facts as their *reason* (P019 + S004) and adjacent procedurals as *related* concerns (P019 + P015). The skill surfaces the cluster.
- **Validation count of 1 is honest.** P019 was just captured — no overconfidence. The user knows to apply it but maybe verify the dedicated-pool config syntax for their specific tooling.

---

## No match — clean miss

Sometimes there's nothing to find. The skill reports honestly and gets out of the way.

### Setup

The user is exploring a brand-new area of the codebase: GraphQL subscription support over WebSockets. The team has never built this before.

### Invocation

```
/myspec:memory-lookup graphql subscriptions websocket
```

### Skill flow

#### 1. Classify

Domain-driven search → all three indexes.

#### 2. Scan all indexes

Procedural index: no entries with "graphql" or "websocket" or "subscription" in `Use When`.

Semantic index: nothing with "graphql" topic, nothing with "websocket".

Episodic index: nothing about subscriptions.

#### 3. Reports honestly

> No matches across procedural, semantic, or episodic memory for "graphql subscriptions websocket".
>
> The memory system has nothing about this domain — likely because the codebase has never built it before. You're in greenfield territory.
>
> Suggestion: as you investigate or implement, capture worth-keeping insights with `/memorize` (or run `/memorify` at session end) so the next agent on this work isn't starting from zero.

The skill stops without trying to be helpful where it has no information.

### Why this example matters

- **An empty result is a real result.** "Nothing here" tells the user they're not duplicating prior work — they're authoring the first memories in this domain.
- **The skill resists the urge to bullshit.** No "well, here are some loosely related memories about HTTP that might apply" — that pollutes the search experience next time.
- **Reminds the user to capture.** The most valuable memories come from the *first* time someone solves a problem. The skill's nudge to `/memorize` later turns this empty result into seeds for the next search.
