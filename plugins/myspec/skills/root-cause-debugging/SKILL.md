---
name: root-cause-debugging
description: >
  Use when encountering any bug, test failure, build error, or unexpected behavior.
  Covers: root cause investigation, multi-component diagnostics, hypothesis testing.
  Do NOT use for feature planning, code review, or performance optimization.
---

# Root Cause Debugging

Find the root cause before proposing fixes. Symptom fixes waste time and create new bugs.

## Iron Rule

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

If you haven't completed Phase 1, you cannot propose fixes.

## Workflow

4 phases, in order. Do not skip ahead.

### Phase 1: Root Cause Investigation

1. **Read error messages completely** — stack traces, line numbers, error codes. They often contain the answer.
2. **Reproduce consistently** — exact steps, every time. If not reproducible, gather more data — do not guess.
3. **Check recent changes** — `git diff`, recent commits, new dependencies, config changes.
4. **Gather evidence at component boundaries** (multi-component systems only):

```
For EACH component boundary:
  - Log what enters
  - Log what exits
  - Verify env/config propagation
Run once → analyze WHERE it breaks → investigate THAT component
```

5. **Trace data flow backward** — where does the bad value originate? What called this with the bad value? Keep tracing up until you find the source. Fix at source, not at symptom.

### Phase 2: Pattern Analysis

1. Find working examples of similar code in the codebase
2. Compare working vs broken — list every difference, however small
3. Check dependencies, config, environment assumptions
4. Do not assume "that can't matter"

### Phase 3: Hypothesis & Testing

1. State hypothesis clearly: "X is the root cause because Y"
2. Make the SMALLEST possible change to test it — one variable at a time
3. Did it work? → Phase 4. Didn't work? → new hypothesis. Do NOT stack fixes.

### Phase 4: Implementation

1. Write a failing test that reproduces the bug
2. Implement a single fix addressing the root cause
3. Verify: test passes, no regressions
4. If fix doesn't work and you've tried < 3 fixes → return to Phase 1 with new information

## 3-Attempt Architecture Rule

**If ≥ 3 fixes have failed:**

STOP. Do not attempt fix #4. Instead:

- Is this pattern fundamentally sound?
- Are we persisting through inertia?
- Should we refactor the architecture instead of fixing symptoms?

**Escalate to the user:**
> "I've made {N} attempts without success. What I've tried: [list]. Each fix reveals new issues in different places — this may be an architectural problem. Should we step back and reconsider the approach?"

This aligns with the escalation protocol in the memory-system rule.

## Red Flags — STOP and Return to Phase 1

If you catch yourself thinking any of these:

- "Quick fix for now, investigate later"
- "Just try changing X and see"
- "Add multiple changes, run tests"
- "It's probably X, let me fix that"
- "I don't fully understand but this might work"
- "One more fix attempt" (when already tried 2+)
- Proposing solutions before tracing data flow
- Each fix reveals a new problem in a different place

## Rationalization Table

| Excuse | Reality |
|--------|---------|
| "Issue is simple, skip the process" | Simple issues have root causes. Process is fast for simple bugs. |
| "Emergency, no time" | Systematic debugging is FASTER than guess-and-check thrashing. |
| "Just try this first" | First fix sets the pattern. Do it right from the start. |
| "I'll write the test after" | Untested fixes don't stick. Test first proves it. |
| "Multiple fixes at once saves time" | Can't isolate what worked. Causes new bugs. |
| "Reference too long, I'll adapt" | Partial understanding guarantees bugs. Read completely. |
| "I see the problem, let me fix it" | Seeing symptoms ≠ understanding root cause. |
| "One more attempt" (after 2+ failures) | 3+ failures = architectural problem. Question the pattern. |

## Session Logging Integration

When debugging, log each attempt in the session table:

```
| # | Action | File(s) | Result | Attempt | Type | Note |
```

Increment **Attempt** when repeating same/similar approach. At attempt 3+, the escalation protocol triggers automatically.

## Verification Checklist

- [ ] Read error messages completely before acting
- [ ] Reproduced the issue consistently
- [ ] Checked recent changes (`git diff`, `git log`)
- [ ] Traced data flow to root cause (not just symptom)
- [ ] Formed explicit hypothesis before each fix attempt
- [ ] Made one change at a time
- [ ] Wrote failing test before implementing fix
- [ ] All tests pass after fix — run verification commands from `.claude/verification.json`
- [ ] No more than 3 fix attempts without escalating
