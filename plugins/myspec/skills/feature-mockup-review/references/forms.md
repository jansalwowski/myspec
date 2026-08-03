# Forms — Anti-patterns and Patterns

Load when mockup contains form inputs: native `<form>` / `<input>` / `<textarea>` / `<select>`, any component-library input primitive, or inline-edit patterns.

## Field-level anti-patterns
- **Placeholder ≠ label** — labels persist; placeholders disappear on first keystroke and fail contrast. Use `<label>` above the field; placeholders are example values only ("e.g. Acme Corp"), not labels.
- **Required indicator** — explicit "(required)" / "(optional)" text > bare asterisk. Asterisk is opaque to non-native speakers and SR users without supplemental text.
- **Helper text below input** — same lane as future errors; visible during typing. Above-input helper text competes with the label.
- **Inline error timing** — show errors on blur, not on every keystroke (frustrates users) and not only on submit (forces re-scanning). Re-validate on the next keystroke after an error has been shown.
- **Color-not-only error** — error states need icon + text alongside the red border (see accessibility.md).

## Submit / Cancel patterns
- **Primary button position** — same position across all forms in the feature (right-aligned in modals, bottom of card in pages). Mismatch is a Consistency violation.
- **Disabled-submit reason** — if submit is disabled, the form must show *why* (which fields are missing, what's invalid). Bare disabled button with no explanation is a dead end.
- **"Save and add another"** — for repetitive admin entry (creating items, adding entries), pair Save with a "Save and add another" affordance.
- **Dirty-form warning** — navigating away from a form with unsaved changes prompts to confirm. Most-missed pattern in admin edit flows.

## Inline editing patterns
- **Edit affordance** — click-to-edit surfaces need a visible cue: edit icon on hover OR cursor change OR explicit "Edit" button. No-cue inline edits are invisible.
- **Save trigger** — Enter to save (single-line), Cmd/Ctrl+Enter (multi-line), blur-to-save with debounce, OR explicit Save button. Pick one per surface and document it; mixed patterns confuse.
- **Cancel / revert** — Esc reverts to previous value; explicit Cancel button on multi-line. Save-on-blur surfaces still need a revert path.
- **Optimistic UI** — apply the change immediately, rollback on error with a toast. Avoid spinner-blocks for trivial inline saves.

## Disabled-state explanation
- **Tooltip required** — disabled buttons must have a `title` / tooltip naming the reason ("Set a slug to enable Save"). Bare disabled state forces the user to guess.
- **Visible vs hidden** — disabled-but-visible signals "this exists but you can't right now"; hidden signals "this isn't relevant." Pick deliberately; consistent across the feature.
