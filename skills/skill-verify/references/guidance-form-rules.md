# Guidance Form Rules

Read by skill-verify step 6 for Anti-Patterns #15 and #16.

Normative guidance has a form, and each form fixes exactly one failure type; the form that bulletproofs one measurably backfires on another. Classify the failure the guidance targets, then check the form (mismatch = Anti-Pattern #15):

| Baseline failure the guidance targets | Right form | Wrong form — flag it |
|---|---|---|
| Skips/violates a rule under pressure (knows better, does it anyway) | Prohibition + rationalization table + red flags | Soft guidance ("prefer...", "consider...") |
| Complies, but output has the wrong shape (bloated, buried verdict, restated spec) | Positive recipe or contract: state what the output IS — its parts, in order | Prohibition list ("don't restate", "never narrate") |
| Omits a required element from something they already produce | Structural: REQUIRED field or slot in the template they fill in | Prose reminders near the template |
| Behavior should depend on a condition | Conditional keyed to an observable predicate | Unconditional rule + exemption clauses |

Prohibitions backfire on shaping problems because agents negotiate with "don't X" under a competing incentive: in head-to-head tests the prohibition arm produced more of the unwanted content than the recipe arm, and trended worse than the no-guidance control. A recipe leaves nothing to negotiate. Rewrite a shape-targeting prohibition list as a recipe, tagged `[requires confirmation]`.

Two wording rules apply to whichever form is used (violation = Anti-Pattern #16):

- **No nuance clauses.** "Don't X unless it matters" reopens the negotiation — one nuance clause degraded a winning recipe from consistent to noisy. Express the real exception as its own conditional on an observable predicate.
- **Exemption clauses don't scope.** "This limit doesn't apply to code blocks" still suppresses code blocks. Restructure so the rule cannot reach the exempt part.

A workflow branch keyed to an observable predicate ("if the frontmatter has a `dependencies:` block") is the right form, not a hedge. Flag only hedges whose predicate is a judgment call ("matters", "necessary", "makes sense").
