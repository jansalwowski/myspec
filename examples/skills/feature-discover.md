# `/myspec:feature-discover` — examples

Reverse-engineers an undocumented feature from existing code into structured documentation. Always produces `discovery.md`; optionally also `spec.md` + `tech-spec.md`. Use this skill **only** when the code exists but no spec does.

**Contents**

- [Discovery only — capturing tribal knowledge](#discovery-only--capturing-tribal-knowledge)
- [Full feature docs — pulling code into the pipeline](#full-feature-docs--pulling-code-into-the-pipeline)
- [Complex feature routes to decomposition](#complex-feature-routes-to-decomposition)

---

## Discovery only — capturing tribal knowledge

Code that's been in production for a year, no docs, original author has left. The user just wants the knowledge captured before they lose it — not a full feature spec.

### Setup

The user points at `src/billing/dunning/` and says: *"This is the dunning flow — chasing failed payments. Nobody really knows how it works anymore. Can we get it written down?"*

### Invocation

```
/myspec:feature-discover
```

### Skill flow

The skill asks for what's missing:

> What feature are we documenting? What does it roughly do?

**User**: payment dunning — when a card charge fails, we retry on a schedule and notify the user. Files are in `src/billing/dunning/`.

The skill explores: reads the directory, traces imports outward, greps for `dunning` across the repo. After ~15 minutes of exploration it has the full picture — entry points, retry scheduler, notification calls, two feature flags, three i18n keys. It also finds calls to a Stripe webhook handler and an internal `risk-score` service that aren't obviously part of the feature.

**Grouped Q&A** (not one question at a time):

> Exploration complete. Before writing up findings, here are some questions grouped by topic:
>
> **External integrations:**
> 1. The retry scheduler calls `/internal/risk-score` — is that part of dunning, or just an unrelated check that happens to live in this code path?
> 2. There's a Stripe webhook handler at `src/billing/dunning/webhooks/charge-failed.ts` — should this be in scope or treated as a separate billing-webhooks feature?
>
> **Business logic:**
> 3. The retry intervals are hard-coded as `[1, 3, 7]` days — is that an intentional product decision or a leftover from a prototype?
> 4. `MAX_DUNNING_AGE_DAYS = 21` — what happens after day 21? I see the row gets flagged but no obvious downstream consumer.

**User**: risk-score is in scope (we skip dunning for high-risk users); webhooks are in scope; intervals are intentional (product decision Q3 last year); after day 21 the subscription gets cancelled by a separate nightly job.

### Confirmation

The skill presents the full findings summary — entry points, all 14 files involved, behavior walkthrough, integrations (risk-score, Stripe, notification-system), 2 feature flags, 3 translations, 1 remaining open question (the nightly cancellation job lives outside this feature — track it separately?).

**User**: looks right.

### Output decision

> A) Discovery only — save to `.ai/discoveries/2026-04-30-payment-dunning/`
> B) Full feature docs — save to `.ai/features/payment-dunning/` with spec.md + tech-spec.md
> C) Both

**User**: A — just the discovery for now.

### Result

One file written: `.ai/discoveries/2026-04-30-payment-dunning/discovery.md`. No `index.yaml` update. No `spec.md`, no `tech-spec.md`.

The hand-off line:

> **Discovery saved.** When you're ready to bring this into the feature pipeline, re-run `/myspec:feature-discover` with option B or C and reference this discovery file.

### Why this example matters

- **Discovery is the durable checkpoint** — it gets written immediately after confirmation, before the output-location decision. Even if the user closes the laptop after this step, the knowledge is captured.
- **Grouped Q&A, not drip-feed** — the skill collected unknowns during exploration and asked them in batches. Asking one question at a time would have stretched this into a 90-minute session.
- **Option A is the right call when knowledge is partial** — the user knew the feature but didn't want to commit to the full spec/tech-spec pipeline. Forcing B here would have produced a low-quality spec and a tech-spec full of `Action: exists` rows nobody asked for.

---

## Full feature docs — pulling code into the pipeline

The team is about to modify a feature that was built before myspec existed. They need it in the feature pipeline so the upcoming work has somewhere to land.

### Setup

The codebase has a `report-export/` module (CSV + PDF export of saved reports) — shipped 18 months ago, never specced. The team is about to add Excel export and wants the existing feature documented first so the new capability slots in cleanly.

### Invocation

```
/myspec:feature-discover report-export
```

The user provides paths up front: `src/reports/export/`, `src/api/exports/`.

### Skill flow

Because paths were provided, the skill skips the description prompt and goes straight to exploration. It traces:

- Entry point: `ExportButton.vue` in the report header
- Pinia store: `useExportStore` with `exportAsCSV`, `exportAsPDF` actions
- API: `POST /api/exports` with `{format, reportId}` payload
- Background job: `GenerateExportJob` in the worker
- Storage: signed S3 URLs returned to the client
- Notification: email when export ready
- One feature flag: `EXPORT_PDF_ENABLED` (gates PDF only; CSV always on)

**Grouped Q&A** (only 2 unknowns surfaced):

> **External integrations:**
> 1. Exports are written to S3 bucket `prod-report-exports` — is the bucket lifecycle (30-day expiry) part of this feature or managed separately by infra?
>
> **Business logic:**
> 2. PDF generation uses a Lambda at `arn:...:report-pdf-renderer` — is that Lambda owned by this team or by the platform team?

**User**: bucket lifecycle is infra-owned (out of scope for the feature); Lambda is ours but lives in a separate repo (note as external dependency).

