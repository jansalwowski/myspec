# `/myspec:root-cause-debugging` — examples

Four-phase methodology for finding root causes before applying fixes. Iron rule: **NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST**. The skill won't propose code changes until Phase 1 is complete.

> **Related**: For the full debugging-with-memory loop including pre-investigation `/memory-lookup` and post-fix `/memorize`, see [flows/debugging-with-memory.md](../flows/debugging-with-memory.md). The scenarios here focus on the debugging skill itself.

**Contents**

- [Single-component bug found in Phase 1](#single-component-bug-found-in-phase-1)
- [Multi-component bug — boundary tracing](#multi-component-bug--boundary-tracing)
- [Stuck in a loop — 3-attempt escalation](#stuck-in-a-loop--3-attempt-escalation)

---

## Single-component bug found in Phase 1

The fastest case: the symptom contains the answer if you actually read it.

### Setup

A unit test started failing on every CI run after a recent merge. Local: passes. CI: `Error: Cannot read properties of undefined (reading 'config') at TenantManager.js:42`.

### Invocation

```
/myspec:root-cause-debugging tenantmanager test failing only in CI
```

### Skill flow

#### Phase 1 — investigation

**1. Read errors completely.** The skill pulls the full CI log:

```
TypeError: Cannot read properties of undefined (reading 'config')
  at TenantManager.getConfig (src/tenant/TenantManager.js:42:18)
  at __tests__/tenant.test.js:15:30

Test setup:
  TENANT_ENV: undefined
  process.env.NODE_ENV: test
```

The line `TENANT_ENV: undefined` jumps out. The error is at line 42 of TenantManager.

The skill reads `TenantManager.js:42`:

```javascript
return process.env[`TENANT_CONFIG_${TENANT_ENV}`].config;
```

The lookup uses `TENANT_ENV` which is undefined in CI but set locally.

**2. Reproduce consistently.** Skill runs `TENANT_ENV= pnpm test tenant` locally. Reproduces.

**3. Check recent changes.** `git log --since='3 days' src/tenant/`:

```
b3d4e5f  refactor: move TENANT_ENV from .env to runtime config
```

Reads the diff. `.env.test` previously had `TENANT_ENV=test`; the refactor removed it expecting runtime configuration. CI doesn't pass `TENANT_ENV` because the change wasn't propagated to `.github/workflows/test.yml`.

**Root cause identified.** The skill skips Phases 2 and 3 — there's no ambiguity about the cause.

#### Phase 4 — fix

1. Failing test confirmed (already failing).
2. Fix: add `TENANT_ENV: test` to the test job in `.github/workflows/test.yml`. Optionally also add a guard in `TenantManager.getConfig()` that throws a clear error if `TENANT_ENV` is unset.
3. Verify: re-run CI. Passes.
4. No regressions — change is additive.

The skill ends:

> Root cause: refactor removed `TENANT_ENV` from `.env.test` but didn't propagate to CI workflow config. Fixed in two places — workflow + clear-error guard. Suggest `/memorize` capturing "env-var refactors must update all environments (.env, CI, container configs, deploy)."

### Why this example matters

- **Phase 1 contained the answer.** Stack trace + git diff + reading line 42 — three steps. No phase 2/3 needed because there was no competing hypothesis.
- **The skill skipped phases when not needed.** The methodology is "in order, do not skip ahead" — but skipping ahead because you already have the root cause is the point of phases 2/3 (refining hypothesis). When phase 1 is unambiguous, you go straight to fix.
- **Two-part fix.** The actual bug is the missing env var; the guard is defensive (clear error next time). Both small, both worth doing.

---

## Multi-component bug — boundary tracing

The interesting case: failures crossing service boundaries. Phase 1's "gather evidence at component boundaries" earns its keep.

### Setup

A scheduled email export sends out *empty* CSV attachments — the file is created, attached to the email, delivered, but contains only the header row. Reproduces inconsistently in production, never locally. No errors logged.

### Invocation

```
/myspec:root-cause-debugging scheduled exports producing empty csvs
```

### Skill flow

#### Phase 1 — investigation

**1. Read errors.** No errors. That itself is a clue: silent data loss.

**2. Reproduce consistently.** Local with the production data snapshot: passes (CSV has data). The skill flags: *"Not reproducible locally → gather more data, do not guess."*

**3. Check recent changes.** No relevant changes in the last 30 days to the export code or its dependencies.

**4. Boundary tracing.** Multi-component pipeline: `Scheduler → ExportJob → DataQuery → CSVWriter → S3Upload → EmailSender`.

The skill instruments each boundary in production (read-only logging — value counts, not contents):

```
For EACH component boundary:
  - Log row count entering
  - Log row count exiting
  - Verify env/config propagation
```

After one production run with the instrumentation:

| Boundary | Rows in | Rows out |
|----------|---------|----------|
| Scheduler → ExportJob | (params) | (params) |
| ExportJob → DataQuery | tenant_id | tenant_id |
| DataQuery → CSVWriter | **0** | 0 |
| CSVWriter → S3Upload | 0 | 0 |
| S3Upload → EmailSender | (file ref) | (file ref) |

The data query returned **zero rows** in production, but the same query returns rows locally with a copy of the production data.

**5. Trace data flow backward.** Why does the query return zero in production but rows locally?

The skill examines the query:

```javascript
SELECT * FROM events WHERE tenant_id = $1 AND created_at >= $2 AND created_at < $3
```

Parameters in the production run: `tenant_id = 47`, `created_at >= 2026-04-29T09:00`, `created_at < 2026-04-30T09:00`.

The skill checks the production DB for tenant 47's events in that window: **plenty exist**. So the query should return rows.

Examining further: the production replica was last refreshed at 2026-04-29T08:55 — five minutes before the window starts. The export job runs against the replica (config: `DB_REPLICA_URL`). Five-minute replication lag means the new events from the window aren't on the replica when the job runs.

**Root cause**: scheduled-export job reads from a replica with replication lag; jobs that schedule near the lag boundary see empty results.

#### Phase 2 — pattern analysis

The skill finds working examples:

- The notification-system also runs at scheduled times and **reads from primary**, not replica. Pattern exists.
- The analytics-rollup uses `read_after_write_consistency: true` flag in its DB client.

#### Phase 3 — hypothesis + minimal test

**Hypothesis**: *"Scheduled jobs reading from replicas can see lag-induced empty results."*

**Smallest test**: in staging, deliberately stall the replica (admin tool exists), run the export job, observe empty CSV. Confirmed.

#### Phase 4 — fix

1. Failing test: integration test that runs the export against a deliberately-lagged replica, asserts non-empty CSV. Today fails.
2. Fix: route scheduled export jobs to primary, mirroring the notification-system pattern. Two-line config change in `ScheduledExportJob`.
3. Verify: integration test passes. Smoke test against staging with manual stall: passes.
4. No regressions; primary has plenty of headroom for this query volume.

The skill ends:

> Root cause: scheduled-export reads from replica with replication lag — empty result when run near the lag boundary. Fixed by routing to primary. Suggest `/memorize` covering "scheduled jobs that read recent data must use primary, not replica" — closely related to existing P019 (connection-pool starvation).

### Why this example matters

- **"No errors" is a clue.** Silent data loss is harder to find than crashes — but boundary tracing makes it methodical. Without instrumentation at each hop, you'd be guessing.
- **Boundary tracing is the highest-leverage Phase 1 step in multi-component bugs.** The single command "log row counts at each boundary" turned a vague symptom into a specific component.
- **Pattern analysis (Phase 2) found the answer in the codebase.** The fix is a known-good pattern from notification-system — not invented. Same as the `flows/debugging-with-memory.md` lesson: *check what the project already does.*
- **Phase 3's deliberate-stall test** is the difference between confidence and a guess. Without it, the team would ship a "fix" that might or might not be addressing the right thing.

---

## Stuck in a loop — 3-attempt escalation

Phase 4's fallback: *"if fix doesn't work and you've tried < 3 fixes → return to Phase 1 with new information."* This is what stops infinite-fix-stacking when a hypothesis is wrong.

### Setup

Production logs show occasional `ECONNRESET` errors when calling an external billing API. Errors are intermittent; no clear pattern. Customer-reported: occasional failed checkouts.

### Invocation

```
/myspec:root-cause-debugging billing api econnreset intermittent
```

### Skill flow

#### Attempt 1

**Phase 1**: Skill reads ECONNRESET logs. Hypothesis: short-lived TCP connections being closed by intermediary load balancer. **Phase 3** test: enable HTTP keepalive on the client. **Phase 4**: deploy keepalive. Wait 24h. **Errors persist at same rate.**

**Phase 4 escalation**: 1 fix tried, didn't work. Return to Phase 1 with new info: *keepalive doesn't help → not a connection-recycling issue.*

#### Attempt 2

**Phase 1 (new info)**: Skill correlates ECONNRESET timestamps against deploy events. Notices: errors cluster in the 30 seconds *after* every deploy. Hypothesis: in-flight requests during pod restart. **Phase 3** test: add graceful shutdown delay (drain inflight requests before SIGKILL). **Phase 4**: deploy. Wait 24h. **Errors during deploy windows drop to zero. But errors outside deploy windows still occur.**

**Phase 4 partial success**: 2 fixes tried. Some progress (deploy-window errors gone) but the original *intermittent* problem persists.

The skill flags this carefully:

> The graceful-shutdown fix addressed a real bug (deploy-window errors), but it's not the original ECONNRESET we were chasing. **The remaining errors are still happening.** I've tried 2 fixes; the iron rule says I should not try a 3rd fix without restarting Phase 1 with the new evidence in hand.

#### Phase 1, third pass

**New info**: errors aren't deploy-related. The skill broadens evidence gathering:

- Pulls 30 days of ECONNRESET logs. Correlates against time-of-day, day-of-week, payload size, customer tenant, request method, billing-API endpoint.
- Notices: 80% of remaining errors are on `POST /charge` with payloads >50KB.

Reads the billing API's docs. Buried at the bottom: *"Maximum request body size: 50KB. Larger requests may be rejected with a connection reset."*

**Root cause**: billing API silently rejects (via TCP reset rather than HTTP 4xx) requests with bodies over 50KB. Our checkout flow occasionally sends large payloads when a cart contains many line items.

#### Phase 4 — fix (this time correct)

1. Failing test: integration test that submits a 51KB payload. Reproduces ECONNRESET.
2. Fix: pre-validate payload size client-side; if over 50KB, split into multiple charge calls (the API supports an `idempotency_key` so this is safe).
3. Verify: tests pass. Production logs over the next 24h show ECONNRESET drops to zero.
4. The graceful-shutdown fix from attempt 2 stays — it was a real bug, just not the one we started chasing.

### Why this example matters

- **The 3-attempt rule is what saves you from infinite-fix-stacking.** Without it, the skill would have tried fix 3, fix 4, fix 5 — each addressing a plausible-sounding theory, each not actually solving the original problem. Methodical regression to Phase 1 with new info is the way out.
- **A "partial success" is suspicious, not celebratory.** Attempt 2 fixed *something* but not the original symptom. Conflating those creates false confidence.
- **Long-tail evidence gathering pays off.** Looking at 30 days of logs and correlating across multiple axes is what surfaced the payload-size pattern. Phase 1 isn't just "read the latest stack trace" — sometimes it's "stare at history hard."
- **A failed-but-real fix isn't always reverted.** The graceful-shutdown work from attempt 2 stays. Two real bugs were found in this session, even though only one was the one we set out to find.
