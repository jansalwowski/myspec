# `/myspec:feature-decompose` — examples

Splits a too-large feature into modular sub-features. The skill analyzes existing `spec.md` (and `tech-spec.md` if present), proposes a sub-feature structure, and creates the directory layout after user confirmation.

> **Note**: For the full multi-skill flow that follows decomposition (per-sub-feature tech-spec, plan, implement), see [flows/feature-decomposition.md](../flows/feature-decomposition.md). The scenarios here focus on the decompose skill itself.

**Contents**

- [Mixed-priority split with deferred sub-features](#mixed-priority-split-with-deferred-sub-features)
- [Skill refuses — feature shouldn't be decomposed](#skill-refuses--feature-shouldnt-be-decomposed)

---

## Mixed-priority split with deferred sub-features

Realistic decomposition: not every capability area becomes a sub-feature on day one. Some go straight to `ideas/` for later.

### Setup

A feature `notifications-v2` is sitting at `status: draft` after an ambitious spec. It covers in-app toast notifications, email digests, push notifications (web + mobile), Slack integration, and notification preferences UI. Five capability areas, ~28 acceptance criteria.

The team only needs in-app toasts and notification preferences for the next release. Email digests are P2. Push and Slack are nice-to-have for next quarter.

### Invocation

```
/myspec:feature-decompose notifications-v2
```

### Skill flow

The skill reads `notifications-v2/spec.md`, identifies capability clusters by scanning user-story headings and acceptance criteria phrasing. Proposes:

```markdown
## Proposed Sub-Features for `notifications-v2`

### Sub-Feature 1: notifications-toasts
- **Status**: draft
- **Priority**: P1
- **Description**: In-app toast notifications surfaced via a top-right
  notification center.
- **Content from parent**:
  - User stories: US1, US2
  - Requirements: REQ1, REQ2, REQ3
  - Scenarios: S1, S2

### Sub-Feature 2: notifications-preferences
- **Status**: draft
- **Priority**: P1
- **Description**: User-facing settings panel for notification channels
  and per-event preferences.
- **Depends on**: notifications-toasts
- **Content from parent**:
  - User stories: US3
  - Requirements: REQ4, REQ5
  - Scenarios: S3

### Sub-Feature 3: notifications-email-digest
- **Status**: draft
- **Priority**: P2
- **Description**: Daily/weekly email digest of unread notifications.
- **Depends on**: notifications-preferences (channel toggle)
- **Content from parent**:
  - User stories: US4
  - Requirements: REQ6, REQ7
  - Scenarios: S4

### Deferred (not yet split out — written to ideas/ instead)
- notifications-push (web + mobile) — too speculative, push permission UX still being designed.
- notifications-slack — depends on a marketing partnership that may not happen.

### Parent Feature Changes
- `notifications-v2/spec.md` becomes the umbrella: status `in-progress`,
  Sub-Features table added, per-capability detail removed.
- The umbrella captures shared invariants (notification entity shape,
  delivery audit log) that apply across all sub-features.
```

### User confirms with edits

```
yes, but bump notifications-email-digest to P2 status and write the deferred ones to ideas/
```

### Skill flow (continued)

The skill:

1. Creates `ai/features/notifications-v2/{notifications-toasts, notifications-preferences, notifications-email-digest}/` with `spec.md` and `dependencies.md` per sub-feature.
2. Rewrites the parent `spec.md` as an umbrella doc with the Sub-Features table.
3. Creates `ai/features/notifications-v2/index.yaml` listing the three sub-features.
4. Updates the top-level `ai/features/index.yaml`: parent flips to `status: in-progress` and references the per-feature index.
5. Writes `ideas/notifications-push.md` and `ideas/notifications-slack.md` as one-paragraph stubs that reference the parent.
6. Adds those two ideas to `ideas/PRIORITY-LISTING.md` under **LOW** with a note pointing back at `notifications-v2`.

### Result

```
ai/features/notifications-v2/
├── spec.md                            # umbrella, status: in-progress
├── dependencies.md                    # cross-cutting deps
├── index.yaml                         # lists 3 sub-features
├── notifications-toasts/
│   ├── spec.md                        # status: draft, P1
│   └── dependencies.md
├── notifications-preferences/
│   ├── spec.md                        # status: draft, P1
│   └── dependencies.md
└── notifications-email-digest/
    ├── spec.md                        # status: draft, P2
    └── dependencies.md

ideas/
├── notifications-push.md              # stub for later
└── notifications-slack.md             # stub for later
```

The skill ends with:

> **Next:** start with `notifications-toasts` (P1, no dependencies). Run `/myspec:feature-tech-spec notifications-v2/notifications-toasts` when ready.

### Why this example matters

- **Not everything has to become a sub-feature.** Capabilities that aren't ready (push permissions UX undefined, Slack contingent on a partnership) belong in `ideas/`, not in your active feature tree. The skill respects this.
- **Mixed priorities are normal.** The agent doesn't force all sub-features into the same priority bucket — it carries through what the user picks.
- **Bidirectional manifest updates** — both `index.yaml` files (top-level and per-feature) land in a consistent state. Skipping this is what causes "ghost sub-features" later.
- **The umbrella spec keeps cross-cutting invariants.** The notification entity shape and audit-log requirement apply to all three sub-features — those live in the umbrella, not duplicated in each child.

---

## Skill refuses — feature shouldn't be decomposed

Decomposition can be wrong. The skill is supposed to recognize when a feature *looks* big but actually has tightly-coupled internals that would just create artificial seams.

### Setup

Feature `pricing-engine` has a large spec — 18 acceptance criteria — but every capability is part of the same evaluation pipeline: rule loading, rule evaluation, output formatting, caching, observability. They all run in the same hot path and share the same core types.

User runs:

```
/myspec:feature-decompose pricing-engine
```

### Skill flow

The skill reads `spec.md` and `tech-spec.md`. Notices:

- The "capabilities" all appear in a single `evaluate()` call chain.
- All five potential sub-features would import from the same `PricingContext` and `Rule` types.
- The implementation steps in `tech-spec.md` are ordered as a single pipeline — no clean parallel groups.
- File inventory shows ~80% of work touches `src/pricing/engine.ts` and its co-located types.

The skill responds:

> I read `pricing-engine/spec.md` and `tech-spec.md` and I don't think this should be decomposed. Reasons:
>
> 1. **Shared core type** — every capability uses `PricingContext` and `Rule`. Sub-features would all need to import from a still-monolithic core, defeating the purpose.
> 2. **Single hot path** — capabilities aren't independently invokable; they execute as steps in `evaluate()`. Splitting them adds artificial seams.
> 3. **File overlap** — 11 of 14 implementation steps touch `src/pricing/engine.ts`. Sub-feature tech-specs would all claim the same file, which `feature-plan` won't be able to parallelize.
>
> Decomposition pays off when capabilities have **disjoint files** and **independent invocation**. Neither holds here.
>
> Suggested alternatives:
>
> - **A) Keep as one feature.** Run `/myspec:feature-plan` and let it produce a single milestone-scoped plan. The 14-task ceiling still applies, but a tightly-coupled feature is the right place to use it.
> - **B) Phase the work.** If the feature is too big to *ship* in one go, split by **time** rather than capability — e.g., a `pricing-engine-v1` (rule loading + evaluation) and a follow-up `pricing-engine-observability` (caching + observability). That's a `feature-update`/follow-up shape, not a decomposition.
>
> Want me to proceed with one of these, or override and decompose anyway?

