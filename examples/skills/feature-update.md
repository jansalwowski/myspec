# `/myspec:feature-update` — examples

Modifies an already-implemented feature: edits `spec.md` and `tech-spec.md` in place, bumps `spec_version`, then hands off to `/feature-plan` for the delta. Core principle: **edit, don't recreate** — only touched sections change.

**Contents**

- [Add a capability to a shipped feature](#add-a-capability-to-a-shipped-feature)
- [Remove a deprecated capability](#remove-a-deprecated-capability)

---

## Add a capability to a shipped feature

The most common update shape: an existing feature gains a new requirement. The user wants minimal churn — just enough doc changes to plan the new work.

### Setup

`team-invites` shipped at `spec_version: 1`, `status: complete`, four months ago. The CHANGELOG lists one archived plan. Customers are now asking for **bulk invitation** — uploading a CSV of email addresses to invite many people at once.

The existing spec covers single-invite flows: form, email, accept link, expiry. The bulk flow needs a new entry point but reuses the existing invitation-creation logic.

### Invocation

```
/myspec:feature-update team-invites
```

### Skill flow

#### 1. Read current state

The skill loads `spec.md` (v1, status: complete), `tech-spec.md` (`based_on_spec_version: 1`), `CHANGELOG.md` (one archived plan). Notes:

- Last shipped: 2025-12-12.
- One archived plan in `plans/`.
- No active `implementation-plan.md` — clean slate for new work.

#### 2. Understand the change

The skill asks:

> Tell me about the change. Specifically:
>
> - **What new behavior is being added?** Describe at the spec level (user-facing).
> - **What existing behavior changes?** Anything in the current spec that's affected.
> - **Constraints?** CSV size limit, throttling, billing implications, anything else.

**User**: Bulk invite via CSV upload, max 200 addresses per upload, throttle to one bulk-invite per admin per hour. No changes to existing single-invite flow. Permission-wise, only admins (not regular team members) can use bulk.

#### 3. Update spec.md

The skill edits **only the affected sections**:

- **User Stories**: appends US7 (admin uploads CSV) and US8 (admin sees per-row results). US1–US6 unchanged.
- **Acceptance Criteria**: appends AC12–AC16 covering CSV format, validation, partial-failure handling, throttle, admin-only access. AC1–AC11 unchanged.
- **Out of Scope**: adds "CSV files larger than 200 addresses" and "scheduled bulk imports."
- **Open Questions**: empty (user answered all of them).
- **Frontmatter**: `spec_version: 2`, `last_updated: 2026-04-30`, `status: draft` (was `approved`).

Existing sections (Overview, Goals) untouched.

#### 4. Update tech-spec.md

Edits affected sections only:

- **Architecture**: appends a paragraph about the bulk endpoint and worker queue (re-uses the existing notification-system queue for throttling).
- **Implementation Steps**: appends 5 new tasks (CSV parser, bulk endpoint, throttle middleware, results modal, e2e test). Existing tasks remain `[x]` from the original implementation.
- **Database Changes**: notes a new column on `invitations` — `source` enum (`single`, `bulk`) for analytics; not breaking.
- **API Endpoints**: adds `POST /api/teams/:id/invites/bulk`.
- **File Inventory**: adds 4 new files, marks 1 existing file as "Modify" (the InviteService, to factor out the per-record logic).
- **Decisions**: appends ADR-4: *"CSV parsing client-side with server-side validation rather than upload-and-parse."* Reason: small files (200 rows), simpler error UX.
- **Frontmatter**: `based_on_spec_version: 2`, `last_updated: 2026-04-30`, `status: draft`.

#### 5. Present diff summary

> **spec.md changes** (v1 → v2):
>
> - User Stories: +US7, +US8 (admin CSV upload, per-row results)
> - Acceptance Criteria: +AC12–AC16 (CSV format, validation, partial-failure, throttle, admin-only)
> - Out of Scope: +200-row limit, +scheduled imports
>
> **tech-spec.md changes**:
>
> - Architecture: +bulk endpoint + queue paragraph
> - Implementation Steps: +5 tasks (CSV parser, endpoint, throttle, results modal, e2e)
> - Database Changes: +`source` column on invitations
> - API Endpoints: +POST /invites/bulk
> - File Inventory: +4 create, +1 modify
> - Decisions: +ADR-4 (client-side parsing)
>
> Status flipped to `draft` on both files (re-approval needed). spec_version: 1 → 2.
>
> Confirm?

#### 6. User confirms, hand-off

```
yes
```

The skill ends with the cross-spec routing prompt:

> **What's next?**
>
> - **A) `/myspec:cross-spec-validation team-invites`** *(recommended)* — your update added a queue dependency that may affect `notification-system`'s contract.
> - **B) `/myspec:feature-plan team-invites`** — skip cross-check, proceed to planning.

User picks A.

### Result

`spec.md` at v2, `tech-spec.md` at v2 status `draft`, both files edited (not rewritten). The five new implementation steps are appended; the original 12 stay `[x]` from the original ship.

### Why this example matters

