# Explore mode (`--explore`)

Rough, throwaway wireframes that answer a layout or flow question before the spec is settled. It works with a brief-stage spec, a full spec, or only a feature name and a few words from the user. Unlike brainstorm's open visual exploration, it is tied to one feature and writes its decisions back into that feature's `spec.md`.

## What changes

| Concern | Explore rule |
|---|---|
| **Output** | Only `${aiDir}/features/{feature}/exploration/`, never `mockups/`. Throwaway by default. At wrap-up it may also write `spec.md` and the `index.yaml` entry (below). |
| **Fidelity** | Low visual, high content. Greyscale, no styling beyond what the layout needs, no design-system components, no brand. Realistic content from the spec, the brief and the user's words; never Lorem ipsum. |
| **Format** | One self-contained HTML file per variant (inline greyscale styles, no scripts, no network), so it opens directly in a browser and doubles as the `/myspec:visualize-options` preview. Draw with the wireframe vocabulary of [Visual Buddy's mock elements](../../brainstorm/visual-buddy.md#mock-elements-wireframe-building-blocks): boxes, placeholders, plain buttons and inputs. When the question is flow, not layout, draw a breadboard (places, the affordances on each, the connections between them) or a flow diagram as inline SVG instead ([Diagrams and graphs](../../brainstorm/visual-buddy.md#diagrams-and-graphs)). |
| **Variants** | 2-4 per surface, differing in structure (layout, information architecture, flow) by default. Never a style comparison. |
| **Label** | Every file shows a visible "Exploration, not a design" banner at the top, so nobody mistakes it for a design or ships from it. |
| **States** | Shown as frames side by side in one file (empty, error, success next to each other), not through preview controls. |
| **Traceability** | Tag each surface and each notable element `hypothesis`, `open question` or `candidate requirement` instead of a Source AC. Name the REQ or AC too when one covers it. |
| **Data** | Invented fields and enum values are allowed. Mark each in the file as `(guess)` and log it for wrap-up. |

**Relaxed** (skip unless the user asks): the spec.md requirement, AC traceability, design-system defaults, typed mock data and exact enum copying, the reuse audit, the production sibling sweep (a quick look is optional), reference-mockup consistency, the catalog skim, `verify` / `compileCheck` / `audit` / preview controls, one primary CTA, destructive-action confirmation, modal dismissal paths, rule extraction and the commit prompt.

**Kept**: the write scope above, no data-model changes, variants vary structure not style, navigation reads as navigation (links look like links and use `href="#mock-path"`), picks go through `/myspec:visualize-options`, and the batched dossier of at most 4 questions.

## Workflow

1. **Resolve the feature.** Use the slug the user passed, or ask for one. Read `${aiDir}/features/{feature}/spec.md` if it exists (either stage), `seed.json` and `scenarios.md` if present, and the user's own words. No spec.md is fine: work from the user's words and log every gap as a guess.
2. **Dossier.** One `AskUserQuestion`, at most 4 questions, recommended answer first: audience, devices, the question to explore (layout, flow, or both), and which surfaces. No style question. Drop what the spec or the user already answered.
3. **Propose.** A numbered list of surfaces, each with its variants (one line on how each differs) and its tag. Confirm "go".
4. **Build.** Write `exploration/{surface}-{a|b|c|d}.html`, or `exploration/{surface}-flow.html` for a breadboard. No verify or compile steps.
5. **Pick and iterate.** For each surface, ask which variant wins through `/myspec:visualize-options`: one option per variant, its file's markup as the preview. Feedback edits the affected files only. Keep a session log of every pick, decision, guess and candidate requirement.
6. **Wrap up**, in this order:
   1. **Write decisions back.** Each pick or settled question becomes one `- [decision] {what was decided} (user)` line in the spec's Open Questions. Each guess that stays becomes `- [assumption] {belief} (inferred)`. A candidate requirement the user confirms becomes a new REQ line in a brief-stage spec (next unused ID), or an `- [open] {question} (user) -> resolve by: spec; default: {value}` line in a full spec. Show the lines and ask once before writing them.
   2. **No spec.md yet:** create one in [the brief stage](../../_shared/spec-template.md#brief-stage) of the spec template. Fill only what the session supports, and tag inferred lines `(inferred)`, never `(user)`. Then append an `index.yaml` entry with `status: draft`, shaped like its siblings.
   3. **Handoff list**, as in normal mode, for any real code, schema or design-system need that came up.
   4. **Leave exploration/ uncommitted** and say so in one line: the user deletes it or keeps it as reference. Recommend the next step: `/myspec:feature-mockup {feature}` for high-fidelity mockups, or `/myspec:feature-spec {feature}` to complete the spec.

## Later, in high-fidelity mode

Normal `feature-mockup` treats `exploration/` as reference only: it may cite the layout the user picked, and never imports or copies the exploration files. `feature-mockup-review` ignores `exploration/`.
