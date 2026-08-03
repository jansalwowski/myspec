# Admin / Dashboard — SaaS Failure Modes + Feedback Patterns

Load when audience = admin (per dossier). Admin UIs are usually the densest part of a product; these are the failure modes most likely to ship.

## SaaS-specific failure modes
- **Information overload / clutter** — too many widgets visible without prioritization; the #1 SaaS dashboard failure mode. Reduce to ≤ 7 equal-weight regions per view; demote secondary widgets behind tabs / collapses.
- **Hidden important features** — frequent actions (export, filter, bulk, search) buried > 2 clicks deep. Surface frequent actions in primary chrome.
- **Weak visual hierarchy** — everything the same size / weight → no visual entry point. F-pattern or Z-pattern layout; primary CTA visually heaviest.
- **One-size-fits-all role views** — admin / moderator / operator see the same surface despite different concerns. When the spec defines multiple roles, the mockup needs role-conditional regions.
- **Mobile responsiveness skipped** — admin tools get phone / tablet use even in B2B contexts. If dossier said desktop+mobile, verify mobile layout exists (stack, hide non-essential, simplify dense tables).
- **No undo for destructive admin actions** — bulk delete / archive / role-revoke must offer a toast-with-Undo for at least 5s after the action. Beyond that, a "Recently deleted" view for 30-day recovery.

## Post-mutation feedback patterns
After every admin mutation (create / update / delete / publish / archive), the UI must confirm the outcome. These are the patterns:

- **Toast — success** — top-right slide-in, auto-dismiss 3–5s, names what happened ("Guide 'Italy A0' archived"). For undoable actions, include an Undo button; toast persists until clicked or 5s elapse.
- **Toast — error** — same position, persists until dismissed (never auto-dismiss errors), names the cause + recovery ("Couldn't archive — 3 sections still reference it. View references."). Action button when applicable.
- **Toast — warning** — orange variant, auto-dismiss 5–7s, names the concern + suggested action. Pre-action warnings go in a modal, not a toast.
- **Toast stacking** — max 3 toasts visible; older ones FIFO. Newer toasts push older up.
- **Inline status indicators** — for fields with autosave, show "Saving…" / "Saved" / "Failed" inline next to the field, not as a toast. Toasts are for actions; inline is for ambient state.
- **Banner for system-wide state** — feature flag rollouts, scheduled maintenance, data import in progress. Top-of-page banner, dismissable (or persistent for hard-state).
- **Bulk action result** — confirmation modal shows the count + sample names BEFORE the action; toast shows the result count AFTER ("3 of 5 guides archived. 2 failed — view details.").

## Other admin patterns worth checking
- **Permissions / read-only mode** — when the user lacks permission, hide the action OR show it disabled with a tooltip explaining the role required. Pick one policy and apply consistently across the feature.
- **"Last updated" / "Last edited by"** — admin lists benefit from showing recency + actor; absent timestamp / author makes audit hard.
- **Search-as-you-type vs explicit submit** — for power-user search bars in admin, prefer search-as-you-type with debounce (250–400ms); explicit submit for slow or expensive queries.
