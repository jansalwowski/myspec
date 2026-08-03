# `/myspec:feature-mockup-review` — examples

Audits mockups in `${aiDir}/features/{feature}/mockups/` across five groups: Coverage & Scope, Production Fidelity, Loose Ends & Wiring, UX & Design Quality (backed by the `references/` heuristics catalogs), and config-driven Project Hard-Guards. Product: a findings table plus two fix batches — deterministic (bulk-approved) and judgement-based (per-item). Never authors new mockup files; gaps route to handoff.

> **Related**: Reviews the output of [feature-mockup.md](feature-mockup.md); shares its configuration (`/myspec:setup mockup`). Spec gaps route to [feature-update.md](feature-update.md), production-code needs to [feature-tech-spec.md](feature-tech-spec.md).

**Contents**

- [Full review with mixed findings](#full-review-with-mixed-findings)
- [Focus prompt narrows to loose ends](#focus-prompt-narrows-to-loose-ends)
- [Unconfigured project — Group E skipped, coverage gap handed off](#unconfigured-project--group-e-skipped-coverage-gap-handed-off)

---

## Full review with mixed findings

### Setup

`billing-portal` has three mockups from a `/myspec:feature-mockup` session. `mockup-design.md` defines semantic-token hard guards, a detection pattern (`raw palette classes on chrome → semantic token, Medium`), and one *Repeated user feedback* rule ("destructive actions name the entity in the confirm modal").

### Invocation

```
/myspec:feature-mockup-review billing-portal
```

### Skill flow

1. **Recon + dossier** — reads spec, all three mockups, `mockup-design.md`; sweeps the configured `siblingRoots` and proposes `admin/PaymentMethodList.vue` as sibling for `PaymentMethods.vue` (user confirms). Loads `core.md` + `accessibility.md`, and — since the mockups include forms and a data table — `forms.md`, `states.md`, `tables.md`.
2. **Findings table** (excerpt):

   | Severity | Dimension | Issue | File | Line(s) | Finding |
   |----------|-----------|-------|------|---------|---------|
   | Critical | A · Spec Alignment | AC unmocked | — | — | AC8 (remove payment method) has no surface in any mockup |
   | High | C · Modal Dismissal | Missing handlers | InvoiceDetail.vue | 88-104 | Refund modal has X + Cancel but no ESC handler or backdrop click |
   | High | E · Repeated user feedback | Confirm names entity | PaymentMethods.vue | 61 | Delete confirm says "Delete this item?" — project rule requires the entity name |
   | Medium | E · Detection patterns | Raw palette on chrome | InvoiceList.vue | 42 | `bg-gray-50` on the list header → semantic token |
   | Medium | D · Form Hygiene | Placeholder-as-label | PaymentMethods.vue | 33 | "Card nickname" placeholder acts as the label |

3. **Deterministic batch** — the ESC/backdrop handlers, the token substitution, and the label split are presented as one numbered list; user approves the batch in a single `AskUserQuestion`. Each edit is followed by `verify` (exit 0) + `compileCheck` (200).
4. **Judgement fix** — the confirm-modal copy change is presented individually with a diff and `[requires confirmation]`; user approves.
5. **The Critical** is a coverage gap, so it is **not fixed inline** — it goes to handoff:

   > ### New mockup files needed (Spec/Coverage gaps)
   > 1. **Remove-payment-method flow (AC8)** — no surface mocks it
   >    → Hand off to: `/myspec:feature-mockup` (billing-portal)

6. **Wrap up** — the entity-naming correction appeared only once, so no rule extraction; commit prompt (`mockup(billing-portal): review fixes — 3 surfaces`); handoff list printed.

---

## Focus prompt narrows to loose ends

### Invocation

```
/myspec:feature-mockup-review billing-portal "loose ends"
```

### Skill flow

The focus prompt maps to **Group C only**. The dossier drops the sibling question (irrelevant to wiring) and confirms the narrowed scope. The review greps every `href="#mock-path"` against the mockup inventory and checks each modal's four dismissal paths and each form's Submit/Cancel wiring.

One finding: `InvoiceList.vue`'s "Export CSV" button has a click handler but no target — not in the inventory, not in the spec's out-of-scope list. Dead secondary action → High. The fix (link it to the documented `#mock-path` for the planned export surface, or demote it to the handoff list if export is unspec'd) is judgement-based and presented per-item. Groups A/B/D/E are not run; the report says so explicitly.

---

## Unconfigured project — Group E skipped, coverage gap handed off

### Setup

A project with mockups built during the degraded `/myspec:feature-mockup` flow: no `mockups` block, a scaffolded but empty `mockup-design.md`.

### Invocation

```
/myspec:feature-mockup-review search-filters
```

### Skill flow

1. Recon notes: **"no mockup configuration; groups A–D only"** and suggests `/myspec:setup mockup`. Group E is skipped — its sections in `mockup-design.md` are empty.
2. Groups A–D run in full against the `.html` mockups: spec ACs cross-checked, wiring greps run, catalogs loaded per trigger.
3. Findings include a Medium (zero-results state missing for the filter panel). Because authoring a new state surface is out of scope for the review skill, it is flagged as a Spec/Coverage gap and routed to `/myspec:feature-mockup` in the handoff list — no new files are authored.
4. With no `verify`/`compileCheck` configured, post-fix verification steps are skipped with a note; the wrap-up summary lists which checks did not run.
