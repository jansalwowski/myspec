# Examples

Walk-throughs showing how myspec skills behave in practice. Two flavors:

- **Per-skill examples** in [skills/](skills/) — one document per skill, multiple scenarios as sections within. Start here if you want to understand how a single skill behaves across different inputs.
- **Multi-skill flows** in [flows/](flows/) — end-to-end scenarios where several skills compose. Start here if you're new to myspec; the flows show how the pieces fit together.

---

## Per-skill examples

### Feature lifecycle

The eight skills you'll use to take a feature from idea to shipped:

| Skill | Scenarios covered |
|-------|-------------------|
| [skills/feature-discover.md](skills/feature-discover.md) | Discovery only (capture tribal knowledge) · Full feature docs (pull existing code into pipeline) · Complex feature routes to decomposition |
| [skills/feature-spec.md](skills/feature-spec.md) | Greenfield small feature · Cross-feature dependencies · Skill recommends decomposing first |
| [skills/feature-decompose.md](skills/feature-decompose.md) | Mixed-priority split with deferred sub-features · Skill refuses to decompose |
| [skills/feature-tech-spec.md](skills/feature-tech-spec.md) | Pattern-following design · ADR-heavy with alternatives · Discovers spec gap during design |
| [skills/feature-plan.md](skills/feature-plan.md) | Single-milestone plan · Multi-milestone with parallel groups · Plan refuses, recommends decompose |
| [skills/feature-implement.md](skills/feature-implement.md) | Sequential execution · Parallel group with worktree dispatch · Resume mid-milestone after interruption |
| [skills/feature-update.md](skills/feature-update.md) | Add a capability to a shipped feature · Remove a deprecated capability |
| [skills/feature-verify.md](skills/feature-verify.md) | Clean health check · Mixed report with severity-ranked routing |
| [skills/feature-complete.md](skills/feature-complete.md) | Clean completion · Discovers late drift during completion |

### Spec quality

| Skill | Scenarios covered |
|-------|-------------------|
| [skills/cross-spec-validation.md](skills/cross-spec-validation.md) | Single sibling break · Multiple breaks across siblings · No conflicts (clean pass) |

### Memory + sessions

| Skill | Scenarios covered |
|-------|-------------------|
| [skills/bootstrap.md](skills/bootstrap.md) | Standard bootstrap with task-relevant memory · Stale session auto-archive · Fresh project (no memories yet) |
| [skills/memory-lookup.md](skills/memory-lookup.md) | Direct procedural match · Partial match across types · No match (clean miss) |
| [skills/memorize.md](skills/memorize.md) | Simple procedural rule · Semantic fact with anchor · Anti-pattern (negative polarity) · Critical decision with Layer 1 promotion |
| [skills/memorify.md](skills/memorify.md) | Single candidate from a debugging session · Multiple candidates with cross-links · Nothing worth saving |
| [skills/session-complete.md](skills/session-complete.md) | Multiple memories with cross-links · Nothing extractable · Multiple active sessions (multi-agent) |
| [skills/session-clean.md](skills/session-clean.md) | Routine sweep (mixed empty + substantive) · Ambiguous siblings with live worktree · Nothing to do (clean directory) |

### When to use which memory skill

- **`/memorize`** — you already know the exact thing to save. Hand it over inline.
- **`/memorify`** — you want the agent to look back over the conversation and propose what's worth keeping.
- **`/session-complete`** — wrapping up a tracked session; extracts memories from the session log table.
- **`/session-clean`** — periodic sweep of the active sessions directory; deletes empty leftovers and archives substantive ones that were never closed.
- **`/memory-lookup`** — search before you start work or debug. The first thing to run on a new bug or unfamiliar area.

### Ideas pipeline

| Skill | Scenarios covered |
|-------|-------------------|
| [skills/idea-intake.md](skills/idea-intake.md) | Standard new idea · Scope clarification (split) · Blocked by unsatisfied dependencies |
| [skills/idea-process.md](skills/idea-process.md) | Clean conversion of a queued idea · Blocked by dependencies · Idea too vague (bounces to brainstorm) |

### Investigation + exploration

| Skill | Scenarios covered |
|-------|-------------------|
| [skills/brainstorm.md](skills/brainstorm.md) | Standard divergent → convergent · Topic too large (decompose) · Devil's advocate / stress-test |
| [skills/root-cause-debugging.md](skills/root-cause-debugging.md) | Single-component bug found in Phase 1 · Multi-component bug with boundary tracing · Stuck in a loop (3-attempt escalation) |

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

## Reading the examples

Each per-skill document is one H1 (the skill) followed by an H2 per scenario, sub-divided into Setup → Invocation → Skill flow → Result → Why this example matters. Scroll to the scenario you care about, or read top-to-bottom.

Each flow follows a similar shape, plus an "at a glance" summary table at the top so you can see the whole pipeline before diving in.

For memory examples, the internal classification (procedural / semantic / episodic) appears in *italic side-notes* so you can see how the skill reasons — but in real usage those terms never reach the user.

---

## Want examples for other skills?

Skills not yet covered by per-skill examples:

- **Spec quality** — `feature-spec-review`, `feature-tech-spec-review` (mostly gating; visible in flows)
- **Drift fixers** — `feature-spec-sync`, `feature-spec-cleanup` (covered in [flows/spec-drift-recovery.md](flows/spec-drift-recovery.md))
- **Auxiliary** — `feature-scenario`, `feature-seed-data`
- **Project setup** — `init`, `update`, `setup`
- **Memory + sessions** — `memory-preflight`, `memory-create`, `session-start`
- **Utilities** — `skill-verify`, `worktree-cleanup`, `docs-sanitize`

If you'd find walk-throughs useful for any of these in isolation, open an issue or send a PR — examples are easy to add: each skill gets one file in `skills/{skill-name}.md` with H2 sections per scenario.