- **Edit, don't recreate.** A user who runs `feature-update` for a small addition shouldn't see their entire spec rewritten. The skill enforces minimal-diff edits.
- **`spec_version` bump means re-approval.** The status flip to `draft` is non-negotiable — it's how `feature-spec-review` knows there's something to look at.
- **Original implementation tasks stay `[x]`.** Don't unmark them. The new tasks land as `[ ]`. When `feature-plan` runs next, it produces a plan covering only the new tasks.
- **The cross-spec routing prompt at the end is the most useful thing this skill does.** Updates frequently break sibling features in subtle ways — the queue contract here is exactly that kind of change.

---

## Remove a deprecated capability

Less common but important: a feature loses functionality. The skill handles "remove" as a first-class operation, not just "add with negative scope."

### Setup

Feature `team-invites` has had a "magic-link" mode (no email, just a copy-pasteable URL) since v1. The team has decided to deprecate it — security review flagged that magic-links bypass email-based identity verification, and customers haven't used the feature in months.

Current state: `spec_version: 2` (after the bulk-invite update), `status: complete`, magic-link is AC-6 in the spec.

### Invocation

```
/myspec:feature-update team-invites
```

### Skill flow

#### 2. Understand the change

> Tell me about the change.

**User**: Removing the magic-link mode. AC-6 goes away, the related UI button + endpoint + service method should be marked for deletion. Reason is security review — flagging in the ADRs.

#### 3. Update spec.md

Edits:

- **User Stories**: removes US5 (magic-link). Renumbers? **No** — leaves a tombstone: *"US5 (deprecated 2026-04-30): magic-link invitations. See ADR-5 in tech-spec.md."*
- **Acceptance Criteria**: removes AC-6. Tombstone: *"AC-6 (deprecated 2026-04-30): see Out of Scope."*
- **Out of Scope**: adds *"Magic-link invitations (deprecated 2026-04-30 due to security review — see tech-spec.md ADR-5)."*
- **Frontmatter**: `spec_version: 3`, `status: draft`.

The skill explains the tombstone choice in the diff summary:

> Note: I left tombstones for US5 and AC-6 rather than deleting them outright. Pure deletions break references in older PRs, plans, and external docs ("remember the magic-link AC?"). The tombstones are one-line redirects that age into harmless context.

#### 4. Update tech-spec.md

Edits:

- **Architecture**: removes the magic-link path description.
- **Implementation Steps**: appends a new task: *"Remove magic-link UI, endpoint, service method, and related tests. Update OpenAPI spec."* (Existing magic-link `[x]` tasks are not touched — they're history.)
- **API Endpoints**: removes the `POST /invites/magic-link` row.
- **File Inventory**: marks the magic-link files for **Action: Delete**.
- **Decisions**: appends ADR-5: *"Deprecate magic-link mode."* Context: security review on 2026-04-25 flagged identity-verification bypass. Alternatives: keep + harden — rejected, complexity not worth the low usage. Consequences: any customer using magic-links must be migrated to email-based invites; outreach handled by support.
- **Frontmatter**: `based_on_spec_version: 3`, `status: draft`.

#### 5. Present diff summary

```
spec.md changes (v2 → v3):
  - Tombstoned: US5, AC-6 (one-line redirects with deprecation date)
  - Out of Scope: added magic-link entry pointing to ADR-5

tech-spec.md changes:
  - Architecture: magic-link path removed
  - Implementation Steps: +1 task (remove magic-link surface)
  - API Endpoints: -1 row (POST /invites/magic-link)
  - File Inventory: marked 4 files for Delete
  - Decisions: +ADR-5 (deprecate magic-link, security driver)

Status flipped to draft. spec_version: 2 → 3.

Confirm?
```

#### 6. User confirms, hand-off

```
yes
```

> **What's next?**
>
> - **A) `/myspec:cross-spec-validation team-invites`** *(recommended)* — removing a public endpoint may affect any feature that referenced it.
> - **B) `/myspec:feature-plan team-invites`** — proceed to planning the removal work.

User picks A. Cross-spec catches that one external-docs page mentions magic-links; user updates that doc separately.

Then `/feature-plan` runs and produces a 1-task plan: the removal task. `/feature-implement` runs it. Files deleted, tests removed, OpenAPI spec regenerated.

### Result

Spec is at v3, tombstones in place for US5 + AC-6, tech-spec drops the implementation. Magic-link code, tests, and endpoint are removed in the resulting commit.

### Why this example matters

- **Tombstones over silent deletion.** Removing a US/AC outright orphans every prior PR, comment, and ticket that referenced it. A one-line tombstone with a deprecation date is *much* easier to live with for the year after the change.
- **The Action: Delete column is real.** File Inventory tracks not just "what files exist" but "what action this iteration is taking on each." Plans pick up "Delete" actions and produce removal tasks.
- **Removal needs an ADR.** "Why did we remove this?" is the question future agents will ask if/when a customer rediscovers the feature. ADR-5 is what stops anyone from naively re-adding it.
- **Cross-spec routing matters even more for removals.** Adding a feature is a permissive change; removing one breaks anyone who depended on it. The recommended path goes through `cross-spec-validation` for exactly this reason.
