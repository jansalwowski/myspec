---
name: "feature-requirements"
description: "Use when a feature starts from rough, partial or ticket-only requirements to gather and challenge before mockups or a full spec. Do NOT use when the scope is clear and the spec is wanted (feature-spec), or for open ideation (brainstorm)."
tags: [feature, requirements, specification, discovery]
---

# Feature Requirements

Turns rough input into a brief: a short, tagged `spec.md` in the brief stage that mockups can trace to and `feature-spec` completes later. The skill assists. It never gates: the user can stop at any point, and the brief is written with whatever is still open.

## Arguments

- `/myspec:feature-requirements {feature} [sources…]`: sources are anything the user gives: pasted text, links, ticket or issue IDs, documents, an `${aiDir}/ideas/` idea file. Without a feature name, propose a kebab-case one from the sources.
- `--autopilot`, or "don't ask me anything": skip Step 4's questions; every gap becomes a tagged assumption with a default.

## Workflow

1. **Read the sources and the feature folder**
   - Read every source the user gave. An idea file is a source only: leave its text unchanged, and in `${aiDir}/ideas/PRIORITY-LISTING.md` mark its row `[~]` (in progress) so `idea-process` does not pick it up and write a second spec over the brief.
   - Read `${aiDir}/features/index.yaml` for the slug and related features.
   - If `${aiDir}/features/{feature}/spec.md` exists:
     - with `stage: brief`: refine it in place. Keep every REQ ID and every `[decision]` line, and continue from Step 3.
     - without `stage`: it is a full spec. Do not overwrite it. Route to `/myspec:feature-spec {feature}` for an unimplemented draft, or `/myspec:feature-update {feature}` for a feature already built, and stop.

2. **Draft the brief first**
   Fill the brief shape in [`_shared/spec-template.md`](../_shared/spec-template.md#brief-stage) from the sources before asking anything: guess, then log. Fill only what a source supports. Tag where each Open Questions line came from. Every gap becomes an `[assumption] … (inferred)` line, or an `[open]` line with its resolve-by stage and a default. Never write inferred content as something the user said: an AI filling gaps silently is the failure this skill exists to prevent.

3. **Scan coverage**
   Rate each brief field Clear, Partial or Missing: Problem, Who, Today (evidence), Success, Appetite, Requirements, Out of Scope. Show the ratings as one short table.

4. **Challenge**
   Lead with the strongest concern, not with praise. Look for:

   | Lens | Signal | Ask |
   |------|--------|-----|
   | Solution-first | The request names a screen, button or tool, not a problem | "What problem does this solve?" and "Is there more than one way to meet it?" |
   | Vague words | fast, simple, user-friendly, robust, intuitive, several, etc., and/or, should | A number, a limit, or one concrete example |
   | Missing evidence | No current workaround, complaint or data | "Tell me about the last time this happened." |
   | Hidden stakeholders | Support, operations, legal or privacy, billing, admins | "Who else is affected when this changes?" |
   | No success signal | Nothing observable says it worked | "How will we know it worked?" |
   | No no-gos | Out of Scope is empty | "What should this explicitly not do?" |

   Ask with `AskUserQuestion`: at most 4 questions per call, ranked by impact. Each question names its recommended answer and one line on why it matters. Whatever stays unasked becomes a labelled assumption with a default. After each round, update the draft and offer one more round or "write it now". The user can stop at any time. Never refuse to write the brief because something is open. Under autopilot, ask nothing and say so in one line.

5. **Write the brief**
   - Write `${aiDir}/features/{feature}/spec.md` in the brief stage per the template's brief shape, with `stage: brief` and `status: draft`. Answers become `(user)` lines, or fold into the Overview, Goals and Requirements bullets.
   - Add the manifest entry to `${aiDir}/features/index.yaml` when it is missing: `status: draft`, plus `title`, `phase`, `priority` and `depends-on` as `feature-spec` writes them. A brief-stage spec meets the draft status; no new status exists.
   - Do not write dependencies.md: `feature-spec` writes it when it completes the spec.
   - Do not ask about committing. Say in one line that the files are uncommitted.

6. **Recommend the next step**
   Read the signals and call `AskUserQuestion`, with the recommended option first and `(Recommended)` appended:

   | Signals | Recommend |
   |---------|-----------|
   | UI-heavy, a new interaction, layout is the problem, "I'll know it when I see it", usability risk | `/myspec:feature-mockup {feature} --explore` for rough variants, or `/myspec:feature-mockup {feature}` for high fidelity |
   | Backend, integration or API contract, migration, rule-heavy, compliance, a known pattern | `/myspec:feature-spec {feature}` to complete the spec |

   Always offer "Stop here" too. The user decides. Run the chosen skill only on their pick.

## Rules

- The brief stays a brief: about 25 lines, no User Stories, no Acceptance Criteria, no implementation detail.
- The Problem line holds no solution words.
- Never set `status: approved` on a brief.
- Never quote failure statistics or cost-of-change curves to persuade the user: the evidence behind them is weak.

## Verification Checklist

- [ ] Every source the user gave was read; an idea file's text was left unchanged and its PRIORITY-LISTING row marked `[~]`
- [ ] An existing full spec was not overwritten; an existing brief kept its REQ IDs and `[decision]` lines
- [ ] spec.md has `stage: brief` and `status: draft`, and matches the brief shape in `_shared/spec-template.md`
- [ ] Every Open Questions line has a status tag and a source tag; every `[open]` line has a resolve-by stage and a default
- [ ] No inferred content is tagged `(user)`
- [ ] Questions asked in calls of at most 4, each with a recommended answer, or skipped under autopilot
- [ ] Manifest entry present with `status: draft`; no dependencies.md written
- [ ] The next step was recommended and left to the user

## Integration

**Next (design first)** [OPTIONAL]: `/myspec:feature-mockup` (`--explore` for rough variants), which traces surfaces to the brief's REQ IDs
**Next (spec first)** [OPTIONAL]: `/myspec:feature-spec`, which completes the brief in place into a full spec
**Reads** [OPTIONAL]: an idea file from `/myspec:idea-intake`, as a source only
