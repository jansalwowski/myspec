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

## Recording the result

Add `## Plan Self-Check` as the last section of the plan, with one line per check. Each line says `clean`, or names each fix in a few words (task, step, what changed). Probe lint says `not applicable` when the plan has no probes. The plan shows the user what was caught and changed before they approve it. `feature-implement` does not read this section and does not require it, so a plan written without one runs as before.

```markdown
## Plan Self-Check

- Snippets vs spec contract: 1 fixed — T3 Step 2 validated only `chevron`; spec §2.4 says any non-solid pattern
- Steps agree: clean
- Reader-visible strings: 1 fixed — T5 attribution text carried `TODO(OQ15)`; replaced with the spec's source label
- Probe lint: P8 declared `(after P7: layer B hidden)`; P12's expected value now matches T7 Step 3's clipPath
```
