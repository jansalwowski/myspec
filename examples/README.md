# Examples

Walk-throughs showing how myspec skills behave in practice. Two flavors:

- **Single-skill examples** (memorize, memorify) — one skill, one transcript, one output.
- **Multi-skill flows** (in [flows/](flows/)) — end-to-end scenarios where several skills compose. Start here if you're new to myspec; the flows show how the pieces fit together.

---

## Multi-skill flows

The complex stuff. Each flow stitches together 3–12 skill calls and shows the handoffs.

| Flow | Skills involved | Use it to understand |
|------|-----------------|----------------------|
| [flows/full-feature-delivery.md](flows/full-feature-delivery.md) | `brainstorm` → `idea-intake` → `idea-process` → `feature-spec-review` → `cross-spec-validation` → `feature-tech-spec` → `feature-tech-spec-review` → `feature-plan` → `feature-implement` → `feature-verify` → `feature-complete` | The full pipeline from "I have an idea" to "merged and shipped." |
| [flows/feature-decomposition.md](flows/feature-decomposition.md) | `feature-decompose` → per-sub-feature `feature-tech-spec` + `feature-plan` + `feature-implement` + `feature-complete`, with `cross-spec-validation` between them | Splitting a too-large feature into independently shippable sub-features. |
| [flows/session-with-memory-extraction.md](flows/session-with-memory-extraction.md) | `bootstrap` → auto-session via hook → `session-complete` (vs. `memorify` as the alternative) | How session tracking, the `mark-code-changed.sh` hook, and memory extraction fit together. |
| [flows/debugging-with-memory.md](flows/debugging-with-memory.md) | `memory-lookup` → `root-cause-debugging` (4 phases) → `memorize` | The full debugging loop: check what's known, investigate methodically, save the lesson. |
| [flows/spec-drift-recovery.md](flows/spec-drift-recovery.md) | `feature-verify` → `feature-spec-sync` → `cross-spec-validation` → `feature-spec-cleanup` → `feature-verify` | Recovering a feature whose spec has drifted from the code. |

---

## Single-skill examples

### memorize

| File | Scenario | Highlights |
|------|----------|------------|
| [memorize-simple-rule.md](memorize-simple-rule.md) | Capture a one-line procedural rule | Minimal questions, single draft, no anchor |
| [memorize-semantic-fact.md](memorize-semantic-fact.md) | Save a stable system fact | Adds a code anchor for later re-verification |
| [memorize-anti-pattern.md](memorize-anti-pattern.md) | Save a "never do this" rule | Negative polarity, explicit `not_for` exclusions |
| [memorize-critical-decision.md](memorize-critical-decision.md) | Save a dated decision and pin it | Episodic type + Layer 1 promotion to always-loaded index |

### memorify

| File | Scenario | Highlights |
|------|----------|------------|
| [memorify-single-candidate.md](memorify-single-candidate.md) | One memory surfaces from a debugging session | Standard happy path |
| [memorify-multi-candidate.md](memorify-multi-candidate.md) | Three memories saved with cross-links | Per-candidate confirmation, `related` linking |
| [memorify-nothing-found.md](memorify-nothing-found.md) | Sweep yields nothing worth keeping | Skill stops cleanly without forcing a save |

### When to use which memory skill

- **`/memorize`** — you already know the exact thing to save. Hand it over inline.
- **`/memorify`** — you want the agent to look back over the conversation and propose what's worth keeping.
- **`/session-complete`** — wrapping up a tracked session; extracts memories from the session log table.

---

## Reading the examples

Each file follows the same shape:

1. **Setup / situation** — the context that motivated the call.
2. **At a glance** — for flows: a table summarizing the steps and approval gates.
3. **Step-by-step transcript** — the agent's questions, the artifacts produced, and the user's confirmations.
4. **Result** — the files written, manifest entries updated, branch state.
5. **What this demonstrates** — the design intent behind the flow, in case you're trying to apply the same pattern to your own work.

For memory examples, the internal classification (procedural / semantic / episodic) appears in *italic side-notes* so you can see how the skill reasons — but in real usage those terms never reach the user.

---

## Want examples for other skills?

The single-skill catalog above only covers the memory skills. If you'd find walk-throughs useful for `feature-spec`, `brainstorm`, `feature-update`, `idea-process`, or any other skill in isolation, open an issue or send a PR — examples are intentionally easy to add.
