---
name: "feature-mockup"
description: "Use when a feature needs spec-validation UI mockups under ${aiDir}/features/{feature}/mockups/ before tech design. Keywords: mockup, prototype screen, wireframe, visualize spec. Do NOT use for production UI or aesthetic landing pages (frontend-design), or to critique mockups (feature-mockup-review)."
tags: [mockup, feature, design, ux, prototyping]
---

# Feature Mockups

Builds spec-validation mockups: static, design-system-default surfaces that prove a spec's flows before technical design. The workflow, guards, and traceability rules are technology-neutral; everything stack-specific (file format, component library, verify/preview commands, authoring idioms) comes from configuration. Mockups render the spec — they never carry aesthetic exploration (that is `frontend-design`'s job) and never touch production code.

## Configuration

Two sources, both optional — configure with `/myspec:setup mockup`:

1. **`.myspec.json` `mockups` block** — machine config:

```json
{
  "mockups": {
    "extension": ".vue",
    "commands": {
      "verify": "pnpm --filter @acme/mockups typecheck",
      "compileCheck": "curl -s \"http://localhost:{port}/@fs{absPath}\" -o /dev/null -w \"%{http_code}\"",
      "preview": "pnpm dev:mockups",
      "audit": "pnpm mockups:audit"
    },
    "siblingRoots": ["apps/web/src/components", "apps/web/src/pages"]
  }
}
```

   Every key is optional. `verify` = whole-suite check (typecheck/lint), must exit 0. `compileCheck` = per-file check (`{absPath}`, `{file}`, `{port}` placeholders), must report success. `preview` = dev-server command to run in the background. `audit` = shared-component reuse scan. `siblingRoots` = production directories to sweep for existing implementations of a surface.

2. **`${aiDir}/conventions/mockup-design.md`** — prose config: project hard guards, style baseline, allowed/forbidden imports, authoring idioms, data-model source, canonical reference mockups, and the append-only *Repeated user feedback* log. If missing, scaffold it with those section headings (empty) before building.

