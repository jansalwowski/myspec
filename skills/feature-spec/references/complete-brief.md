# Completing a Brief-Stage Spec

`feature-spec` follows this when `${aiDir}/features/{feature}/spec.md` has `stage: brief` in its frontmatter. The brief stage and the full shape are both in [`_shared/spec-template.md`](../../_shared/spec-template.md#brief-stage). Complete the file in place: never create a second spec, never rename the feature.

## Procedure

1. **Read the inputs**
   - The brief: every REQ line and every Open Questions line with its tags.
   - Mockups, when they exist: `${aiDir}/features/{feature}/mockups/` (each file's title header names its Source REQ or AC and its States covered) and `${aiDir}/features/{feature}/exploration/` (the variants the user picked; read them as reference, the `[decision]` lines say which one won).
   - No mockups: derive from the brief and the user's answers alone, and every AC says `no UI` or names the state it implies.

2. **Map examples to rules to ACs** (example mapping)
   - Each mockup state is one concrete example: "invoice list, no invoices yet", "export failed, retry shown".
   - Group the examples under the rule they illustrate: "an empty list explains how to create the first invoice".
   - Each rule becomes one acceptance criterion, in the template's `- [ ] AC-n:` form.
   - Expand each terse REQ line into a testable requirement. Keep its ID. A new requirement takes the next unused ID.
   - User Stories come from the Who line and the rules: one story per actor goal.

3. **Run the "what mockups miss" checklist**
   Mockups show the screens someone thought of. Go through every item below. Each one is covered by an AC, or marked N/A with a reason in one line, or becomes an Open Questions line:

   | Area | Check |
   |------|-------|
   | States | empty, first use, loading, partial, error, success, disabled, offline or timeout |
   | Errors | what fails, what the user sees, how they recover |
   | Permissions | what each role can see and do |
   | Data rules | limits, formats, uniqueness, defaults, time zones, rounding, retention |
   | Edge content | long or missing text, 0 / 1 / many items, volume, languages and locales |
   | Invisible behaviour | notifications, background jobs, audit log, analytics, side effects on other features |
   | Non-functional | performance, scale, security, privacy, availability |
   | Accessibility | keyboard use, screen readers, contrast, focus order |
   | Lifecycle | undo and delete, cancel midway, back button, deep links, session expiry |
   | Integrations | each external system failing or slow |

   Ask the user only about items no source answers, at most 4 questions per `AskUserQuestion` call, each with a recommended answer. When the user asked for no questions, each unanswered item becomes an Open Questions line with a default.

4. **Trace both ways**
   - Every AC ends with its origin: `(mockup: {file} / {state})` or `(no UI)`.
   - Every mockup state maps to at least one AC. A state with no AC is either a missing AC (add it) or scope creep (list it in the summary for the user to drop from the mockup).

5. **Fold the Open Questions**
   - `[decision]` and `[fact]` lines become requirement or AC text, then leave Open Questions.
   - `[assumption]` lines the user confirmed become requirements. The others stay as open questions.
   - Remaining `[open]` lines stay, rewritten in the full template's plain form: the question, its default, and the stage that resolves it. Drop the status and source tags.
   - Write "None." when nothing remains.

6. **Finish the file**
   - Remove `stage: brief` from the frontmatter. Keep `status: draft` and `spec_version` as it is (a light brief check may already have raised it). Set `last_updated` to today.
   - Check the result against the full template: every required section, REQ IDs, AC IDs, no implementation detail.

Then the SKILL.md workflow continues at Step 3 (dependencies.md). The manifest entry already exists from the brief: Step 4 updates it, never adds a second one.

## Summary for the user

Before Step 5 of the SKILL.md, list in a few lines: how many ACs came from mockup states and how many say `no UI`, the checklist items marked N/A, the mockup states flagged as scope creep, and the open questions left.
