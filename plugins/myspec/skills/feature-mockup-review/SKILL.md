---
name: "feature-mockup-review"
description: "Use to critique mockups in ${aiDir}/features/{feature}/mockups/ — UX issues, scope creep, dead buttons, missing states, accessibility, hard-guard violations. Keywords: review mockup, mockup audit, loose ends. Do NOT use to build mockups (feature-mockup)."
tags: [feature-workflow, mockup, validation, ux, review, critical-thinking]
---

# Feature Mockup Review

Audits feature mockups against universal UX dimensions plus project-specific hard guards. The five review groups are technology-neutral; everything stack-specific comes from the same configuration `feature-mockup` builds with (`.myspec.json` `mockups` block + `${aiDir}/conventions/mockup-design.md`). Without configuration, groups A–D still run in full; group E is skipped with a note.

## Constraints (hard guards — non-negotiable)

| Concern | Rule |
|---|---|
| **Scope** | Only edit files under `${aiDir}/features/{feature}/mockups/`. Never edit production code, schema, or the design system. |
| **No new mockup files** | If a missing surface is needed (e.g. empty state not mocked), flag as Spec/Coverage gap and hand off to `/myspec:feature-mockup` — never author new mockup files in this skill. |
| **Never apply silently** | Present every fix for approval before editing. The deterministic batch can be approved as a single bundle; judgement-based fixes are per-item. No edits without an explicit Yes. |
| **Verify after every edit** | Re-run the configured `verify` command + per-file `compileCheck` after each approved fix (skip with a note when not configured). Inherits `feature-mockup`'s verification discipline. |

## Workflow

### 1. Resolve scope

- **No args** → `AskUserQuestion`: feature (list `${aiDir}/features/*/mockups/` dirs) + scope (whole dir / single file).
- **`<feature>`** → review the whole `mockups/` dir.
- **`<feature> <File>`** → single file.
- **`<feature> "<focus prompt>"`** → free-text lens. Map keywords to dimensions: "mobile" → state + accessibility + touch-target focus; "scope creep" → A only; "loose ends" → C only; "looks off" → D + E.

Verify `${aiDir}/features/{feature}/spec.md` and the target mockup file(s) exist. Refuse if either is missing.

### 2. Silent recon (no questions)

Read without asking:
- `.myspec.json` `mockups` block — commands, `siblingRoots`, extension. Absent → note "no mockup configuration; groups A–D only" and suggest `/myspec:setup mockup`.
- `${aiDir}/features/{feature}/spec.md` — required ACs, user stories, out-of-scope list
- `${aiDir}/features/{feature}/mockups/README.md` (if present) and every target mockup file
- `${aiDir}/features/{feature}/mockups/_*` and `_components/` — shared scaffolding
- `${aiDir}/conventions/mockup-design.md` — project hard guards (the *Repeated user feedback* section is authoritative)
- `${aiDir}/conventions/accessibility.md` if present — link-vs-button catalogue
- The **reference mockup** (most-recent in this feature's dir; fall back per `feature-mockup`'s order)
- The configured `audit` command's output file, if the project has one
- For each target surface, **grep for production siblings** by token similarity against the mockup filename across the configured `siblingRoots`. Collect 1–3 candidates per surface; mark `greenfield` if none (or if no roots are configured).

### 3. Dossier — one batched `AskUserQuestion` (≤4 q's)

- **Confirm prod siblings** — for each surface with candidates, propose the top match; user confirms, picks an alternative, or marks `greenfield`. Multi-select if multiple surfaces.
- **Confirm scope** — review the entire findings set, or narrow to the focus prompt's mapped group(s) only.
- **Confirm reference mockup** — agent's pick (latest in feature dir) vs alternative.
- Drop questions answered by the focus prompt or the spec.

### 4. Run 5 review groups

#### A. Coverage & Scope
| Sub-dimension | Check |
|---|---|
| **Spec Alignment** | Every spec.md AC traceable to a surface; every surface traceable to ≥1 AC. Spec ACs in no mockup → Critical. |
| **Scope Discipline** | Every interactive element, settings toggle, secondary action justified by spec. Unjustified surfaces / buttons → High candidate for removal. |
| **State Coverage** | For each data-driven surface, verify the three highest-leverage states are mocked or referenced: empty / loading / error. Missing empty or error state → Medium. |

#### B. Production Fidelity
| Sub-dimension | Check |
|---|---|
| **Sibling Comparison** | For each non-`greenfield` surface, compare prop names, enum coverage, modal-vs-dropdown choice, dismissal UX against the production sibling. Divergence without spec justification → High (likely accidental reinvention). |
| **Cross-Mockup Consistency** | Same component picks, density baseline, spacing scale, token usage as the reference mockup. Idiom drift → Medium. |

