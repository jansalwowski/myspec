# Accessibility — WCAG-lite

Always load. Every surface needs an a11y review; a design system's semantic tokens usually satisfy contrast by default, but the other dimensions still need checking.

- **Programmatic label association** — `<label for="...">` matches `<input id="...">`; visual proximity is not enough. Screen readers need the HTML connection.
- **Focus visible** — keyboard focus has a clear, contrasted ring. Never `outline: none` without a replacement. Tab order matches visual reading order.
- **Color contrast ≥ 4.5:1** — body text and primary buttons. Design-system text tokens typically pass by default (verify against the project's token docs); custom colors do not.
- **Color-not-only signal** — error states need icon + text + (optional) red border; never red border alone. Status badges pair color with text or icon.
- **Touch target ≥ 32×32 desktop / 44×44 mobile** — Fitts's Law in WCAG terms. Row-end action buttons in dense tables are the common offender.
- **Keyboard reachability** — every interactive surface reachable by Tab; every modal dismissable by Esc; menus navigable with arrow keys.
- **ARIA roles only when semantic HTML can't express the intent** — prefer `<button>` over `<div role="button">`. Matches the navigation-is-a-link hard guard.
- **Alt text on informative images** — empty `alt=""` for decorative only. Map / chart surfaces need a text alternative or `aria-label` summarizing the data.
- **Hover ≠ only access path** — anything reachable on hover must also be reachable by focus (touch devices have no hover). Hover affordances must have a focus-visible counterpart.
- **Reduced-motion respect** — if the mockup implies animation, respect `prefers-reduced-motion`. Mostly N/A for static mockups; flag only if the mockup encodes an animated interaction as its core affordance.
