# Autopilot

Opt-in mode for the feature pipeline skills whose `AskUserQuestion` gates otherwise block: `feature-spec-review`, `cross-spec-validation`, `feature-tech-spec-review`, `feature-plan`, `feature-implement`. One feature run can hit a dozen gates before any code exists (issue #98), most of them confirming the option the skill already recommends. Autopilot answers those gates for the user and still stops where their judgment is the point.

## Turning it on

Autopilot is on only when the user asked for it in this session: the words "autopilot" or "proceed without asking", or `--autopilot` in the skill's arguments. Never infer it from silence, speed, or an earlier session. It stays on for the pipeline skills this run hands off to, until the user turns it off. Announce it once: "Autopilot on — taking recommended options; stopping on Critical findings, failing probes, and outward-facing actions."

## At a gate

| Gate | Autopilot answer |
|------|------------------|
| Option list with one marked `(Recommended)` | That option |
| "Review passed — mark `status: approved`?" | Yes, when the skill's own rule says the review passed (no Critical/High open) |
| Next-step / hand-off choice | The recommended skill, invoked directly |
| Fixes tagged `[requires confirmation]` with no Critical among them | Apply the ones the skill recommends; leave the rest unapplied and listed |

Print each decision as it is made — `Autopilot: <gate header> → <option> — <why it was recommended>` — so the transcript shows what was chosen on the user's behalf. `feature-implement` also records it in the Execution Log as a `Ruling:` line, so it reaches "Rulings I made".

## Still stops and asks

Autopilot never answers these; ask exactly as without it:

- Any open **Critical** finding, in any review or gate
- A checkpoint probe that came back FAIL or BLOCKED — fix and waive are the user's calls, and a waiver is never automatic
- An outward-facing or irreversible action: push, opening or merging a PR, deploy, publish, force operations, deleting data or files the user wrote
- `feature-implement`'s hard stops (Rulings, Not Stalls) and a dirty working tree at Step 0
- A gate with no recommended option, or one the skill says needs the user's decision by name (a `DEFERRED` requirement in `feature-plan`, a scope cut)
- The user's own earlier answer contradicts the recommendation — their answer wins

At the end of the run, list every autopilot decision in the skill's summary so the user can reverse any of them.