#### C. Loose Ends & Wiring
| Sub-dimension | Check |
|---|---|
| **Targets Resolve** | Every link, navigation shim, and button with a click handler resolves to a file in the mockup inventory, a documented `#mock-path`, or the spec's out-of-scope list. Dead primary CTA → Critical. Dead secondary action → High. |
| **Modal Dismissal Coverage** | Every modal wires X button + ESC handler + backdrop click + Cancel button. Missing any → High. |
| **Form Wiring** | Every form has Submit + Cancel; default focus on first field; validation states reachable (valid/invalid/submitted). Missing → High. |
| **Empty/Error Recovery** | Empty states have a CTA; error states have retry or a path forward. Missing → Medium. |

#### D. UX & Design Quality (load catalogs per [references/README.md](references/README.md) — see Catalog loading)
| Sub-dimension | Check |
|---|---|
| **Nielsen Heuristics** | 10 quick checks (see catalog). |
| **Accessibility (WCAG-lite)** | Labels programmatically associated; focus visible; color contrast ≥ 4.5:1; color-not-only signal; touch targets ≥ 32×32 desktop / 44×44 mobile. |
| **Visual Hierarchy** | Exactly one primary CTA per surface. Information-overload check: ≤ ~7 visually-equal-weight elements per region; F-pattern / Z-pattern scan order. |
| **Form Hygiene** | Visible label outside the field (never placeholder-as-label); explicit "(required)" / "(optional)" text > asterisk; helper text below input in the same lane as future errors; sensible default focus. |
| **Confirmation Discipline** | Every destructive action (delete, archive, deactivate, force-publish) has a confirmation modal naming the entity + blast radius; disabled when usage blocks it. |
| **Microcopy** | Buttons name the action ("Delete user", not "OK"); errors are actionable ("Email is required", not "Invalid input"); empty-state copy follows Status+Action or Benefit+CTA. |
| **Dark Pattern Detection** | Per EU DSA 5-category taxonomy: notifications (urgency cues), tracking/consent (visual-prominence bias), onboarding (forced consent), recommender (hidden defaults), gamification (countdown timers, confirmshaming, default-opt-in for sensitive actions). |

#### E. Project Hard-Guards (config-driven, deterministic where possible)

Skipped with a note when `${aiDir}/conventions/mockup-design.md` is absent. Otherwise:

| Sub-dimension | Check |
|---|---|
| **Always rules** | Walk `mockup-design.md` *Always* rule-by-rule (token discipline, allowed/forbidden imports, authoring idioms, modal pattern — whatever the project defines). Violation on chrome → High. |
| **Detection patterns** | Run every grep/pattern the project documents under *Detection patterns* in `mockup-design.md`; each hit is a finding at the severity the pattern names (default Medium). |
| **Style baseline** | Density, spacing scale, icon library, sample-data rules from *Style baseline* hold across all target files. |
| **Repeated user feedback rules** | Walk the *Repeated user feedback* section rule-by-rule; flag any mockup that violates one. These are the project's hardest-won learnings — re-flagging them is the highest-leverage catch. |
| **Config freshness** | If *Component library* pins `Configured against: {package}@{version}`, compare against the installed version (package.json / lockfile) — mismatch → Medium: config predates the installed library; recommend `/myspec:setup mockup` or a manual section re-check. Likewise if frontmatter `myspec_version` is older than `.myspec.json` `frameworkVersion`, note that newer blueprint sections may be available. |
| **Navigation = link** | (Universal, enforced here for determinism.) URL-changing actions are real anchors with `href="#mock-path"` — no click-handler nav, no generic containers as links, no `role="link"` on a non-anchor. |

### 5. Findings table

**REQUIRED:** Follow [../\_shared/review-output.md](../_shared/review-output.md) for the findings-table and fix-proposal shapes. Use `{Group} · {Sub-dimension}` as the Dimension. Example rows:

```markdown
| Severity | Dimension | Issue | File | Line(s) | Finding |
|----------|-----------|-------|------|---------|---------|
| Critical | A · Spec Alignment | AC unmocked | mockups/README.md | — | spec.md AC-007 (bulk archive) has no mockup |
| High | C · Modal Dismissal | Missing handlers | EditModal.vue | 102-118 | Modal missing ESC handler + backdrop click |
| Medium | D · Form Hygiene | Placeholder-as-label | EditForm.vue | 45 | "Name" placeholder acts as label — split into label + example placeholder |
```

