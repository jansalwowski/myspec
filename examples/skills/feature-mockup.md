# `/myspec:feature-mockup` — examples

Builds spec-validation mockups under `${aiDir}/features/{feature}/mockups/`: static, design-system-default surfaces that prove a spec's flows before technical design. Technology-agnostic — file format, component library, and verify/preview commands come from the `.myspec.json` `mockups` block and `${aiDir}/conventions/mockup-design.md`. Every surface must trace to a spec AC; real code or schema needs go to a handoff list, never into the mockup session.

> **Related**: Configured by `/myspec:setup mockup`. Requires an approved spec from [feature-spec.md](feature-spec.md). Reviewed by [feature-mockup-review.md](feature-mockup-review.md); handoffs route to [feature-update.md](feature-update.md) or [feature-tech-spec.md](feature-tech-spec.md).

**Contents**

- [First mockups for an approved spec (configured project)](#first-mockups-for-an-approved-spec-configured-project)
- [Unconfigured project — graceful degradation](#unconfigured-project--graceful-degradation)
- [Scope-creep flagged, schema need routed to handoff](#scope-creep-flagged-schema-need-routed-to-handoff)

---

## First mockups for an approved spec (configured project)

### Setup

`billing-portal` has an approved `spec.md` (AC1–AC9: invoice list, invoice detail, payment-method management). The project ran `/myspec:setup mockup`: Vue SFC mockups, a `@corp/ui` component library, `verify`/`preview`/`compileCheck` commands recorded, `siblingRoots: ["apps/web/src/components"]`.

### Invocation

```
/myspec:feature-mockup billing-portal
```

### Skill flow

1. **Silent recon** — reads `mockup-design.md` (two *Repeated user feedback* rules), the spec, the schema slice for `Invoice`/`PaymentMethod` (copies the real `InvoiceStatus` enum), the `@corp/ui` export index, and sweeps `apps/web/src/components` — finds `admin/PaymentMethodList.vue` as a sibling for one planned surface. Picks the most-recent project mockup as the structural reference.
2. **Dossier** — one batched `AskUserQuestion` (audience: end-user · style: match reference · devices: desktop+mobile · intent: "customers can't find historical invoices"). User accepts all four proposals.
3. **Inventory** — numbered list, each entry with Source AC, sibling, and states:

   > 1. `InvoiceList.vue` — AC1–AC3 · sibling: greenfield · states: empty / loading / error / success
   > 2. `InvoiceDetail.vue` — AC4–AC6 · sibling: greenfield · states: success only (per spec)
   > 3. `PaymentMethods.vue` — AC7–AC9 · sibling: `admin/PaymentMethodList.vue` · states: empty / success

   User confirms "go".
4. **Build loop** — per file: write (inline `interface Invoice` mirroring the schema, realistic seed data, one primary CTA, `href="#mock-path"` navigation), then `verify` (exit 0) and `compileCheck` (200). Emits `InvoiceList.vue · verify ✓ · compile ✓` per file.
5. **Iterate** — user: "invoice rows need the amount right-aligned" → edit, re-verify that file only.
6. **Wrap up** — no correction repeated 2×, so rule extraction is skipped silently; commit prompt (`mockup(billing-portal): 3 surfaces — InvoiceList, InvoiceDetail, PaymentMethods`); handoff list is empty.

---

## Unconfigured project — graceful degradation

### Setup

A Rails monolith with myspec initialized but no `mockups` block and no `mockup-design.md`. The user wants to visualize a `search-filters` spec anyway.

### Invocation

```
/myspec:feature-mockup search-filters
```

### Skill flow

1. Announces: **"no mockup configuration — universal guards only; run `/myspec:setup mockup` to configure."**
2. Scaffolds `${aiDir}/conventions/mockup-design.md` with empty section headings so wrap-up rule extraction has a home.
3. No frontend component format is detectable, so mockups are authored as self-contained `.html` files with the title-header comment block.
4. Universal guards still hold: AC traceability in the inventory, one primary CTA, confirmation modal for the "Clear all filters" destructive action, link-based navigation.
5. Verify / compile-check / audit steps are **skipped with a note** — the wrap-up summary states which checks did not run.
6. Wrap-up ends by recommending `/myspec:setup mockup` and, since no preview tooling exists, opening the HTML files directly in a browser.

---

## Scope-creep flagged, schema need routed to handoff

### Setup

Same `billing-portal` project. During iteration the user asks: "add an auto-pay toggle to PaymentMethods" — but no AC in `spec.md` covers auto-pay, and mid-session they note the mockup needs a `PaymentMethod.isDefault` flag the schema lacks.

### Skill flow

1. **Auto-pay toggle** — the skill checks the spec: no AC covers it. Per the spec-AC traceability guard it does not build the surface:

   > Auto-pay isn't covered by any AC in `spec.md` — building it would be scope creep. Options: (a) drop it, (b) route to `/myspec:feature-update` to add the requirement first. Which?

   User picks (b); the item goes to the handoff list, the mockup stays unchanged.
2. **`isDefault` flag** — a schema need. The skill does **not** invent the field in the inline mock beyond what a spec AC implies, and does not touch the schema. Appends to the handoff list.
3. **Wrap up** prints:

   > ## Real changes surfaced during mockup work
   >
   > 1. **Auto-pay requirement** — user wants an auto-pay toggle; spec has no covering AC
   >    → Hand off to: `/myspec:feature-update` (new requirement)
   > 2. **`PaymentMethod.isDefault`** — default-method indicator needs a schema field
   >    → Hand off to: `/myspec:feature-tech-spec` (data-model change)

Both items leave the session as documentation, not code — the mockup session never edits production files.
