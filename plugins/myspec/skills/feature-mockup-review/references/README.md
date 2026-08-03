# UX Heuristics Catalog — Load-trigger Index

Read this index when entering Group D (UX & Design Quality) of `/myspec:feature-mockup-review`. Load the always-load files unconditionally; load conditional files only when the trigger fires for the mockup under review.

| File | Always load? | Load trigger |
|---|---|---|
| [core.md](./core.md) | **Yes** | Nielsen's 10 + Laws of UX — universal cognitive/perceptual rules; apply to every surface |
| [accessibility.md](./accessibility.md) | **Yes** | WCAG-lite — every surface gets a11y review (labels, focus, contrast, keyboard, touch targets) |
| [forms.md](./forms.md) | Conditional | Mockup contains form elements (native inputs/textareas/selects, any component-library input primitive) or inline-edit patterns |
| [states.md](./states.md) | Conditional | Mockup is data-driven (renders list/grid/table/card collection) OR has multi-state interactive surface (quiz, edit flow, async action). Includes empty/loading/error + state-machine completeness + data-stress edge cases |
| [tables.md](./tables.md) | Conditional | Mockup renders a tabular data view (native table, component-library table/data-grid, admin list with row-end actions, sortable columns) |
| [dark-patterns.md](./dark-patterns.md) | Conditional | Audience = end-user (per dossier) OR surface is consent / sign-up / pricing / donate / marketing / nudge |
| [admin-dashboard.md](./admin-dashboard.md) | Conditional | Audience = admin (per dossier). Includes SaaS-specific failure modes + post-mutation feedback patterns (toasts, banners) |

## Cross-cutting patterns

A few patterns straddle catalogs. Each lives in its primary home below; the other catalog references it:

| Pattern | Primary | Also relevant in |
|---|---|---|
| Color-not-only error | accessibility.md | forms.md |
| Disabled-state explanation tooltip | forms.md | accessibility.md |
| Confirmation modal copy | core.md (error prevention) | admin-dashboard.md (bulk actions) |
| Touch target size | accessibility.md | tables.md (row-action targets) |

## Adding a new catalog

When a recurring review pattern doesn't fit any existing catalog, add a new file here and an entry in the table above. Keep each catalog under ~70 lines; one-line pattern + one-line detection cue per entry.