Show **all** Critical/High/Medium. Cap Low at the 5 most-impactful — ranked by repeat-count in `mockup-design.md`'s *Repeated user feedback* section. Footer: "N additional Low findings — see `${aiDir}/conventions/mockup-design.md`."

### 6. Present fixes — two groups, both require approval

**Deterministic batch** — semantic-preserving patterns that need no per-item judgement. Universal members:

| Pattern | Fix |
|---|---|
| Missing accessible label on icon-only button | Add from neighboring text or action name |
| Click-handler navigation on a non-anchor | Convert to a real link with `href="#mock-path"` |
| Modal missing one of: X / ESC / backdrop click | Add the missing handler(s) wired to the same close function |
| Placeholder-as-label (no label above input) | Insert a label with the placeholder text; rewrite placeholder to an example value (or empty) |
| Required field marked with `*` only | Add explicit "(required)" text alongside |
| Hits from `mockup-design.md` detection patterns with a documented mechanical fix | Apply the documented substitution (e.g. raw style token → semantic token) |

Present the batch as a single numbered list — each entry: `{File}:{Line} · {pattern} · {one-line before → after}`. Then ask:

```
AskUserQuestion:
  question: "Apply all N deterministic fixes as a single batch?"
  options:
    - "Yes — apply the whole batch" (Recommended)
    - "Show me each one individually" — falls through to per-item review
    - "Skip the batch entirely"
```

**Judgement-based fixes** — surface restructure, scope-creep removal, sibling-reinvention realignment, IA changes. Per-fix confirmation, one at a time, with diff + rationale + `[requires confirmation]` tag per the shared output conventions.

New empty/error/loading state inline → never propose as a fix; flag as Spec/Coverage gap and route to handoff.

### 7. Apply approved fixes

For each approved fix (bundled or individual):
1. Apply the edit
2. Run the configured `verify` command → must exit 0 (skip with a note if not configured)
3. Run the configured `compileCheck` for the file → must succeed (skip with a note if not configured)
4. Emit `{File} · {dimension} ✓`

Skip any fix the user rejected.

### 8. Wrap up

Three steps in order, using `AskUserQuestion`:

#### Rule extraction (conditional)
Review the session for **the same correction applied 2+ times**. Same shape as `feature-mockup`: propose appending to `${aiDir}/conventions/mockup-design.md` *Repeated user feedback*, one rule per AskUserQuestion call, max 4 per session.

#### Commit prompt
```
AskUserQuestion:
  question: "Commit {N} fixes now?"
  options:
    - "Yes — `mockup({feature}): review fixes — {N} surfaces` (Recommended)"
    - "Yes, but let me write the message"
    - "No, leave staged"
```
Stage only `${aiDir}/features/{feature}/mockups/**` and any `mockup-design.md` updates. Never `git add -A`. Use the project's standard commit footer.

#### Handoff list

```
## Issues surfaced during mockup review

### New mockup files needed (Spec/Coverage gaps)
1. **{surface}** — {one-line gap description}
   → Hand off to: `/myspec:feature-mockup` ({feature})

### Spec gaps
2. **{topic}** — spec doesn't define {behavior}; mockup can't be aligned without a spec decision
   → Hand off to: `/myspec:feature-update`

### Production-code issues surfaced
3. **{topic}** — {description}
   → Hand off to: `/myspec:feature-tech-spec` or `/myspec:feature-plan`

### Missing design-system components
4. **{component}** — no design-system equivalent for {pattern}
   → Manual: design-system maintainer
```

## Catalog loading

Before running Group D, read [references/README.md](references/README.md) (the load-trigger index).

**Always load** — universal rules, every surface:
- `references/core.md` — Nielsen's 10 + Laws of UX
- `references/accessibility.md` — WCAG-lite

**Conditional load** — based on the mockup's content and dossier answers:

| Trigger | Catalog |
|---|---|
| Mockup has form inputs or inline-edit | `references/forms.md` |
| Mockup is data-driven or has a multi-state interactive surface | `references/states.md` (empty/loading/error + state-machine + data-stress edge cases) |
| Mockup renders a tabular data view | `references/tables.md` |
| Audience = end-user OR surface is consent / sign-up / pricing / donate / nudge | `references/dark-patterns.md` |
| Audience = admin | `references/admin-dashboard.md` (SaaS failure modes + post-mutation feedback patterns) |

Each catalog entry is a 1-line pattern + 1-line detection cue. Read the index first; skip catalogs whose trigger does not apply.

## Severity Classification

