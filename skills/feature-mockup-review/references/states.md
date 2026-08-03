# States — Empty / Loading / Error + State Machine + Data Stress

Load when mockup is data-driven (renders list / grid / card collection) OR has a multi-state interactive surface (quiz player, edit flow, async action).

These three states are the **highest-leverage UX investment** for any data-driven surface — verify presence for every async surface.

## Empty / Loading / Error
- **Empty** — Status + Action ("No projects yet. Create your first project") or Benefit + CTA ("Start organizing your photos. Upload now."). Never bare "No data."
- **Empty: first-use vs zeroed** — first-use empty (haven't started yet) needs a different CTA than zeroed empty (had data, deleted it all). Different copy, possibly different illustration.
- **Empty: zero search results** — distinct from generic empty; needs "No matches for 'X' — try different filters" and a "Clear filters" affordance.
- **Loading** — skeleton screens for content-shaped loads (cards, table rows); spinners only for < 1s indeterminate; progress bars for known-duration uploads/imports.
- **Loading granularity** — page-level (whole skeleton) vs region-level (one card loading, others stable) vs optimistic (instant + rollback). Pick deliberately per surface.
- **Error** — explain what + offer next step (Retry / fall back / contact). Avoid technical codes in user-facing copy ("Couldn't load items — try again" beats "Error 500: backend timeout").
- **Error granularity** — field-level (form), section-level (one card failed), page-level (5xx), network-offline. Each tier has different copy and retry semantics.

## State machine completeness
For each interactive surface with multiple states (quiz player, edit flow, multi-step submission), verify every reachable state is mocked:
- **Idle / initial** — the entry state before user interaction
- **In-progress / mid-flow** — user has started but not finished
- **Submitting / saving** — async write in flight; UI typically disabled
- **Saved / committed** — write succeeded; success indicator visible briefly
- **Conflict / rolled-back** — write failed mid-flight; user sees rollback + reason
- **Retrying** — user-triggered retry after error; distinguish from initial loading

Illegal transitions should be visually impossible (greyed out, hidden, or guarded by confirm).

## Data stress edge cases
Realistic sample data is required, but specifically verify the layout survives:
- **Max-length strings** — 200-character title, 80-character name, full-paragraph description in a card row. Does it truncate gracefully with a tooltip, or break the layout?
- **Zero items** — render the empty state, not a 0-row table
- **One item** — pluralization correct? Spacing not weird with a single row/card?
- **Very large numbers** — 1,234,567 → "1.2M" with the precise value in a tooltip
- **Unicode** — names with emoji 🎯, RTL characters within mixed content, combining marks, very-wide CJK characters. Does the cell width adapt or clip?
- **Currency / unit formatting** — "1 234,56 €" vs "$1,234.56" — pick a format and stick to it; currency symbol leads or trails per locale.
- **Long names need truncation + tooltip** — truncating mid-word with `...` requires a `title` attribute showing the full value on hover. Bare truncation hides data.
