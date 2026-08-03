# Blueprint: Mockup

## Purpose
Configure the `/myspec:feature-mockup` and `/myspec:feature-mockup-review` skills for this project — mockup file format, design-system baseline, import rules, verify/preview tooling, production-fidelity roots, and project hard guards. The skills' workflow and review dimensions are universal; this blueprint captures everything stack- or repo-specific.

## Recon (before asking)

Inspect the repo so most questions become confirm-or-correct instead of open-ended:
- Detect the frontend stack (package manifest, framework config, file extensions in the main app).
- Detect a component library / design system (workspace packages, UI-library dependencies, an existing token config).
- Detect existing mockups (`${aiDir}/features/*/mockups/`) and existing preview tooling (a dedicated preview app or script).
- Detect the data-model source (schema file, migrations directory, model classes).

Present each detected value as the proposed answer for its question below.

## Discovery Questions (ask one at a time)

Any question may be answered "skip"; sections left unanswered keep their header with "(none configured)". Answering "defaults" to a question accepts the proposed/detected value.

### Format & design baseline

1. "What file format should mockups use? (Detected: `{extension}` — e.g. `.vue` for a Vue repo, `.tsx` for React, `.html` when there is no frontend stack.)"

2. "What is the design baseline for mockups?
   - **Component library at default styling** (recommended when one exists) — name it, its import path, and where its export index / component list lives
   - **Plain semantic HTML/CSS** — a small neutral token set, no library
   - **No design system yet** — follow the `frontend-design` skill's guidance once to establish a neutral baseline, then hold it
   Also: which semantic tokens/classes should mockups use for surfaces, text, and borders? (or 'library defaults')"

### Imports

3. "Which imports are mockups **allowed** to use? (Proposed from your baseline: the component library, an icon library, the framework's reactive primitives, and a shared-mockup alias for `_`-prefixed scaffolding — name the alias if one exists.)"

4. "Which imports are **forbidden** in mockups? (Proposed from the detected stack: API client / data layer, state store, router, ORM / schema packages. Mockups mirror types inline instead.)"

### Verify & preview tooling

5. "What command verifies all mockups (typecheck / lint over the mockups tree)? Must exit 0 when clean. (or 'none')"

6. "How are mockups previewed?
   - **Existing tooling** — give the dev-server command and, if available, a per-file compile-check command (placeholders: `{absPath}`, `{file}`, `{port}`)
   - **Install the plugin's default preview template** — offered only if `templates/mockup-preview/` ships a template matching your stack
   - **None** — the skills skip preview/compile checks with a note"

7. "Is there a shared-component reuse audit command (lists cross-feature self-rolled chrome worth importing instead of re-rolling)? (or 'none')"

### Production fidelity

8. "Which production directories should be swept for existing implementations of a surface (sibling roots)? (e.g. `apps/web/src/components`, `src/pages` — or 'none' for greenfield projects)"

9. "Where is the authoritative data model defined (schema file, migrations directory, model classes)? Mockups copy exact field names and enum values from here."

10. "Are there canonical reference mockups new mockups should structurally match (one for admin surfaces, one for end-user surfaces)? (or 'none yet — the first accepted mockups will seed these')"

### Hard guards & idioms

11. "Any repo-specific authoring idioms for mockup files? (e.g. helper-function style, typing discipline, structure order, no lifecycle hooks, modal mockup pattern, a required `mockups/README.md` frontmatter shape)" (or "skip")

12. "Any deterministic detection patterns the reviewer should grep for — each with a severity and, where possible, a mechanical fix? (e.g. 'raw palette classes on chrome → map to semantic token, Medium')" (or "skip")

## Output Format

### `${aiDir}/conventions/mockup-design.md` (required)

```markdown
---
title: "Mockup Design Conventions"
purpose: "Persistent design rules for ${aiDir}/features/{feature}/mockups/*. Loaded by the feature-mockup and feature-mockup-review skills at silent recon. Append-only — do not delete prior rules without user approval."
updated: {YYYY-MM-DD}
---

# Mockup Design Conventions

> **Scope**: `${aiDir}/features/{feature}/mockups/*` only. Production code is governed by the project's own conventions.
>
> **For agents**: read this file at silent recon. Apply *Always* and *Style baseline* unconditionally. Treat *Repeated user feedback* as project-specific overrides — when conflicting with defaults, the user's stored feedback wins.

## Always
<hard guards from Q2–Q4 and Q11 as a table: design-baseline discipline, token rules, import discipline, idioms promoted to guards>

## Style baseline
<from Q2 + Q11 as a table: density, spacing scale, modal mockup pattern, sample-data rules, icon library>

## Imports

### Allowed
<from Q3 as a table: package/alias · purpose. Include the shared-mockup alias row.>

### Forbidden
<from Q4 as a table: package · why>

## Data model source
<from Q9: path(s) + one line on how mockups mirror them (inline types, exact enum values, cite the source in a comment)>

## Component library
<from Q2: library name, import path, export index / component list location — or "(none — plain semantic HTML/CSS)">

## Cross-mockup consistency
<from Q10: canonical reference mockups (admin / end-user), plus the rule: new mockups copy structural idioms from the reference unless the user explicitly opts out>

## Detection patterns
<from Q12, one per line: pattern (regex or description) · severity · mechanical fix if any — or "(none configured)">

## Repeated user feedback

> Append-only log of design corrections the user has applied 2+ times in a single session. Captured at session wrap-up via the rule-extraction prompt.
>
> Format:
> ```
> ### YYYY-MM-DD — {one-line rule}
> - **Why**: {reason given by user, or inferred from context}
> - **How to apply**: {when this rule kicks in}
> - **Source**: session `{session_id_first8}`
> ```
```

## Post-generation

1. Update `.myspec.json` — add or update the `mockups` block from Q1, Q5–Q8 (omit keys answered "none"):

```json
{
  "mockups": {
    "extension": "<Q1>",
    "commands": {
      "verify": "<Q5>",
      "preview": "<Q6 dev-server command>",
      "compileCheck": "<Q6 per-file command>",
      "audit": "<Q7>"
    },
    "siblingRoots": ["<Q8>"]
  }
}
```

2. If Q6 chose the default preview template: copy the matching template from the plugin's `templates/mockup-preview/` into the project (location confirmed with the user), install its dependencies, and record the resulting commands in the `mockups` block.

## Output Location
- `${aiDir}/conventions/mockup-design.md`
- `.myspec.json` `mockups` block (project root)