| Severity | Definition |
|----------|------------|
| **Critical** | Blocks acceptance — spec AC unmocked, destructive action without confirmation, dead primary CTA, modal with zero dismissal path. |
| **High** | Must fix before implementation — accidental sibling reinvention, missing modal dismissal handler, missing form submit/cancel, project hard-guard violation on chrome, two competing primary CTAs. |
| **Medium** | Should fix — missing empty/error state, color-only signal, placeholder-as-label, vague microcopy, idiom drift from reference. |
| **Low** | Nice to have — copy polish, additional aria descriptions, density tweaks. Capped at top-5 per session. |

Never downgrade a severity to make the report look cleaner.

## Detection Patterns (universal greps)

Stack-specific patterns (token regexes, framework idioms) live in `mockup-design.md` *Detection patterns* and run in Group E. These universal ones always run:

```
# Navigation via click handler instead of an anchor (C/E)
click-handler attributes containing route/navigation calls; generic containers (div/span) with click handlers wrapping link-styled content

# Dead link suspicion (C. Targets Resolve)
count href="#mock-path" occurrences vs the inventory; unmapped mock-paths are candidates

# Modal missing dismissal (C. Modal Dismissal)
for each modal surface, verify ALL of: X button, ESC handling, backdrop click, Cancel button

# Placeholder-as-label suspicion (D. Form Hygiene)
any input with a placeholder and no associated visible label in the same surface

# Destructive action without confirm (D. Confirmation Discipline)
/(delete|archive|deactivate|remove|destroy)/i in button text → verify a confirm modal exists in the inventory
```

## Verification Checklist

- [ ] All 5 review groups checked against every target file (or E skipped with a note when unconfigured)
- [ ] Spec.md ACs cross-validated against the mockup inventory
- [ ] Production siblings confirmed via dossier `AskUserQuestion` (or `greenfield` marked)
- [ ] Reference mockup confirmed
- [ ] Findings table follows `_shared/review-output.md`; every issue has file + line(s) or `—`
- [ ] Low findings capped at 5 most-impactful
- [ ] Always-load catalogs (`core.md`, `accessibility.md`) read before Group D; conditional catalogs loaded per trigger
- [ ] `mockup-design.md` *Always*, *Detection patterns*, and *Repeated user feedback* walked rule-by-rule (Group E)
- [ ] Deterministic batch presented for bulk approval as a single `AskUserQuestion`; no edits without an explicit Yes
- [ ] Judgement-based fixes presented per-item with `[requires confirmation]` and awaited
- [ ] After each approved fix: configured `verify` + `compileCheck` ran clean (or absence noted)
- [ ] No new mockup files authored (gaps handed off to `/myspec:feature-mockup`)
- [ ] No edits outside `${aiDir}/features/{feature}/mockups/**` and `mockup-design.md`
- [ ] Wrap up ran in order: rule extraction → commit prompt → handoff list
- [ ] Handoff list distinguishes new-mockup gaps, spec gaps, production-code issues, missing design-system components

## Known Limitations

- **Visual rendering blind spot** — this skill is text-only. It catches structural / semantic / pattern issues but cannot see overflow, misalignment, wrapping breaks, low contrast despite valid tokens, or focal-point chaos that only manifests in pixels. After the review, do a manual preview walkthrough (configured `preview` command) at desktop + mobile viewports before claiming "done".
- **No diff / baseline mode** — every invocation reviews the whole scope; there's no "what changed since last review". For iterative reviews, narrow with the `<File>` argument or a focus prompt.

## Integration

**Requires** [REQUIRED]: mockups built by `/myspec:feature-mockup` and `${aiDir}/features/{feature}/spec.md`.
**Configured by** [OPTIONAL]: `/myspec:setup mockup` — same configuration as `feature-mockup`.
**Suggests**: `/myspec:feature-mockup` (gap fills), `/myspec:feature-update` (spec gaps), `/myspec:feature-tech-spec` or `/myspec:feature-plan` (production-code handoff).
**Next**: re-invoke after gap-fill rounds, or proceed to `/myspec:feature-tech-spec` once the review passes.

## Example Usage

```
User: /myspec:feature-mockup-review checkout
```

1. Load spec.md + all mockup files in `${aiDir}/features/checkout/mockups/`
2. Sweep configured `siblingRoots` for production siblings; propose candidates
3. Dossier `AskUserQuestion`: confirm siblings + scope + reference mockup
4. Run all 5 groups, build the findings table
5. Present the deterministic batch for bulk approval, then judgement fixes per-item
6. Apply approved fixes, re-verify per file
7. Wrap up: rule extraction (if 2× repeats), commit prompt, handoff list

```
User: /myspec:feature-mockup-review checkout EditModal.vue "mobile version has really bad ux"
```

Same workflow narrowed to `EditModal.vue`; the focus prompt biases Group D toward touch-target + responsive checks and surfaces mobile-specific findings ahead of desktop polish.
