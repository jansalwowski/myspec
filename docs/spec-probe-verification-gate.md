---
title: "Probe Verification Gate"
status: draft
phase: 1
priority: P2
spec_version: 1
created: 2026-09-07
last_updated: 2026-09-07
---

Spec for [issue #18](https://github.com/jansalwowski/myspec/issues/18), Phase 1 only.

myspec does not install itself into its own repo (see `AGENTS.md`), so there is no
`${aiDir}/features/` tree to hold this. It lives in `docs/` in the shape
`feature-spec` would have produced, and the dependency section stands in for
`dependencies.md`.

## Overview

A milestone checkpoint in `feature-implement` is verified by the same controller
that decides whether to run the verification. When the obvious probe is blocked by
environment friction, adjacent signals — unit tests green, code matches the spec —
are available as substitutes, and declaring the checkpoint passed is the cheapest
path. This feature moves the execution of plan-time-authored assertions into a
separate agent that holds the assertions and nothing else, so the decision to skip
is not available to the agent that would benefit from it.

## Goals

- Separate the agent that authors a verification from the agent that decides whether
  it ran.
- Make a checkpoint's verification executable rather than narrative: an assertion
  written before implementation, run against a live target, returning a literal
  observed value.
- Catch the two defect classes a diff reviewer structurally cannot: code that
  correctly implements an under-specified requirement, and a probe that was never
  executed (both look clean in a diff).
- Cost nothing on features that render nothing — a backend migration or a docs
  change must not acquire a browser gate.

## Requirements

1. A feature must be able to declare its verification medium. The declaration must
   support `visual`, `api`, `data`, `mixed`, and `none`, and `mixed` must resolve
   per milestone rather than per feature.
2. A feature whose medium is not `none` must declare a contract surface appropriate
   to that medium — the stable, refactor-tolerant handles an assertion is allowed to
   reference. For `visual` this is test IDs on the public surface plus reactive
   state attributes; for `api` a request/response shape; for `data` a schema
   expectation.
3. A milestone checkpoint must be able to carry assertions written as literal
   executable expressions in the medium's own language, authored before
   implementation begins.
4. An assertion must reference only the declared contract surface. An assertion that
   reaches past it — into CSS class names, internal DOM structure, or private state —
   must be rejected at review time as unstable.
5. Review of the technical design must reject a feature whose declared medium has no
   corresponding contract surface. Review of the plan must reject a milestone
   checkpoint that carries no assertions when its medium requires them.
6. A probe reviewer must execute assertions verbatim. It must not reword, narrow,
   substitute, or skip one.
7. A probe reviewer must report, per assertion, a pass/fail verdict and the value it
   actually observed, plus a path to an audit artifact (a screenshot, a response
   body, a query result).
8. A probe reviewer must not be able to modify the code it is testing. Its tool
   surface is the probe medium, reading files, and asking the user a question.
9. When environment friction blocks a probe, the reviewer must surface the block to
   the user and stop. It must not substitute an adjacent signal and must not report
   a verdict it did not observe.
10. A probe reviewer must not receive the spec rationale, the plan's reasoning, or
    the implementers' reports. Its context is the assertion list and the target.
11. Phase 1 must be invocable by hand, per milestone, leaving existing flows
    unchanged. Automatic dispatch from `feature-implement` is Phase 2 and is out of
    scope here.
12. Phase 1 must ship the visual medium only. The `api` and `data` siblings are
    declared in the schema but unimplemented, and a feature declaring one must be
    told so rather than silently ungated.

## Acceptance Criteria

- A feature that declares no medium behaves exactly as it does today — no new
  section is required of it, no review dimension fires, no gate exists.
- A feature that declares `none` is accepted without a contract surface and without
  assertions.
- A technical design declaring `visual` without a contract surface is rejected by
  design review, naming the missing section.
- A plan whose milestone checkpoint declares `visual` and carries no assertions is
  rejected by the coverage pass before the plan is saved.
- An assertion referencing a CSS class name rather than a declared test ID is
  rejected at design or plan review, naming the unstable reference.
- Invoking the probe reviewer for a milestone returns one verdict per assertion,
  each carrying the observed value and an artifact path, and no verdict for an
  assertion that was not run.
- A probe reviewer given an assertion it cannot execute reports the block and stops;
  it returns no pass verdict for that assertion.
- A probe reviewer asked to modify the code under test cannot do so — the tools are
  absent, not merely discouraged.
- A feature declaring `api` or `data` in Phase 1 is told the medium is not yet
  implemented, and its checkpoint is not reported as verified.

## Design Decisions

The issue left four questions open. Resolved here, and open to revision before
technical design:

**Where the medium is declared — the technical design, not the product spec.**
The product spec states the observable behavior; whether that behavior is checked
through a browser, an endpoint, or a query is a property of how it was built. The
contract surface (test IDs, response shapes) already lives in the technical design,
and separating the mode from the surface it selects would let the two drift.

**Pixel-diff is a separate future mode, not part of `visual`.**
Comparing against a stored reference image needs baseline storage, an approval
workflow for intended changes, and a rendering environment stable enough that a font
substitution is not a failure. That is a different feature. `visual` in Phase 1 means
sampling declared properties of a live render — a colour at a region, a computed
style, an element's presence and state.

**`mixed` dispatches one reviewer per medium, in sequence, per milestone.**
Each reviewer receives only the assertion block for its own medium. The alternative —
one reviewer dispatching to siblings per assertion — reintroduces an agent that sees
all the signals at once, which is the property this feature exists to remove.

**The probe reviewer ships from the plugin's own `agents/` directory.**
Since 2.0 the plugin ships no agent definitions and installs none into user scope.
This reintroduces the first one, and does so without writing to user scope. Dispatch
name resolution and precedence against a user's own agent of the same name are
unverified and must be tested before this ships — see Open Questions.

## Out of Scope

- Automatic dispatch of the probe reviewer from `feature-implement` (Phase 2).
- The `http-probe-review` and `data-probe-review` siblings (Phase 3, and only once an
  equivalent failure has actually been observed in those media).
- Pixel-parity visual regression against stored baselines.
- Retrofitting assertions onto features whose plans predate this.
- Choosing or mandating a browser automation tool for a project; the medium is
  declared, the tooling is the project's.
- Standing up the target the probe runs against. Whether that is an existing
  component harness or a temporary development page created in the first milestone
  and removed at feature completion is a per-plan decision, not a framework one.

## Open Questions

1. Does a plugin-shipped agent definition resolve by dispatch name, and what happens
   when a consumer project defines an agent with the same name? This gates the whole
   feature and is testable today, independently of everything else here.
2. Should a checkpoint's assertions be reviewable as a unit before implementation
   begins — an explicit user approval of "this is what will prove the milestone" —
   or does design review plus plan review cover it?
3. When an assertion fails, does the milestone reopen as a fix loop (as a phase
   review does today), or does it stop for the user? A failing probe often means the
   spec was misread, which a fix loop is not equipped to resolve.
4. Is `none` an honest declaration or an escape hatch? A feature can always claim it.
   Whether design review should challenge a `none` on a feature that visibly renders
   is undecided.

## Dependencies

**Depends on:** nothing shipped. The contract surface additions sit inside existing
documents, and the review dimensions extend existing rubrics.

**Depended on by:** Phase 2 (automatic dispatch) and Phase 3 (the `api` and `data`
siblings) both require Phase 1's schema and reviewer contract.

**Related:** the phase reviewer in `feature-implement` reads a diff package and runs
the project's verification commands. This feature does not change that seam; it adds
a second gate that reads none of it.

**External:** a browser automation capability available to the reviewer agent. Phase
1 does not vendor one.