### User responds

```
go with B — let's just do v1 now
```

### Skill flow (continued)

The skill does **not** call decomposition. It instead:

1. Edits `pricing-engine/spec.md` — moves caching + observability sections to **Out of Scope**, adds a note: *"Tracked for v2 in ideas/pricing-engine-observability.md."*
2. Bumps `spec_version` to 2 and `status: draft` (re-approval needed).
3. Creates `ideas/pricing-engine-observability.md` with the deferred content.
4. Adds an idea entry to `PRIORITY-LISTING.md`.

The skill ends with:

> Updated `pricing-engine/spec.md` to v2 — scope tightened to v1 (rule loading + evaluation). Run `/myspec:feature-spec-review pricing-engine` to re-approve, then proceed with `/myspec:feature-tech-spec` (no decomposition).

### Why this example matters

- **The skill has the right to refuse.** Forcing decomposition on a tightly-coupled feature creates more drift than it prevents — three sub-features all editing `engine.ts` is worse than one feature that edits it.
- **Decomposition signal is file overlap, not user-story count.** The skill checks `tech-spec.md` file inventory specifically for this. If a feature *only* has a spec (no tech-spec yet), the skill leans more conservative.
- **Phasing-by-time** is a valid alternative to decomposition. Especially good for performance/observability work that's incremental on top of a v1.
- **Override is available** — the user can still force decomposition, but the skill makes them confirm. That's the right default.
