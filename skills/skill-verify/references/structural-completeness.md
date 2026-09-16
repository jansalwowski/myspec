# Structural Completeness

What satisfies each row of the Structural Completeness table in SKILL.md step 7. These are absences, not smells: no regex finds them, so judge each against the skill's own stated purpose. A skill that never mutates anything cannot fail the guardrail row — mark rows N/A rather than forcing a finding.

Ordered by how often each is missing in real skills, worst first.

## Rationalization coverage

**Satisfied by:** an Excuse | Reality table, a red-flag list, or named counter-arguments sitting next to the rule they defend.

**Flag when:** the skill states a rule it expects to hold under pressure — "always write the test first", "never skip the review" — and supplies nothing to defeat the excuse that will be reached for. A bare prohibition loses to a plausible-sounding reason in the moment.

**Not a finding:** rules with no competing incentive ("use forward slashes"). Nobody rationalizes their way out of those.

**Proposed fix shape:**

```markdown
| Excuse | Reality |
|---|---|
| "This change is too small to test" | Small changes are where untested regressions hide |
```

## Gotchas present and surfaced

**Satisfied by:** environment-specific facts that defy reasonable assumptions, stated in SKILL.md itself.

**Flag when:** the skill covers a domain with known traps and states none, or states them only in `references/`. Reference files load on demand, and the agent cannot know to demand a file about a trap it does not know exists. Gotchas are the one category that belongs inline even at token cost.

**Examples:** "this CLI exits 0 on failure", "the config is read before the env var is set", "`cp` is shell-wrapped here and silently no-ops".

## Validation step

**Satisfied by:** an explicit check that the produced artifact is correct — a command to run, a file to diff, a condition to assert.

**Flag when:** the workflow ends at "write the file" with no verification beat. Distinguish from the Verification Checklist section, which is a self-audit of the *process*; this row is about verifying the *output*.

## Guardrails on destructive steps

**Satisfied by:** a stated precondition, a dry-run, or a confirmation before each mutating or irreversible step.

**Flag when:** a step deletes, overwrites, force-pushes, drops, or publishes with no precondition. Severity rises with reversibility: an unguarded `rm -rf` outranks an unguarded file overwrite.

## Human checkpoint

**Satisfied by:** a named point where the user is asked, with the options stated.

**Flag when:** the skill hits a genuinely ambiguous fork or an irreversible action and picks for itself. Do **not** flag skills that correctly avoid asking — a checkpoint on every routine decision is its own defect, and over-asking is a real failure mode. The test is whether a wrong choice is expensive to undo.

## Plan before execute

**Satisfied by:** a step that states the plan, the affected files, or the task list before mutation begins.

**Flag when:** a multi-step mutating workflow starts changing things in step 1. Read-only and single-action skills are N/A.

## Decision tree explicit

**Satisfied by:** a table or numbered conditional keyed to observable predicates.

**Flag when:** branching logic is buried in prose — "if it seems like X you might want to Y". Prose branches get missed; table rows do not. This row and Anti-Pattern #8 overlap: #8 is *no* conditionals at all, this is conditionals in the wrong form.

## Progress tracking

**Satisfied by:** a checklist, a state file, or a numbered task list the agent updates as it goes.

**Flag when:** a long multi-step workflow offers no way to tell what has been done. Applies to workflows that can be interrupted or resumed. A five-step linear skill does not need this; a twenty-step one does.

## Caveats and failure path

**Satisfied by:** a stated response for when a step fails — retry, abort, escalate, ask.

**Flag when:** every step assumes success. Undefined failure paths get improvised, and improvisation at a failure point is where skills do damage. Name the failure mode and the required response.

## Utility script

**Satisfied by:** a file under `scripts/`, with SKILL.md stating whether to **run** it or **read** it.

**Flag when:** the same deterministic logic is described in prose and re-derived on every invocation — parsing, validating, counting, formatting. Code is deterministic; language interpretation is not. Transcripts showing the agent reinventing the same logic each run are the evidence.

**Ambiguity to avoid in the fix:** "Run `scripts/check.py`" and "See `scripts/check.py` for the algorithm" are different instructions. Say which.
