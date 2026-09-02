# Flow — debugging with memory loop

Real bugs don't get fixed by guessing — they get fixed by investigating the root cause and *remembering the lesson*. This flow shows the full loop: lookup what's already known, investigate methodically, fix at the root, capture what was learned.

## The bug

A staging deploy is failing every Monday morning at 09:00 UTC. The deploy script runs database migrations, then a smoke test that POSTs to `/api/healthcheck`. The healthcheck has been returning 503 since 09:02 every Monday for three weeks. By 09:30 it's green again. Nobody has been able to reproduce it on demand.

## At a glance

| Step | Skill | Purpose |
|------|-------|---------|
| 1 | `/myspec:memory-lookup` | Has someone already debugged this? |
| 2 | `/myspec:root-cause-debugging` | Phase 1: investigate without proposing fixes |
| 3 | (continued) | Phase 2: pattern analysis vs. working examples |
| 4 | (continued) | Phase 3: hypothesis + minimal test |
| 5 | (continued) | Phase 4: implement fix at root, write regression test |
| 6 | `/myspec:memorize` | Save the lesson so the next agent doesn't redo the hunt |

---

## 1. Memory lookup — start by asking "did we already solve this?"

```
/myspec:memory-lookup monday morning healthcheck 503
```

The skill classifies the search target as procedural-leaning ("symptom-driven"), scans:

- **procedural index** — looks at the *Hook* column for "503", "healthcheck", "staging", "monday", "deploy". One match: **P011** — *"After staging deploys, run smoke tests with retry."* Loaded — but the file's `not_for:` says "this is for build-pipeline failures, not application 5xx." Doesn't apply.
- **semantic index** — *Hook* matches on "deploy", "staging". One match: **S004** — *"Staging Postgres has a separate connection pool from production sized at 5 connections."* Loaded — interesting, possibly relevant.
- **episodic index** — recent events tagged with "staging" or "monday". Nothing under 30 days.

The agent reports:

> Found 1 partially-relevant memory:
> - **S004** — Staging DB connection pool is 5. If a Monday-morning task spikes connection usage, healthcheck could starve. Worth keeping in mind.
> No procedural fix recipe matches. Proceeding to investigation.

---

## 2. Root-cause debugging — Phase 1: investigation

```
/myspec:root-cause-debugging monday healthcheck 503
```

The skill announces the **iron rule**:

> NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST

### Step 1 — read errors completely

The agent pulls `kubectl logs` for the healthcheck pod from last Monday 09:00–09:30:

```
[09:01:14] connection acquire timeout: pool exhausted (5/5 in use)
[09:01:14] sql: dial postgres: timeout
[09:01:15] healthcheck handler: 503 (no db)
... (repeats every 30s) ...
[09:29:42] connection acquired in 4.1s
[09:29:42] healthcheck handler: 200
```

So it's a **connection-pool starvation**. Lines up with S004.

### Step 2 — reproduce consistently

Reproducing on staging requires waiting until next Monday. The agent instead reproduces by **simulating the load pattern**: locally, opens 5 long-running queries against staging (via `psql` connections), then hits the healthcheck. 503 immediately. Pool size of 5 confirmed as the cap.

### Step 3 — check recent changes

`git log --since='4 weeks ago' --oneline` on infra repo:

```
a1b2c3d  ops: add weekly analytics-rollup job (cron, Mondays 09:00 UTC)
```

There it is. Three weeks ago someone added an analytics rollup that runs at exactly 09:00 UTC every Monday. The rollup runs a few long-lived queries and holds connections.

### Step 4 — gather evidence at component boundaries

The agent traces:

- **Cron scheduler** — fires the rollup at 09:00 UTC. ✓
- **Rollup job** — opens 4 connections, runs ~25-minute aggregation. Connections held the whole time. ✓
- **Connection pool** — staging is sized 5. Rollup holds 4 → 1 left for everything else. The deploy smoke test hits at 09:01–09:02 and competes with the regular healthcheck poller. Pool exhausted. ✓
- **Healthcheck handler** — fails to acquire a connection within 1s timeout, returns 503. ✓

### Step 5 — trace data flow backward

Who decided the pool was 5? `git blame` on the staging Helm values:

```
infra/staging/values.yaml: pool_size: 5  # alice — keep small to detect leaks early
```

Documented choice — not a bug. The bug is that we added a Monday workload that breaks the assumption.

**Phase 1 done.** Root cause identified: analytics-rollup holds 4 of 5 staging DB connections starting Monday 09:00 UTC, starving the healthcheck and any other deploy traffic during the rollup window.

---

## 3. Phase 2 — pattern analysis

The agent compares to the production pool (`pool_size: 50`). Production has the same rollup — but plenty of headroom, so no symptom. The fix-shape is constrained: **either give staging more headroom, or stop holding connections during the rollup, or schedule the rollup outside deploy windows.**

The agent finds two related working examples:

- The nightly backup job uses a **dedicated connection pool** (pool size 2) so it can't starve the main pool. Pattern exists in the codebase.
- The CDC consumer **uses short-lived transactions** in a loop instead of one long transaction.