### Confirmation

Findings summary presented — clean. **User**: confirmed.

### Complexity check

Two formats, one entry point, one storage destination, one notification path. Below the decomposition threshold. The skill notes this and proceeds without flagging.

### Output decision

**User**: B — full feature docs.

### Result

Five files written:

```
.ai/features/report-export/
  discovery.md        # The full reverse-engineering record
  spec.md             # Generated from discovery — Goals, User Stories (US1 CSV, US2 PDF), Acceptance Criteria
  tech-spec.md        # File Inventory uses Action: exists for all 12 discovered files
  dependencies.md     # External: report-pdf-renderer Lambda; S3 bucket (infra-owned)
```

Plus one row added to `.ai/features/index.yaml`:

```yaml
- name: report-export
  title: "Report Export"
  status: shipped         # not "draft" — this code is in production
  phase: 1
  priority: P1
  depends-on: []
  origin: discovered      # marker that this was reverse-engineered
```

The hand-off line:

> **Next:** `/myspec:feature-spec-review report-export` to validate the generated spec, then `/myspec:feature-update` for the Excel export work.

### Why this example matters

- **`tech-spec.md` File Inventory is `Action: exists` everywhere** — this is the rule that distinguishes a discovery-driven tech-spec from a greenfield one. No phantom `add` or `create` actions for code that already shipped.
- **Status is `shipped`, not `draft`** — the spec describes existing code, so it goes into the manifest at the right lifecycle stage. The pending Excel work will be a `feature-update`, not a fresh `feature-spec`.
- **Discovery → spec is a real synthesis step**, not a copy-paste — the skill uses the exploration findings as source material to write proper user stories and acceptance criteria. Open Questions from discovery carry through into the spec untouched.

---

## Complex feature routes to decomposition

The user points at a sprawling area of the codebase. The skill explores, finds it's actually four loosely coupled capabilities, and stops to recommend decomposition before generating a 30-criterion umbrella spec.

### Setup

The user says: *"Document the admin panel — `src/admin/`. Nobody knows the full scope anymore."*

### Invocation

```
/myspec:feature-discover admin-panel
```

### Skill flow

Exploration takes a while — `src/admin/` contains:

1. **User management** — list/edit/disable users, password resets, role assignment
2. **Audit log viewer** — searchable log of admin actions, with CSV export
3. **Feature flag dashboard** — runtime toggles, per-environment, with approval workflow
4. **Billing override tools** — comp credits, refund issuance, subscription edits

Plus three external integrations (Stripe, Auth0, an internal flag service) and 14 feature flags of its own.

### Grouped Q&A

The skill batches questions across all four areas, not per-area. **User** answers; everything is in scope.

### Confirmation

Findings summary presented. **User**: confirmed.

### Complexity check — triggers

Decomposition threshold met:

- 4 distinct capabilities, each shippable independently ✓ (>3)
- Integrations with 3 different external services ✓ (>2)

The skill stops before the output-decision step:

> This feature looks large enough to benefit from decomposition.
>
> I see 4 distinct capabilities:
> 1. User management
> 2. Audit log viewer
> 3. Feature flag dashboard
> 4. Billing override tools
>
> An umbrella spec covering all four would produce ~30 acceptance criteria and a tech-spec referencing 60+ files. That's hard to review and harder to keep in sync.
>
> Would you like to decompose into sub-features? If yes, I'll write `discovery.md` first (single source of truth), then follow `feature-decompose` using the discovery as source material instead of a spec.

**User**: yes, decompose.

### Result — discovery first, then decomposition

The skill writes `discovery.md` to `.ai/discoveries/2026-04-30-admin-panel/discovery.md` — the full record of what was found, all four capability areas in one document.

Then it hands off into the decompose flow:

> **Proceeding with feature-decompose.**
> Suggested sub-feature boundaries based on discovery:
> - `admin-user-management`
> - `admin-audit-log`
> - `admin-feature-flags`
> - `admin-billing-overrides`
>
> Each will get its own `spec.md` + `tech-spec.md` (status: shipped, origin: discovered) under `.ai/features/`. The discovery file stays as the umbrella record.
>
> Shall I proceed?

**User**: yes.

The decompose skill takes over. Final state:

```
.ai/discoveries/2026-04-30-admin-panel/discovery.md   # umbrella record
.ai/features/admin-user-management/{spec.md, tech-spec.md, dependencies.md}
.ai/features/admin-audit-log/{spec.md, tech-spec.md, dependencies.md}
.ai/features/admin-feature-flags/{spec.md, tech-spec.md, dependencies.md}
.ai/features/admin-billing-overrides/{spec.md, tech-spec.md, dependencies.md}
```

Four manifest rows added, all `status: shipped`, `origin: discovered`.

### Why this example matters

- **Discovery happens before decomposition, never instead of it** — the umbrella discovery is the source of truth that the decomposition draws from. Without it, each sub-feature would be re-discovered in isolation and the cross-cutting context would be lost.
- **The complexity check fires after exploration, not before** — the skill needs to actually see the code to know whether decomposition is warranted. Pre-judging from a one-line user description (*"document the admin panel"*) would route some genuinely simple features through unnecessary decomposition.
- **Output-decision step is skipped when decomposition wins** — if the user agrees to decompose, the skill goes straight to writing discovery.md + handing off, rather than asking "A / B / C." Decomposition implies option B (full feature docs) by definition, just split across multiple feature directories.
