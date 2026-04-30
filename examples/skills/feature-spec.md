# `/myspec:feature-spec` — examples

Creates `spec.md` + `dependencies.md` for a new feature, and adds a manifest entry. The skill asks clarifying questions, drafts the documents, and waits for approval before writing.

**Contents**

- [Greenfield — small self-contained feature](#greenfield--small-self-contained-feature)
- [Feature with cross-feature dependencies](#feature-with-cross-feature-dependencies)
- [Skill recommends decomposing first](#skill-recommends-decomposing-first)

---

## Greenfield — small self-contained feature

A new, small feature with no dependencies. The skill walks the standard question set and produces a clean spec.

### Setup

The user wants to add a "favorite reports" capability — users star a report and it pins to the top of their list.

### Invocation

```
/myspec:feature-spec favorite-reports
```

### Skill flow

The skill reads `ai/features/index.yaml`, confirms the slug is unused, then asks:

> 1. **Scope** — does favoriting persist across devices, or stay per-device?
> 2. **Limits** — is there a max number of favorites per user?
> 3. **UI placement** — star icon in the report list row, the report header, or both?
> 4. **Out of scope** — sharing a favorite list with other users? Tagging?

**User**: per-account; no limit; star in list row only; sharing/tagging out of scope.

The skill drafts `spec.md`:

```yaml
---
title: "Favorite Reports"
status: draft
phase: 1
priority: P2
spec_version: 1
created: 2026-04-30
last_updated: 2026-04-30
---
```

Required sections all present — Overview, Goals, User Stories (US1 star, US2 unstar, US3 favorites pin to top), Acceptance Criteria (AC1–AC5), Out of Scope (sharing, tagging, max count), Open Questions (none).

`dependencies.md` is short — no feature deps, just a one-liner external dep on the existing `react-icons` star glyph.

Manifest row added:

```yaml
- name: favorite-reports
  title: "Favorite Reports"
  status: draft
  phase: 1
  priority: P2
  depends-on: []
```

### User confirms

```
yes, looks good
```

### Result

Files written, manifest updated. The skill ends with a hand-off line:

> **Next:** `/myspec:feature-spec-review favorite-reports` — validate the spec before tech-spec.

### Why this example matters

The simplest path: 4 questions, 1 draft, 1 approval. No back-and-forth, no decomposition signal. Most small features look like this.

---

## Feature with cross-feature dependencies

A new feature that needs to coordinate with existing features. The skill notices the dependency and populates `dependencies.md` bidirectionally.

### Setup

User wants to add **scheduled reports** — recurring auto-generated reports delivered via email. The codebase already has a `notification-system` feature (shipped) and an `email-templates` feature (in-progress).

### Invocation

```
/myspec:feature-spec scheduled-reports
```

### Skill flow

The skill reads `index.yaml`, sees `notification-system: complete` and `email-templates: in-progress`. Notes both as **likely dependencies**. After scope questions:

> Two questions about cross-feature integration:
>
> - This feature delivers reports via email. Does it call into `notification-system` to send, or does it implement its own delivery?
> - Reports use templating. Does it use the templates from `email-templates`, or its own format?

**User**: yes use notification-system; reuse email-templates rendering.

The skill drafts:

**spec.md** — frontmatter `priority: P1`, plus an explicit assumption in Open Questions:

```markdown
## Open Questions

- Confirmed: scheduled-reports calls `notification-system` for delivery; falls under the queued-notification SLA (up to 60s deferred).
- `email-templates` must support the "scheduled-report" template variant before this feature ships.
```

**dependencies.md**:

```markdown
## Feature Dependencies (this feature requires)

- `notification-system` — used for queued email delivery. Hard dependency.
- `email-templates` — provides the report email template. Hard dependency. Note: `email-templates` is currently in-progress; this feature blocks on its completion.

## Dependent Features (require this feature)

(none yet)

## External Dependencies

- `cron-parser` (npm) — to validate cadence presets server-side.
```

**Manifest entry**:

```yaml
- name: scheduled-reports
  title: "Scheduled Reports"
  status: draft
  phase: 1
  priority: P1
  depends-on: [notification-system, email-templates]
```

The skill **also asks the user**:

> Should I update `notification-system/dependencies.md` and `email-templates/dependencies.md` to add scheduled-reports as a dependent feature?

**User**: yes.

The skill edits the bidirectional links so `notification-system/dependencies.md` now lists `scheduled-reports` under "Dependent Features."

### User confirms

```
approved
```

### Result

Three files modified: new `scheduled-reports/{spec.md, dependencies.md}` written; existing `notification-system/dependencies.md` and `email-templates/dependencies.md` updated.

### Why this example matters

- **Bidirectional dependency links** — the skill's verification checklist requires consistency, so it asks before editing the upstream features. Without this, the manifest drifts immediately.
- **Surfacing in-progress dependencies** — flagging that `email-templates` is in-progress is what stops the user from approving and immediately starting tech-spec for a feature that can't ship yet.
- **Open Questions is load-bearing** — it captures the assumed contracts (60s delivery SLA, template variant must exist) that `cross-spec-validation` will later check.

---

## Skill recommends decomposing first

The user describes a feature that's actually three features in a trench coat. The skill notices and routes to `feature-decompose` rather than producing one bloated spec.

### Setup

User says: *"Add team workspaces — multi-tenant orgs, user roles, billing per workspace, workspace-level audit logs, and a workspace switcher in the header."*

### Invocation

```
/myspec:feature-spec team-workspaces
```

### Skill flow

The skill scopes the request and notices five distinct capability areas: tenancy/data model, RBAC, billing, audit logs, UI switcher. Each could be its own spec. Before drafting, the skill flags it:

> Heads up — what you described looks like multiple distinct capabilities:
>
> 1. Tenancy / data model (workspace entity, scoping)
> 2. Role-based permissions
> 3. Per-workspace billing
> 4. Audit logs
> 5. Workspace switcher UI
>
> A single spec covering all five would be hard to review and would produce a tech-spec with 25+ implementation steps (above the recommended ceiling).
>
> Two paths:
>
> - **A) Single umbrella spec** — write one `team-workspaces/spec.md` now, then immediately decompose with `/myspec:feature-decompose team-workspaces`. The umbrella doc captures the cross-cutting goals; sub-features carry the per-area specs.
> - **B) Stop here** — pick the foundational capability first (likely tenancy/data model), spec just that, ship it, then add the rest as separate features.
>
> Which would you like?

**User**: option A — write the umbrella, then decompose.

### Skill flow (continued)

The skill writes a deliberately thin umbrella spec — Overview, cross-cutting Goals, a placeholder Sub-Features table, and a single sentence per capability area. **No detailed user stories or acceptance criteria** at this level — those live in the sub-feature specs after decomposition.

Frontmatter:

```yaml
status: draft
phase: 1
priority: P0
spec_version: 1
note: "Umbrella spec; decompose before tech-spec phase."
```

`dependencies.md` is also umbrella-level — captures dependencies that apply to all sub-features.

### Result

Umbrella `spec.md` + `dependencies.md` written. The skill's hand-off line:

> **Next:** `/myspec:feature-decompose team-workspaces` — split this into per-capability sub-features before any tech-spec work.

### Why this example matters

- **Routing, not just authoring** — when the skill recognizes a poor fit, it offers a different path instead of plowing ahead. Saves the user from a 30-criterion spec that no human will read.
- **The umbrella pattern** is intentional: keeps the cross-cutting context in one place, defers the per-capability detail until decomposition. See [flows/feature-decomposition.md](../flows/feature-decomposition.md) for the rest of this pipeline.
- **Spec scope is detected from input shape**, not feature size. A small feature with 10 acceptance criteria is fine. A feature with 5 distinct capability areas is the trigger for decomposition.
