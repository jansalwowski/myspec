# `/myspec:feature-tech-spec` — examples

Creates `tech-spec.md` from an approved `spec.md`. The skill reads the spec, examines existing patterns in the codebase, and produces an architecture + implementation breakdown. Always requires `spec.md` with `status: approved`.

**Contents**

- [Pattern-following design](#pattern-following-design)
- [ADR-heavy design with architectural alternatives](#adr-heavy-design-with-architectural-alternatives)
- [Discovers spec gap during design](#discovers-spec-gap-during-design)

---

## Pattern-following design

The most common case: the codebase already has a pattern for this kind of feature, and the tech-spec mostly captures *which* pattern and how.

### Setup

`favorite-reports` (from the [feature-spec example](feature-spec.md#greenfield--small-self-contained-feature)) is approved. The codebase has three other "favorite-style" features (favorite-dashboards, favorite-queries, favorite-collections) that all follow the same shape: a `{entity}_favorites` join table, a service with `add` / `remove` / `list` / `isFavorite`, and a UI hook.

### Invocation

```
/myspec:feature-tech-spec favorite-reports
```

### Skill flow

#### 1. Read approved spec

The skill loads `spec.md`, notes `spec_version: 1` and the 5 acceptance criteria.

#### 2. Research existing patterns

The agent examines `src/features/dashboards/favorites/`, `src/features/queries/favorites/`, etc. Records the convention:

- Schema: `{entity}_favorites(user_id, {entity}_id, created_at)` with composite PK and an index on user_id.
- Service file: `src/features/{feature}/favorites/service.ts`.
- React hook: `useFavorites({entity}Id)`.
- Tests co-located in `__tests__/`.

#### 3. Draft tech-spec

```yaml
---
title: "Favorite Reports -- Technical Specification"
status: draft
based_on_spec_version: 1
created: 2026-04-30
last_updated: 2026-04-30
---
```

Sections produced:

- **Architecture**: "Follows the existing favorites pattern (see dashboards-favorites). New `report_favorites` table, `ReportFavoritesService`, `useReportFavorites` hook."
- **Reuse audit** (required — the `require-reuse-audit.sh` hook blocks tech-spec writes without it):

  | Candidate | Surface | Decision | Reason |
  |-----------|---------|----------|--------|
  | `FavoritesService<T>` | shared services | reuse | generic contract fits reports unchanged |
  | `useDashboardFavorites` | app hooks | skip | dashboard-specific cache keys; new hook instead |

- **Key Interfaces**: `ReportFavorite`, `FavoritesService<Report>` (extends the generic favorites contract).
- **Implementation Steps** — 6 ordered tasks:
  1. Migration: `report_favorites` table.
  2. `ReportFavoritesService` with add/remove/list/isFavorite.
  3. API handlers: `POST /api/reports/:id/favorite`, `DELETE /api/reports/:id/favorite`.
  4. `useReportFavorites` hook.
  5. Star button component in `ReportListRow`.
  6. Pin-to-top sort logic in the list query.
- **Database Changes**: one new table.
- **Decisions** — one ADR: *"Follow existing favorites pattern rather than introducing a generic favorites service."* Context: three existing per-feature implementations; consolidating them is out of scope.
- **Edge Cases**: deleting a favorited report (cascade), unfavoriting then refavoriting in the same session (idempotent).
- **File Inventory** — 5 files create, 2 modify.

`based_on_spec_version: 1` matches.

### User confirms

```
yes
```

### Result

`tech-spec.md` written. The skill ends with:

> **Next:** `/myspec:feature-tech-spec-review favorite-reports`, then `/myspec:feature-plan favorite-reports`.

### Why this example matters

- **Pattern recognition is the highest-leverage step.** When the codebase already solves a class of problem, the tech-spec's job is to point at the pattern, not invent a new one. The result: an ADR documenting *why* we matched the existing convention.
- **Implementation Steps stay small (6 tasks)** — within the comfortable feature-plan ceiling, no parallelism opportunities (each step depends on the previous), one milestone.
- **No GraphQL section** because this codebase uses REST. The skill adapts to the project's stack — it's not a fixed template.

---

## ADR-heavy design with architectural alternatives

When there's *not* an obvious pattern, the tech-spec earns its keep by documenting the choice between alternatives.

### Setup

`scheduled-reports` is approved. The codebase has no scheduled-job infrastructure yet — this feature has to introduce it. The user already discussed alternatives during the spec phase (in-app cron, system cron, dedicated worker, queue-based) and asked the spec to defer the choice to tech-spec.

### Invocation

```
/myspec:feature-tech-spec scheduled-reports
```

### Skill flow

The skill researches:

- The codebase already runs a Postgres + a Redis instance.
- There's no existing job runner, but `bullmq` is in `package.json` (used by one cleanup script).
- Production runs on Fly.io; persistent VMs are an option but additional cost.

#### Drafts the tech-spec

The Architecture section is short, but the **Decisions** section has three ADRs:

```markdown
### Decisions

#### ADR-1: Job runner — bullmq on existing Redis

- **Decision**: Use bullmq with the existing Redis instance for scheduled job execution.
- **Context**: We need recurring job execution. Three options were considered.
- **Alternatives**:
  - **Postgres pg_cron** — rejected: requires running cron in the DB, complicates failover.
  - **System-level cron + standalone worker** — rejected: introduces a new VM and deploy surface.
  - **bullmq on Redis** — chosen: bullmq is already a dependency, Redis is already running, and bullmq's repeatable jobs handle cadence natively.
- **Consequences**: Coupling to Redis availability for scheduling. Mitigated by the fact that the rest of the app already requires Redis. Adds an in-app worker process in the deploy.

#### ADR-2: Cadence representation — preset enum, not cron expressions

- **Decision**: Schedules expose a closed set of cadence presets (DAILY_9AM, WEEKLY_MONDAY, WEEKLY_FRIDAY) rather than free-form cron expressions.
- **Context**: spec.md AC-3 limits the user-facing UI to presets.
- **Alternatives**: Free-form cron — rejected as out of spec scope.
- **Consequences**: Adding a new cadence requires a code change. Acceptable trade-off; user research showed >90% of users want one of the three presets.

#### ADR-3: Failure handling — retry with backoff, alert on 3rd failure

- **Decision**: A scheduled run that fails to send the email retries with exponential backoff (1m, 5m, 15m). On 3rd failure, the run is marked `failed`, the user is notified in-app, and an oncall alert fires.
- **Context**: Spec AC-7 requires retries; alerting threshold was unspecified.
- **Alternatives**: Infinite retry — rejected: hides systemic issues. Single-shot — rejected: too brittle for transient SMTP issues.
- **Consequences**: An oncall alert per failed run after 3rd retry. Volume should be low; if it isn't, that itself is a signal worth paging on.
```

Implementation Steps total 11, organized into two milestones:

- **Milestone 1**: data model + service + bullmq registration + retry logic.
- **Milestone 2**: settings UI + email integration + run history.

### User confirms with edits

```
ADR-3 retry intervals look short. Bump to 5m / 30m / 2h. Otherwise approved.
```

The skill edits the ADR, re-renders, gets approval, writes.

### Result

`tech-spec.md` with three ADRs and explicit alternatives, status `draft` until tech-spec-review.

### Why this example matters

- **ADRs are not optional when there's no pattern.** The next agent reading this in a year needs to know *why* bullmq was chosen — without ADR-1, they'll re-litigate that decision and possibly pick differently.
- **Each ADR follows the same shape**: Decision → Context → Alternatives → Consequences. The skill enforces this; ad-hoc prose doesn't survive code review.
- **User edits land before write.** ADR-3's retry policy was a judgment call — the user nudged it once and the skill applied the change without rewriting the rest.

---

## Discovers spec gap during design

Sometimes designing the implementation surfaces a question the spec didn't answer. The skill stops, names the gap, and refuses to invent the answer.

### Setup

`team-invites` is approved at `spec_version: 1`. The user runs:

```
/myspec:feature-tech-spec team-invites
```

### Skill flow

The skill reads `spec.md` and starts mapping acceptance criteria to implementation steps. Hits a wall:

- AC-4 says: *"Invitee receives an email and clicks a link to accept."*
- The spec doesn't specify: how long is the invite link valid? What happens if the user clicks an expired link? Can a user re-request an invite? Can an admin cancel a pending invite?

The skill stops drafting and reports:

> Before I can finish the tech-spec, I need to resolve four gaps in the spec:
>
> 1. **Invite link TTL** — how long is the link valid? (Common choices: 7 days, 14 days, no expiry.)
> 2. **Expired-link UX** — error page only, or "request a new invite" option?
> 3. **Cancellation** — can an admin cancel a pending invite before it's accepted?
> 4. **Resend** — can the invitee request a fresh email if the original is lost?
>
> I can't make these decisions in the tech-spec — they're product behavior, not implementation detail. Two options:
>
> - **A) Update the spec.** Run `/myspec:feature-update team-invites` (or pause this skill, edit the spec by hand, and bump spec_version). Then re-run `/myspec:feature-tech-spec team-invites`.
> - **B) Answer here, and I'll update spec.md inline before continuing.** I'll bump `spec_version` to 2, add the new acceptance criteria, and proceed with the tech-spec — but it'll require re-approval of the spec.

**User**: option B — link valid 14 days, expired link shows "request a new invite" button, admins can cancel before acceptance, resend allowed once per 24h.

### Skill flow (continued)

The skill:

1. Edits `spec.md` — adds AC-8 through AC-11 covering the answers, bumps `spec_version` to 2, sets `status: draft` (was `approved`).
2. Continues drafting `tech-spec.md` with `based_on_spec_version: 2`.
3. Notes in the tech-spec's Decisions section: *"Spec was incomplete on TTL/expiry/cancel/resend semantics; resolved during tech-spec design — see spec_version 2."*

### Result

Both files written. The skill ends with a different hand-off than usual:

> **Important**: spec.md was modified. Run `/myspec:feature-spec-review team-invites` to re-approve at v2 *before* `/myspec:feature-tech-spec-review`. Otherwise the tech-spec will be reviewing against an unapproved spec.

### Why this example matters

- **The skill refuses to invent product behavior.** TTL, cancellation, resend — these are user-facing decisions, not implementation details. The skill names the gap and stops.
- **Spec changes during tech-spec are first-class.** The skill knows how to bump `spec_version` and re-route through review — it doesn't pretend the spec was always v2.
- **The Decisions section captures the discovery.** Future readers will see why spec_version skipped from 1 to 2 — useful when archaeology is needed later.
