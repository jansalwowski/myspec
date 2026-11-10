# Plan Self-Check

Step 4.6 of `feature-plan`. It runs on every plan, after Spec Coverage and before the plan is saved. Implementers paste plan snippets verbatim and phase reviewers grade the diff against the plan, so a defect the plan mandates passes the implementer and costs a fix loop at phase review. In one two-feature run, about 10 of 11 phase-review findings came from the plan. Each costs a few minutes to fix here.

Read the whole written plan against `spec.md` and `tech-spec.md`, not against your memory of writing it. Fix every finding in the plan itself. A finding the plan cannot fix, such as a spec rule the tech-spec never designed for, is a tech-spec defect: say so and stop.

## The four checks

| # | Check | A finding |
|---|-------|-----------|
| 1 | **Snippets vs spec contract.** Compare every code and test snippet with the Spec contract quotes and Global Constraints its task carries. | The snippet enforces a narrower rule than the quote, such as one variant where the spec says "any". It adds a case or misses one. An update path validates less than the create path the same rule covers. A memo or cache is keyed on less than its result depends on, so it goes stale when an input changes. An eager reference or import-time side effect breaks existing tests' mocks. |
| 2 | **Steps agree.** Within each task, compare the test step with the implementation step. Then compare each task with the later tasks that touch the same behavior. | Step 1 asserts something Step 3 contradicts, for example a test that expects "no clip-path" while the implementation adds one. A later task's snippet undoes or contradicts an earlier task's. |
| 3 | **Reader-visible strings.** Check every string the plan dictates that reaches a person: UI text, labels, attribution, messages, emails, exported headers. | An internal ID, a `TODO`, a `FIXME` or an open-question reference reaches rendered output. Placeholder text. Two strings shown together that repeat the same sentence. A string the spec does not supply that the plan made up: take the spec's wording, or name the string in Step 6 for the user to supply. |
| 4 | **Probe lint.** Check every `**Checkpoint probes:**` line. Skip this check when the plan has no probes. | The target cannot do the action at that milestone, for example zooming a page that renders without zoom, or calling an endpoint a later milestone adds. A probe's expected value contradicts what the tasks build. A probe reads state that an earlier probe in the block wrote, hid or deleted, and does not say so. |

## Probe order

The executor runs a milestone's probes in plan order, in one session (`feature-implement` Step 4b). A probe may depend on an earlier one; don't remove the dependency just to make the probes independent. Declare it on the probe line instead, `P8 [visual] (after P7: layer B hidden): …`, so a reader and the executor know the starting state. A dependency only counts as a finding when it is left undeclared. When reordering costs nothing, put a probe that needs pristine state before the probes that change it.

## Before presenting

Walk this after the four checks, against the written plan. Each line restates a rule from SKILL.md; fix the plan where one fails.

- [ ] `## Spec Coverage` holds one row per spec.md requirement ID, per spec.md acceptance criterion, and per tech-spec.md implementation step, each mapped to task IDs and the test that proves it, or explicitly `DEFERRED` with a reason (Step 4.5)
- [ ] Header `spec` / `tech_spec` keys point at the feature's `spec.md` and `tech-spec.md`; `planned_against` holds HEAD's SHA after the Step 1 sync; `auto_parallel_phases: true` is set
- [ ] `## Global Constraints` holds every project-wide exact (versions, limits, naming, invariants) verbatim with source refs; no task text re-derives one
- [ ] Task boundaries are right-sized — each task independently rejectable by a reviewer; trivial same-shape changes batched into one task
- [ ] Every task has exact file paths matching tech-spec file inventory
- [ ] Every task has TDD steps and a `**Verify at phase review:**` command scoped to the task's own tests
- [ ] Every algorithm or relied-on library call has a `**Prototype:**` line from a scratch run
- [ ] If Test Hooks names *Real inputs*: the derivation's core ran on that corpus and the plan quotes the result, or the first task is a spike on it
- [ ] Parallel groups have zero file overlap (check file lists)
- [ ] Barriers exist after every parallel group
- [ ] Consecutive small sequential tasks share a phase; a new phase starts only after a task publishing a contract later tasks are written against
- [ ] Execution order table matches task dependencies
- [ ] Every `DEFERRED` row was surfaced to the user in Step 6, not decided unilaterally
- [ ] Every task has a populated **Spec contract** block with verbatim quotes (not paraphrased) from spec.md / tech-spec.md
- [ ] Every task whose Files contain `Modify:` has a populated **Touch only** line
- [ ] Every task has an Interfaces block (Consumes/Produces, exact signatures); names and types match verbatim between producer and consumer tasks
- [ ] Walked in execution order, every Consumes item matches an earlier task's Produces as written, and no task in between removed or renamed it (a retired field, symbol, or config key a later task still relies on)
- [ ] Every signature-, field-, enum-, symbol-, or directory-changing Produces item has its grepped callers and consumers in that task's Files/Touch only or a barrier step, including tests and fixtures that use a newly added entity or value as the absent example
- [ ] Within each milestone, lower-level layers (data, services) precede higher-level layers (UI, presentation) per project conventions
- [ ] Phase numbers are globally unique across all milestones
- [ ] Cross-milestone dependencies use `Milestone N` in the Depends On column (not individual phase numbers from other milestones)
- [ ] Each milestone is a coherent vertical slice
- [ ] If tech-spec.md sets `verification_mode` (not `none`): every milestone has a `**Checkpoint probes:**` block of literal probes with expected values, referencing only `### Test Hooks` handles; a `[real-input]` probe on every milestone touching a named real corpus; a *Scratch environment* line in Test Hooks whenever any probe writes
- [ ] `## Plan Self-Check` records the four Step 4.6 checks, each clean or naming its fixes; every probe that depends on an earlier probe declares it
- [ ] Commit decision presented to user (Step 7); plan committed before handoff

## Recording the result

Add `## Plan Self-Check` as the last section of the plan, with one line per check. Each line says `clean`, or names each fix in a few words (task, step, what changed). Probe lint says `not applicable` when the plan has no probes. The plan shows the user what was caught and changed before they approve it. `feature-implement` does not read this section and does not require it, so a plan written without one runs as before.

```markdown
## Plan Self-Check

- Snippets vs spec contract: 1 fixed — T3 Step 2 validated only `chevron`; spec §2.4 says any non-solid pattern
- Steps agree: clean
- Reader-visible strings: 1 fixed — T5 attribution text carried `TODO(OQ15)`; replaced with the spec's source label
- Probe lint: P8 declared `(after P7: layer B hidden)`; P12's expected value now matches T7 Step 3's clipPath
```
