# Completion

Read from SKILL.md Step 5, once every milestone is complete. `<plugin lib>` is the path SKILL.md resolves.

1. Remove the orchestration marker (`"<plugin lib>/session-event.sh" implement stop`) so the Stop hook blocks again, then run the Final Verification section from the plan.
2. Build the full-feature review package: `"<plugin lib>/review-diff.sh" "$BASE_SHA" "$STATE/feature-review.diff"` and dispatch the holistic reviewer (`./holistic-reviewer-prompt.md`) on the `premium` tier with the package path, the Final Verification and required `verification.json` check exit codes, and the plan's Execution Log entries (deferred minors and parked findings to triage, probes, waivers and phase Not proven lines to weigh as evidence, decisions to check across the feature). This pass is mandatory — never skipped, never downgraded to a cheaper tier: it is the only pass that sees the whole feature. Write its report to `${aiDir}/features/{feature}/holistic-review.md` (frontmatter in the prompt file) and commit it with the commit trailers (SKILL.md Step 3): `/myspec:feature-implement-review` reads it and skips what it already covers.
3. Print the completion report. Evidence comes first, so a red or missing check is not buried under the summary. In order: **Evidence** — each Final Verification command and each required `verification.json` check with its exit code, then every `Probe` line (verdict, observed value, artifact path); the holistic verdict with its **Not proven** list; the milestone summary, with any live demo URL; **"Rulings I made"** — every `Ruling:` line from the Execution Log, in the order made, each with its cost-if-wrong; **"Decisions implementers made"** — every `Decision` line, in log order, with any the holistic review called stale marked so; every `Waiver:` line; and the deferred-minors triage outcome. Write "none" for an empty list. The rulings list is exhaustive: if the Execution Log holds a ruling, the report holds it. This report is the only place the decisions taken on the user's behalf reach them.
4. **Ask the user what to do next** via `AskUserQuestion` — do not auto-hand-off:

```
question: "Implementation complete. What next?"
header:   "Next step"
options:
  - "feature-implement-review" → REQ/AC traceability, test trace, scope drift on top of
                                  holistic-review.md; persists conformance-report.md
  - "/code-review"              → Claude Code's built-in bug review of the branch diff
  - "feature-complete"          → skip the reviews; sync docs, archive plan, merge
  - "Stop here"                 → leave the branch as-is; continue later
```

Recommend `feature-implement-review` when the holistic verdict is not READY TO MERGE, any criterion came back ⚠/❌, its Not proven list names a criterion with no test at all or a waived probe (mocked-only coverage alone does not count), a probe was waived, or the plan has 10+ tasks; otherwise `feature-complete`, since the holistic pass already checked every criterion. Execute the choice: invoke `/myspec:feature-implement-review`, the built-in `/code-review` (not a myspec skill; Claude Code only), `/myspec:feature-complete`, or stop and report the branch name. The two review passes are complementary, not exclusive (conformance vs. bugs) — after one finishes, offer this choice again so the user can run the other or proceed.