**No configuration present** → announce "no mockup configuration — universal guards only; run `/myspec:setup mockup` to configure", author mockups in the format the repo suggests (frontend stack's component format if one exists, self-contained HTML otherwise), and skip the verify/compile/audit steps with a note.

## Constraints (hard guards — non-negotiable)

| Concern | Rule |
|---|---|
| **Scope** | Only write inside `${aiDir}/features/{feature}/mockups/`. Production code is read-only context. |
| **No data-model changes** | Never edit schemas, migrations, API types, services, or validators. Mockups mirror the data model; they never move it. |
| **Design-system defaults** | Every UI element that can plausibly be a design-system/component-library element must be one, at default styling. No re-theming, no alternative libraries, no per-file subcomponents. No custom fonts, no custom CSS variables, no decorative texture — semantic tokens / system defaults only. |
| **Inline mock data only** | Mirror the real data model in local type/interface blocks with realistic sample data. Never import production data-layer, API-client, state-store, or router modules (the project's forbidden-import list lives in `mockup-design.md`). |
| **Reuse before reinventing** | Before authoring non-trivial chrome (navbar, footer, hero, pagination, top-section), run the configured `audit` command and check `${aiDir}/features/*/mockups/_*` and `_components/` for an existing shared implementation. Import it instead of re-rolling. |
| **Navigation = link** | Anything that would change the URL in production must be a real link element (`href="#mock-path"`). Never click-handler navigation shims, never a generic container styled as a link, never `role="link"` on a non-anchor. |
| **Variants vary structure, not style** | A/B/C variants of one surface differ in layout/IA only — same components, same tokens, same density baseline. Variants are never a vehicle for visual-style comparisons. |
| **Cross-mockup consistency** | New mockups copy structural idioms (component picks, density, spacing) from the reference mockup chosen in recon. Different style only if the user explicitly opts in. |
| **Real changes → handoff** | When mockup work surfaces a need for production code, schema, or design-system work, **append to the handoff list, do not implement**. |
| **Spec-AC traceability** | Every interactive element, settings toggle, secondary action, and entire surface must map to a specific AC in `${aiDir}/features/{feature}/spec.md`. Unjustified surfaces are scope-creep candidates — drop them, or flag the spec gap and pause until resolved. |
| **Destructive actions confirm** | Every destructive action (delete, archive, deactivate, force-publish) gets a confirmation modal that names the entity + blast radius and is disabled when usage blocks it. |
| **One primary CTA per surface** | Exactly one visually-primary action per mockup surface; secondary actions clearly subordinate. |
| **Project hard guards** | Every rule in `mockup-design.md` *Always* applies on top of this table; on conflict, the project file wins. |

## Workflow

### Phase 1 — Clarify

1. **Resolve feature.** Use any feature slug the user passed; otherwise ask "Which feature directory under `${aiDir}/features/`?". Verify `${aiDir}/features/{feature}/spec.md` exists — if not, refuse. **REQUIRED prerequisite:** `/myspec:feature-spec`.
2. **Silent recon** — read these without asking the user. **Data-model/spec mismatches are the #1 source of rebuild rounds — never invent enum values or field names from a verbal description.** If the spec is ambiguous about a model shape, ask the user before guessing.
   - `.myspec.json` `mockups` block + `${aiDir}/conventions/mockup-design.md` (scaffold if missing; the *Repeated user feedback* section is authoritative override).
   - `${aiDir}/conventions/accessibility.md` if present — link-vs-button catalogue backing the navigation guard.
   - `${aiDir}/features/{feature}/spec.md` (+ parent feature's `spec.md` when sub-feature).
   - `${aiDir}/features/{feature}/seed/` and `scenarios.md` if present (realistic sample data).
   - **Data-model slice** — read the project's authoritative model definitions (schema file, migrations, model classes — named under *Data model source* in `mockup-design.md`) for the models the spec references; copy exact enum values and field names into the inline mock types.
   - **Component-library surface** — the library's export index / component list (named in `mockup-design.md`), so every pick is a real component. If the *Component library* section pins a version (`Configured against: {package}@{version}`), compare it against the installed version (package.json / lockfile). On mismatch, stop before building: tell the user the mockup config predates the installed library and confirm the *Allowed imports* / *Detection patterns* sections still hold — or route to `/myspec:setup mockup` to regenerate.
   - **Reuse audit** — run the configured `audit` command if present and read its output. Then `find ${aiDir}/features -path '*/mockups/_*'` to list shared scaffolding files; for each that overlaps planned chrome, read it and plan to import rather than re-roll.
   - **Pick a reference mockup** for cross-mockup consistency: most-recent mockup in `${aiDir}/features/{feature}/mockups/` → most-recent project-wide mockup → the canonical references named in `mockup-design.md`. Read the chosen reference once.
   - `ls ${aiDir}/features/{feature}/mockups/` — list existing mockups.
   - **Production sibling lookup** — for each surface you plan to build, sweep the configured `siblingRoots` for the production sibling component/page and read it. Capture: prop names, modal-vs-dropdown choice, dismissal UX, enum coverage, selection pattern. The mockup must *embrace* the existing flow, not reinvent it. No sibling → mark the surface `greenfield`. No `siblingRoots` configured → mark all surfaces `greenfield` and note it.
   - **Catalog skim — REQUIRED (conditional)** — read [../feature-mockup-review/references/README.md](../feature-mockup-review/references/README.md) (the review skill's load-trigger index) and skim every catalog whose trigger fires for the planned mockups; always skim `core.md` and `accessibility.md`. The review skill will check against these — building to them prevents the round-trip.
3. **Batched dossier — one `AskUserQuestion` call, ≤4 questions, recommended option first.** Each question is a *proposed answer* the user can accept, swap, or override via free input. Default set:
   - **Audience** — admin (dense, compact) / end-user (polished, roomy) / both
   - **Style match** — match `{reference-mockup-path}` (Recommended) / different style — describe via Other
   - **Devices** — desktop / desktop+mobile / mobile-only
   - **User-facing pain or intent** — propose 2–3 plausible framings drawn from the spec
   Drop questions the spec already answers unambiguously. Never exceed 4 questions per call.
4. **Propose inventory.** Numbered list, calibrated by the dossier. **Each entry must include**:
   - **Filename** + one-line rationale
   - **Source AC** — the specific AC from `spec.md` this surface satisfies (required — no AC = scope creep; drop it or flag the spec gap)
   - **Production sibling** — path from recon, or `greenfield`
   - **States covered** — which of empty / loading / error / partial / success this mockup renders, or "inherited from {sibling surface}". Data-driven surfaces with unmocked states are spec-coverage gaps, not silent omissions.
   - Existing mockups marked `(exists — update)`
   - **Contested surfaces** — where the spec admits multiple plausible IA paths — marked `(variants?)`

   After the user confirms the inventory, follow up with one `AskUserQuestion` covering only the `(variants?)` surfaces: "Build single / A+B / A+B+C for {Surface}?" Default = single. Confirm "go".

### Phase 2 — Build (per-file loop)

For each confirmed mockup, in order:

1. **Write** `${aiDir}/features/{feature}/mockups/{Name}{extension}` with:
   - **Title header** — a `title:` + `description:` comment block at the top, in the file format's comment syntax (preview tooling reads it; it is also the file's self-description).
   - **Authoring idioms** from `mockup-design.md` (structure order, helper style, typing discipline — whatever the project mandates).
   - **Inline mock types** mirroring the real data model; realistic sample data drawn from `seed/` + `scenarios.md` when available — never Lorem ipsum.
   - **Static only** — no lifecycle/effect hooks, no network, no timers. Interaction state may be mocked with local reactive state when the surface's job is to demonstrate the interaction.
   - **Modal surfaces** follow the project's modal mockup pattern from `mockup-design.md`, with all four dismissal paths wired (X + ESC + backdrop + Cancel).
2. **Verify.** Run the configured `verify` command. Fix errors, re-run until clean. Not configured → skip with a note.
3. **Compile-check.** If `preview` is configured, ensure the dev server is running (start in background if not). Run the configured `compileCheck` for the file — expect success; on failure read the dev-server log for the transform error and fix. Not configured → skip with a note.
4. **✓** — emit one-line progress (`{Name} · verify ✓ · compile ✓`), move to the next file.

After all files: if the project's docs conventions require a `mockups/README.md` (see `mockup-design.md`), write or update it with the required frontmatter.

### Phase 3 — Iterate (stay open)

After all files green, emit "Built N mockups. What's next?" and wait.

For each piece of feedback:
- **Visual / data / structure change** → edit affected files only → re-verify + re-compile-check only those files → ✓
- **Hint of a real code, schema, or design-system need** ("we need a new field on X", "the API is missing Y", "no component exists for this") → DO NOT implement → append to **handoff list**

Loop until the user says "done", "wrap up", or shifts topic.

### Wrap up

Three steps in order. All three use `AskUserQuestion`.

#### Step 1 — Rule extraction (conditional)

Review the iteration log for *the same correction applied 2+ times in this session* (e.g. a token substitution repeated across files, a component-pick correction, a layout rule). If at least one such pattern exists, frame it as a one-line rule and ask:

```
AskUserQuestion:
  question: "Save '{rule}' to ${aiDir}/conventions/mockup-design.md?"
  options:
    - "Yes, save as-is (Recommended)" — appends to *Repeated user feedback*
    - "Edit before saving" — agent shows the proposed entry, user revises
    - "No, skip this one" — drops it
```

When saving, append under *Repeated user feedback* using that file's documented format (date · rule · Why · How to apply · session ref). One AskUserQuestion per rule, max 4 rules per session — defer the rest.

If no pattern crosses the 2× threshold, skip this step silently.

#### Step 2 — Commit prompt

```
AskUserQuestion:
  question: "Commit {N} mockups now?"
  options:
    - "Yes — `mockup({feature}): {N} surfaces — {comma-list-of-names}` (Recommended)"
    - "Yes, but let me write the message"
    - "No, leave staged"
```

Stage only `${aiDir}/features/{feature}/mockups/**` and any `mockup-design.md` updates from Step 1. Never `git add -A`. Use the project's standard commit footer. Confirm with `git status` after the commit.

#### Step 3 — Handoff list

Print the handoff list (if any):

```
## Real changes surfaced during mockup work

1. **{topic}** — {one-line description}
   → Hand off to: `/myspec:{skill}` ({rationale})
```

**Handoff routing:**
- Data-model field/relation/migration → `/myspec:feature-tech-spec`
- Spec changes / new requirement → `/myspec:feature-update`
- Implementation tasks → `/myspec:feature-plan` → `/myspec:feature-implement`
- Missing design-system component → design-system maintainer (no skill — manual)

## Patterns

### Title header (default: HTML-comment frontmatter)

```
<!--
title: {Feature name} · {Surface name}
description: {One-sentence description of what's mocked}
-->
```

Use the comment syntax of the mockup's file format; keep the `title:` / `description:` keys — the default preview tooling parses them for navigation.

### Sharing a component across mockups

When the same chrome surfaces in two or more features (navbar, footer, hero, pagination), promote it once instead of re-rolling:

1. Pick the feature that conceptually owns it. Create the directory + `spec.md` stub if missing.
2. Save it as `${aiDir}/features/{feature}/mockups/_{Name}{extension}` (or under `_components/`). The `_` prefix keeps it out of preview navigation.
3. Other mockups import it via the project's mockup alias (see `mockup-design.md`).
4. When it stabilizes, graduate it to the design system via the handoff list — never directly.

## Verification checklist

- [ ] Configured `verify` command exits 0 for the suite (or its absence was noted)
- [ ] Configured `compileCheck` passed per file (or its absence was noted)
- [ ] Every file imports only from the allowed list in `mockup-design.md`; zero production data-layer/state/router imports
- [ ] Authoring idioms from `mockup-design.md` applied (helper style, typing, structure order)
- [ ] No custom fonts, no custom CSS variables, no re-theming — design-system defaults only
- [ ] Realistic sample data mirroring the real data model, not Lorem ipsum; enum values copied, not invented
- [ ] Title header present in every mockup file
- [ ] Every navigational element is a real link with `href="#mock-path"` — no click-handler nav shims
- [ ] Variants of the same surface differ in layout/IA only — same components, tokens, density
- [ ] Every new mockup matches the reference mockup's structural idioms unless the user opted out
- [ ] Phase 1 used a single batched `AskUserQuestion` (≤4 questions) for the dossier
- [ ] Reuse audit ran (or was noted absent); overlapping chrome imported, not re-rolled
- [ ] Every mockup surface maps to ≥1 spec.md AC (Source AC populated in inventory)
- [ ] Production sibling located + read for each non-`greenfield` surface; deviations deliberate and noted
- [ ] States planned at inventory time match states mocked (or inherited / handed off)
- [ ] Every destructive action has a confirmation modal mocked (or linked in the inventory)
- [ ] Every modal has all four dismissal paths wired (X + ESC + backdrop + Cancel)
- [ ] Every form has Submit + Cancel + default focus on first field
- [ ] Exactly one visually-primary CTA per surface
- [ ] Wrap up ran rule extraction (if ≥2× repeats), the commit prompt, and printed the handoff list — in that order

## Integration

**Requires** [REQUIRED]: `/myspec:feature-spec` — a spec.md must exist before mocking.
**Configured by** [OPTIONAL]: `/myspec:setup mockup` — writes `${aiDir}/conventions/mockup-design.md` and the `.myspec.json` `mockups` block; can install the default preview app.
**Next** [OPTIONAL]: `/myspec:feature-mockup-review` — audit the built mockups before tech design.
**Then** [REQUIRED]: `/myspec:feature-tech-spec` — once the spec is visually validated.