Two candidate patterns to apply.

Also notes: the original choice ("keep pool small to detect leaks early") was a debugging affordance, not a permanent constraint. Worth re-litigating if the fix wants to bump the pool.

---

## 4. Phase 3 — hypothesis + minimal test

**Hypothesis**: *"The analytics-rollup holds long-lived connections from the shared pool. Moving the rollup to its own dedicated pool will eliminate the starvation."*

**Smallest test**: locally run the rollup against a dedicated pool (override via env), watch the shared pool's connection count during the run. Should stay flat at baseline.

The agent runs the test. Shared pool connections stay at 1 (just the healthcheck poller); rollup pool holds 4 as expected. Hypothesis confirmed.

The agent does *not* stack a second fix ("also raise the pool to 10"). One change at a time — that's the iron rule of the skill.

---

## 5. Phase 4 — implement and verify

1. **Failing test first**: writes an integration test that simulates 4 long-running queries plus a healthcheck call. Today the test fails (503). After fix it should pass.
2. **The fix**: adds an `analytics_pool` block to staging values, repoints the rollup job to use it. Diff is ~12 lines across two files.
3. **Verify**: test passes locally. Smoke test against staging on next deploy succeeds even with rollup running.
4. **Regressions**: nothing else uses the new `analytics_pool` config key, so the change is contained. Production gets the same config change too — defense in depth, even though prod's headroom currently masks the problem.

---

## 6. Memorize the lesson

The bug is fixed and the diff explains *what* was done. But the *lesson* — that long-running scheduled jobs sharing the main pool can starve healthchecks, especially in environments with small pools — won't be re-derived from a `git blame`. Save it.

```
/myspec:memorize background jobs that hold long-lived db connections must use a dedicated pool — sharing the main pool can starve healthchecks and any other inbound traffic, especially in environments where the pool is sized small for leak detection
```

The skill (silently) classifies this as **procedural / negative-leaning**, asks one clarifying question:

> Is there a case where sharing the main pool is still acceptable — e.g., short-lived jobs that only hold a connection for a few hundred ms?

User: *"Yes — anything sub-second is fine, the rule is about jobs that hold connections >5 seconds."*

Drafts:

```markdown
---
id: P019
type: procedural
polarity: positive
triggers: [background-job, cron, connection-pool, postgres, starvation, healthcheck, deploy]
not_for:
  - jobs that hold a DB connection for less than ~5 seconds
  - jobs that only run during low-traffic maintenance windows with confirmed headroom
anchors:
  - file: infra/staging/values.yaml
    pattern: "analytics_pool"
related: [S004]
validated: 2026-04-30
---

# Long-running background jobs need a dedicated DB connection pool

## Procedure (Do This)
For any background job that holds a Postgres connection for more than
~5 seconds (analytics rollups, exports, backfills, large reports),
configure it with a dedicated connection pool, not the shared
application pool.

## Why This Works
The shared pool is sized for short-lived request handlers. A handful
of long-lived connections from a job will starve incoming requests
when the pool is small (staging: 5, dev: 5). Healthchecks, deploy
smoke tests, and other inbound traffic will 503 with "connection
acquire timeout."

## What Fails
On 2026-04-30, three weeks of Monday-morning deploy failures were
traced to the weekly analytics rollup holding 4 of staging's 5
connections during the deploy window (09:00-09:30 UTC). Production
masked the same pattern thanks to a 50-connection pool — but
the bug was still there.

## Verification
While the job is running: `SELECT count(*) FROM pg_stat_activity
WHERE application_name = 'app-shared'` should stay at baseline. The
job's connections appear under its own application_name.
```

User approves. Memory written. The agent also offers:

> Should P019 also live in the always-loaded index? Past misses on this took 3 weeks to diagnose.

User: *"Yes, pin it."* Layer 1 promotion happens — one-line summary lands in `ai/memory/index.md` under **Rules**.

---

## What this flow demonstrates

- **Memory lookup is the cheap first step.** Often there's no match — that's fine, you still know nobody else solved this. When there is a match, you save hours.
- **Root-cause-debugging's phases prevent the most expensive bug**: applying a fix to a symptom and shipping a *new* bug. The iron rule ("no fixes before phase 1") is load-bearing.
- **Phase 2 (pattern analysis) finds the project's existing answer.** The dedicated-pool pattern was already in the codebase — the agent didn't invent a solution, it copied a known-good one.
- **Phase 3 (hypothesis + smallest test) catches false positives.** Without it, you'd have shipped "raise the pool to 10" and called it done — but the rollup would still be a ticking time bomb whenever workload grows.
- **Phase 4 demands a regression test.** That test is *what stops this exact bug from coming back* in six months when somebody refactors the rollup.
- **`/memorize` after the fix is the highest-leverage step in the whole flow.** The diff captures the *what*. The memory captures the *why* and the *general rule*. Without it, the next agent will rediscover this from scratch.
