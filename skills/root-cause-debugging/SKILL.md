---
name: root-cause-debugging
description: "Use when a bug, test failure, build error, or unexpected behavior needs its root cause found before any fix. Keywords: why is this failing, diagnose, hypothesis test. Do NOT use for feature planning, code review (built-in /code-review), or performance tuning."
---

# Root Cause Debugging

Find the root cause before proposing fixes. Symptom fixes waste time and create new bugs.

## Workflow

4 phases, in order. Phase 1 is a hard prerequisite for proposing any fix — without a traced root cause, fixes are guesses, and stacked guesses produce new bugs in different places.

### Phase 1: Root Cause Investigation

1. **Read error messages completely** — stack traces, line numbers, error codes. They often contain the answer.
2. **Look up past memories** — run `/myspec:memory-lookup` with the error message or symptom. A past session may have traced the same error already.
3. **Reproduce consistently** — exact steps, every time. If not reproducible, gather more data — do not guess.
4. **Check recent changes** — `git diff`, recent commits, new dependencies, config changes.
5. **Gather evidence at component boundaries** (multi-component systems only):

```
For EACH component boundary:
  - Log what enters
  - Log what exits
  - Verify env/config propagation
Run once → analyze WHERE it breaks → investigate THAT component
```

6. **Trace data flow backward** — where does the bad value originate? What called this with the bad value? Keep tracing up until you find the source. Fix at source, not at symptom.

### Phase 2: Pattern Analysis

1. Find working examples of similar code in the codebase
2. Compare working vs broken — list every difference, however small
3. Check dependencies, config, environment assumptions
4. Do not assume "that can't matter"

### Phase 3: Hypothesis & Testing

1. State hypothesis clearly: "X is the root cause because Y"
2. Make the smallest possible change to test it — one variable at a time, so a result is attributable
3. Did it work? → Phase 4. Didn't work? → new hypothesis. Don't stack fixes — you'll lose the ability to isolate which one helped

### Phase 4: Implementation

1. Write a failing test that reproduces the bug
2. Implement a single fix addressing the root cause
3. Verify: test passes, no regressions
4. If the fix doesn't work and it is the first failed fix → return to Phase 1 with new information. The second failed fix → the rule below

## 2-Failed-Fix Escalation Rule

**If the same error remains after 2 different fixes:** stop. Don't attempt fix #3 — repeated failure on the same surface usually means the diagnosis or the architecture is wrong, not that fix #3 will be the one. Run `/myspec:memory-lookup` with the error once more, then ask:

- Is this pattern fundamentally sound?
- Are we persisting through inertia?
- Should we refactor the architecture instead of fixing symptoms?

**Escalate to the user:**
> "I've made {N} attempts without success. What I've tried: [list]. Each fix reveals new issues in different places — this may be an architectural problem. Should we step back and reconsider the approach?"

This is the "Same error" row of "Escalation Triggers" in `${aiDir}/pre-flight.md`, which lists the other triggers.

## Red Flags — return to Phase 1

These thoughts mean Phase 1 isn't done; they justify guessing rather than diagnosing:

- "Quick fix for now, investigate later"
- "Just try changing X and see"
- "Add multiple changes, run tests"
- "It's probably X, let me fix that"
- "I don't fully understand but this might work"
- "One more fix attempt" (after 2+ tries)
- Proposing solutions before tracing data flow
- Each fix reveals a new problem in a different place

## Rationalization Table

| Excuse | Reality |
|--------|---------|
| "Issue is simple, skip the process" | Simple issues have root causes. Process is fast for simple bugs. |
| "Emergency, no time" | Systematic debugging is faster than guess-and-check thrashing. |
| "Just try this first" | First fix sets the pattern. Do it right from the start. |
| "I'll write the test after" | Untested fixes don't stick. Test first proves it. |
| "Multiple fixes at once saves time" | Can't isolate what worked. Causes new bugs. |
| "Reference too long, I'll adapt" | Partial understanding guarantees bugs. Read completely. |
| "I see the problem, let me fix it" | Seeing symptoms ≠ understanding root cause. |
| "One more attempt" (after 2 failures) | 2 failed fixes = stop and ask. Question the pattern. |

## Session Logging Integration

When debugging, log each attempt in the session table:

```
| # | Action | File(s) | Result | Attempt | Type | Note |
```

Increment **Attempt** when repeating same/similar approach. Nothing escalates for you: count the failed fixes yourself and stop at 2.

## Verification Checklist

- [ ] Read error messages completely before acting
- [ ] Reproduced the issue consistently
- [ ] Checked recent changes (`git diff`, `git log`)
- [ ] Traced data flow to root cause (not just symptom)
- [ ] Formed explicit hypothesis before each fix attempt
- [ ] Made one change at a time
- [ ] Wrote failing test before implementing fix
- [ ] All tests pass after fix — run verification commands from `.claude/verification.json`
- [ ] `/myspec:memory-lookup` run with the error before the first fix
- [ ] Escalated to the user after 2 failed fixes, without trying a third
