# Tables — Admin List Patterns

Load when mockup renders a tabular data view: a native `<table>`, a component-library table/data-grid, an admin list with row-end actions, sortable columns, or any data grid with > 3 columns.

These are the patterns most likely to be missed or done inconsistently in admin-heavy products.

## Column / row mechanics
- **Sort indicator** — sortable columns show a direction triangle next to the label; the current sort column is visually distinct (filled vs hollow). Clicking re-toggles asc / desc / off (3-state).
- **Sticky headers** — for tables scrollable past one viewport, the header row sticks to the top of the scroll container. Mocked as `position: sticky; top: 0` or equivalent.
- **Column truncation + tooltip** — long cell values truncate with `...` and reveal full value via `title` attribute on hover. Bare truncation hides data (see states.md).
- **Row hover affordance** — interactive rows show a hover background (the design system's inset/hover surface token) so the user knows the row is clickable / actionable.
- **Density toggle** — for tables consumed in both browse and audit contexts, offer a compact / comfortable / spacious toggle. Pin the choice in localStorage (production), not session.
- **Empty / loading rows** — render skeleton rows (matching column count) on load, not a page-level spinner. Empty table shows the empty state inside the table, not below.

## Row actions
- **Row-end placement** — single primary action goes in the last column as a button (Edit / View). 2-3 secondary actions go into an overflow menu (kebab `⋮` icon). More than 3 actions = the row needs its own detail view.
- **Action click target ≥ 32×32** — dense tables routinely use 24×24 icon buttons; that's below Fitts's Law minimum. Pad or enlarge.
- **Destructive row actions** — Delete / Archive / Deactivate always behind a confirmation modal (see core.md error prevention). Never a one-click trash icon that nukes the row.

## Bulk selection / actions
- **Selection column** — checkbox in the first column; header checkbox toggles select-all-on-page (NOT select-all-matching-filter, which is a separate action).
- **Bulk toolbar appears when selection > 0** — slides in above the table; shows count ("3 selected"), bulk actions (Archive / Delete / Tag), and a Clear-selection button. When selection drops to 0, toolbar disappears.
- **Select-all-on-page vs select-all-matching-filter** — header checkbox = page; explicit "Select all 247 matching" link inside the toolbar = filter. Always offer both for large datasets.
- **Bulk action confirmation** — Modal lists the count and a sample of names ("Delete 3 guides: 'Italy A0', 'France A1', 'Spain A2'?"). Never just "Delete 3 items?" — names anchor the action.

## Filter rail / search
- **Filter persistence** — filter state survives in-feature navigation (open an item, come back) via URL or in-memory; not localStorage. Clearing requires explicit action.
- **Filter count badge** — chips show `{Status: Draft (12)}`; the count is the visible item count under that filter, updated live.
- **Clear all** — when ≥ 2 filters active, show a "Clear all" link. Never make the user clear chips individually.
- **Zero results inside table** — different copy from generic empty; references the active filters and offers "Clear filters" as the recovery CTA.
