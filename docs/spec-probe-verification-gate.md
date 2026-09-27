---
title: "Probe Verification Gate"
status: draft
phase: 1
priority: P2
spec_version: 2
created: 2026-09-07
last_updated: 2026-09-27
---

Spec for [issue #18](https://github.com/jansalwowski/myspec/issues/18), Phase 1 only,
with [issue #92](https://github.com/jansalwowski/myspec/issues/92) folded in (spec_version 2).

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
- Put the checks that found the most bugs in a real 20-task run (#92) — a clickable
  demo on scratch data and a real-engine run over a real corpus — into the milestone
  gate instead of leaving them to controller improvisation.
- Make it hard to run those checks against real infrastructure by accident. A demo
  in that run overwrote 91 objects in an unversioned production bucket because one
  bucket variable was left unset.

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
11. Phase 1 must leave existing flows unchanged for plans that carry no probes.
    (spec_version 1 also kept dispatch manual and deferred automatic dispatch from
    `feature-implement` to Phase 2; spec_version 2 moves it in — see Design
    Decisions.)
12. ~~Phase 1 must ship the visual medium only.~~ Superseded in spec_version 2: the
    probe executor runs whatever literal commands the plan authored, in any medium
    the session has a tool for, and reports BLOCKED where it has none. No medium is
    silently ungated, which was the point of the original requirement.
13. A milestone checkpoint must not be marked passed by the controller without the
    probe executor's per-probe evidence, or an explicit user waiver of the named
    probe recorded in the plan's Execution Log. A FAIL or BLOCKED probe stops for
    the user.
14. For a feature with a UI surface, a milestone checkpoint may carry a **demo
    gate**: the probe executor serves the milestone on scratch data, walks the
    declared flows, and returns a clickable URL plus screenshots, which the user
    reviews at the checkpoint prompt.
15. Where the technical design names a real input corpus, a milestone checkpoint
    touching that path must carry a **real-input gate**: the real engine runs over
    the corpus and the observed output is compared with the declared expectation
    (for an "output unchanged" invariant, the same command at the base commit).
16. Every probe that writes — demo, real-input, data — must run in a scratch
    environment that satisfies a shared checklist: a separate database; a separate
    storage bucket with every bucket-related variable set explicitly; a separate
    queue port, not only a separate DB index; and a post-run check that the real
    database, bucket, and queue were untouched.
17. Phase reviewers must prefer real-engine / real-data checks over mocks for
    invariants over real output ("output unchanged", "never splits"). A mocked test
    pinning such an invariant does not by itself prove it.

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
- A probe the executor has no tool for is reported BLOCKED, and its checkpoint is not
  reported as verified.
- The controller cannot move past a milestone checkpoint whose probe report is
  missing, FAIL, or BLOCKED without the user either fixing it or waiving the named
  probe; the waiver lands in the Execution Log and the completion report.
- A demo gate returns a URL and screenshot paths, and the checkpoint prompt shows
  both to the user.
- A probe run whose scratch checklist is incomplete, or whose post-run untouched
  check fails, is reported BLOCKED (incomplete) or FAIL (touched), never PASS.

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

**Changes in spec_version 2 (#92).** The resolved decisions above stand, with three
changes, each recorded rather than silently applied:

- *Checkpoint dispatch moves into Phase 1.* #92 places the demo and real-input gates
  in the milestone checkpoint itself, and requirement 13 is meaningless if the gate
  is only invocable by hand. `feature-implement` Step 4b dispatches the probe
  executor; manual invocation is no longer a separate surface. Requirement 11 is
  narrowed accordingly: plans without probes still behave exactly as today.
- *The executor is a prompt template, not a plugin-shipped agent — for now.* Open
  Question 1 (dispatch-name resolution and precedence for plugin `agents/`) is still
  untested. Phase 1 ships `skills/feature-implement/probe-executor-prompt.md`,
  dispatched like the other reviewers, with its no-edit rule stated in the prompt.
  Requirement 8's "tools absent, not merely discouraged" is deferred to the agent
  definition once Open Question 1 is answered.
- *Medium-agnostic executor.* Requirement 12 is superseded (see above). `mixed`
  dispatches one executor per milestone with the whole block, not one per medium:
  probes run in plan order and may depend on an earlier probe's writes (an `[api]`
  count after a `[visual]` save), and per-medium executors each restarting the
  target killed the demo an earlier one left running. The executor still sees no
  build context, which is the property the per-medium split was meant to protect.

Open Question 3 is resolved for Phase 1: a failing or blocked probe stops for the
user (fix / waive / stop). A fix goes through the implementer fix loop, and the
executor re-runs the same probes.

## Out of Scope

- ~~Automatic dispatch of the probe reviewer from `feature-implement` (Phase 2).~~
  Moved into Phase 1 in spec_version 2.
- A plugin-shipped agent definition with a structurally restricted tool surface —
  waits on Open Question 1.
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
3. ~~When an assertion fails, does the milestone reopen as a fix loop, or does it
   stop for the user?~~ Resolved in spec_version 2: it stops for the user.
4. Is `none` an honest declaration or an escape hatch? A feature can always claim it.
   Whether design review should challenge a `none` on a feature that visibly renders
   is undecided.

## Dependencies

**Depends on:** nothing shipped. The contract surface additions sit inside existing
documents, and the review dimensions extend existing rubrics.

**Depended on by:** Phase 2 (automatic dispatch) and Phase 3 (the `api` and `data`
siblings) both require Phase 1's schema and reviewer contract.

**Related:** the phase reviewer in `feature-implement` reads a diff package and runs
the project's verification commands. This feature leaves that seam in place, adds a
second gate that reads none of it, and adds one line to the phase reviewer's rubric
(requirement 17).

**External:** a browser automation capability available to the reviewer agent. Phase
1 does not vendor one.

**Shared reference:** `skills/_shared/scratch-isolation.md` holds the scratch
checklist (requirement 16); the probe executor and the phase reviewer both cite it.
