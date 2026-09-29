# Behavioural evals

Cases for `claude plugin eval` (Claude Code 2.1.269+). Each case sends a realistic prompt to a fresh, sandboxed Claude session that has only this plugin loaded, then grades what happened: which skill fired, what the final reply says, which files were written. They catch what the bash suites and the skill lint cannot: a skill that no longer triggers on natural phrasing, a sibling that steals its prompts, a review that stops finding a planted flaw, an artifact that drifts from the contract its consumer reads.

Evals run **locally only**, on the maintainer's Claude Code login. There is no CI job and no API key. Every run is a real model call against that login's usage limits.

## Tiers

| When | What runs | Command | Blocks? |
|---|---|---|---|
| pre-commit | static skill lint (no model) | `.githooks/pre-commit` | yes |
| pre-push | cases for the skills changed on the branch, 1 run each, Sonnet | `.githooks/pre-push` → `run.sh --mode changed` | no (report-only) |
| release | every case, 3 runs, two agent models (Sonnet, Haiku), judge Sonnet, compared with the previous release | `scripts/evals/release-check.sh` (RELEASING.md) | report-only; the maintainer decides |

Enable the hooks once per clone with `scripts/install-git-hooks.sh`. That script and `.githooks/pre-commit` come from PR #137 (requires #137). Skip the pre-push evals with `MYSPEC_SKIP_EVALS=1 git push` or `git push --no-verify`. Make a below-threshold result block the push with `MYSPEC_EVALS_STRICT=1`.

The hook prints the case count, a time estimate and the skip hint before it starts. It stops after `MYSPEC_EVAL_DEADLINE_SECONDS` (default 240) and reports what finished. It fails open: if `claude` is missing or logged out, the API is unreachable, the deadline passes, or a run errors, it warns and the push goes ahead, even under strict. Inside Claude Code (`CLAUDECODE` set) it skips the evals and tells the agent to run `scripts/evals/run.sh --mode changed` itself with a long enough Bash timeout, because the agent's default 120 s timeout would kill the push halfway. `MYSPEC_EVALS_IN_AGENT=1` runs them anyway.

Each case also carries a **stability tier** tag:

- `regression`: passed every run so far. A failure is news.
- `capability`: may fail. Either it measures something the plugin does not do reliably yet (the failure is the finding), or it has not been run often enough to trust. A capability case moves to `regression` once it passes reliably across releases.

Tiers are calibrated on Sonnet, the pre-push model. Haiku invokes skills far less often (2 of 15 cases fired in the first full run), so read its column as data about Haiku, not as a regression.

## Running

```bash
scripts/evals/run.sh --mode changed                      # skills changed since the merge base with origin/main
scripts/evals/run.sh --mode changed --base v2.7.0        # ... since a tag
scripts/evals/run.sh --mode full                         # every case, 3 runs, sonnet + haiku
scripts/evals/run.sh --mode full --runs 1 --models sonnet --case 'trigger-*'
MYSPEC_EVALS_DRY_RUN=1 scripts/evals/run.sh --mode changed   # show the selection and the command, spend nothing
```

Results go to `.eval-results/<UTC timestamp>-<mode>-<pid>/<model>/` (gitignored): claude's own `aggregate-result.json` and `report.html`, plus `eval.log`. `--mode changed` runs one `claude plugin eval` invocation per selected case (its `--case` takes a single glob), so there each case has its own `<model>/<case>/` directory. The script ends with a table:

```
CASE                       MODEL   SCORE  FIRED  WRONG  ERRORS  COST   TIME  NOTES
route-spec-review          sonnet  1.00   1/1    0/1    -       $0.14  33s
```

`FIRED` counts runs in which the expected skill was invoked; `WRONG` counts runs in which a sibling that should have stayed quiet was invoked. `ERRORS` counts runs that ended in an error; they are left out of the other columns. `NOTES` names the other failing graders and any run error.

Every run passes `--trust-plugin --scaffold --no-publish --judge-model sonnet --ablation none`, a tool grant (`Write`, `Edit`, and read-only `git` verbs), and a cost ceiling.

| Variable | Default | Effect |
|---|---|---|
| `MYSPEC_EVALS_STRICT` | `0` | `1`: exit 1 when a case scores below the threshold |
| `MYSPEC_EVAL_THRESHOLD` | `0.8` | case score threshold |
| `MYSPEC_EVAL_MAX_COST_USD` | `2` changed / `20` full | cumulative ceiling for the whole call: no invocation starts once it is spent, and each one gets the remainder as `--max-cost-usd`. Runs already in flight can overshoot it by at most `MYSPEC_EVAL_CONCURRENCY` runs |
| `MYSPEC_EVAL_DEADLINE_SECONDS` | none (pre-push: `240`) | stop launching, stop in-flight invocations, report what finished, exit 2 |
| `MYSPEC_EVAL_PROBE_URL` | `$ANTHROPIC_BASE_URL` or `https://api.anthropic.com` | reachability probe run before any case |
| `MYSPEC_EVAL_CONCURRENCY` | `4` | parallel runs |
| `MYSPEC_EVAL_ABLATION` | `none` | `with-without` adds the no-plugin baseline arm and its Δ (doubles the cost) |
| `MYSPEC_EVALS_DRY_RUN` | `0` | `1`: print selection and commands only |

Exit status: `0` ran (report-only), `1` below threshold and strict, `2` infrastructure error (claude missing or logged out, API unreachable, bad `--base`, a case file that failed to load, cost ceiling or deadline hit, or any run that ended in an error other than the `max_turns` cap). An exit 2 says nothing about the plugin; read the eval log it prints.

## Which cases `--mode changed` selects

Files changed between `--base` (default: `git merge-base origin/main HEAD`) and `HEAD`:

| Changed path | Selects |
|---|---|
| `skills/<name>/…` or `plugins/myspec/skills/<name>/…` | every case tagged `skill:<name>` |
| `skills/_shared/<file>` | every case tagged with a skill whose files mention `_shared/<file>`, following `_shared` files that reference each other |
| `evals/<case>/…` | that case |
| `evals/_fixtures/<entry>…` | every case whose files mention `<entry>` (a top-level file or directory name); `lib.sh` is sourced by every case, so it selects them all |

Nothing else selects a case. Changes to `framework-files/`, `scaffolding/`, `hooks/` or `lib/` are left to the full suite, even though the scaffold copies `framework-files/` into every workspace.

Tag a case with **every** skill its graders name, siblings included. A description change in `code-review` can start stealing `skill-verify`'s prompts, so `nearmiss-skill-verify` carries `skill:code-review` too.

## The cases

| Case | Family | What it proves |
|---|---|---|
| `trigger-new-feature` | trigger | "start a new feature … write the requirements" → feature-spec, spec.md written |
| `route-spec-review` | trigger, near-miss | "before the technical design, check the requirements doc" → feature-spec-review, not tech-spec-review or code-review |
| `trigger-memorize` | trigger | a named fact to keep → memorize, not memorify or session-complete |
| `trigger-memorify` | trigger | "anything from this debugging worth keeping?" → memorify |
| `trigger-memory-lookup` | trigger, near-miss | "have we run into this before?" → memory-lookup, not a capture skill |
| `trigger-session-complete` | trigger | "that's it for today, wrap up the session" → session-complete, not memorify |
| `trigger-implement-review` | trigger, near-miss | "does what we built match the spec and plan?" → feature-implement-review, not code-review or feature-verify |
| `nearmiss-skill-verify` | trigger, near-miss | "check my SKILL.md for problems" → skill-verify, not code-review or feature-spec-review |
| `trigger-doctor` | trigger | "health check of our myspec setup" → doctor, not the feature audits |
| `trigger-feature-verify` | trigger | one feature's drift → feature-verify, not feature-status-audit or doctor |
| `trigger-feature-status-audit` | trigger | "does index.yaml match the features folder?" → feature-status-audit |
| `spec-review-planted-flaws` | planted flaw | feature-spec-review fires and flags an untestable AC, a REQ-002/REQ-004 contradiction, and missing error states; does not pass the review |
| `tech-spec-review-planted-flaws` | planted flaw | feature-tech-spec-review flags a requirement with no step (REQ-004) and an ignored shared CSV writer the conventions mandate; reports a Critical and does not pass |
| `code-review-planted-bug` | planted flaw | code-review (Python fixture) finds an off-by-one that drops the first line item and does not approve |
| `feature-spec-contract` | artifact contract | feature-spec writes spec.md with every section and frontmatter key feature-spec-review checks, plus dependencies.md and a manifest entry |

The `capability` case `trigger-memorize` fails for a reason the plugin has not fixed yet: Claude Code's built-in auto-memory takes "remember this" prompts before memorize can. The run still saves the right thing, so only the skill-fired grader fails. `code-review-planted-bug` failed the same way (0/5 on Sonnet: it ran `git diff` and reviewed the change itself) until the code-review description quoted natural review phrasing and said to use the skill instead of reading the diff directly; it then fired 5/5 and moved to `regression`.

## Adding a case

1. Create `evals/<case>/` with `case.yaml`, `prompt.md`, `fixture.sh`, `graders/`, and `grader-samples.json` if it has regex graders.
2. Phrase the prompt the way a user types it. Never name the skill.
3. Give it **at least one deterministic grader** (`tool_used`, `regex`, `file_exists`, `tool_order`). An `llm` grader may add to it but never replace it: a judge's verdict varies between runs, and the default Haiku judge voted FAIL three times on a review that plainly passed.
4. Tag it: `skill:<name>` for every skill its graders name, the family (`trigger`, `near-miss`, `planted-flaw`, `artifact-contract`), and `capability`.
5. Prove each grader can fail (next section), then run it a few times before promoting it to `regression`.

```yaml
# evals/<case>/case.yaml
schema_version: "1.1"
name: <case>
context:
  scaffold_script: fixture.sh
```

```markdown
<!-- evals/<case>/prompt.md -->
---
description: "One sentence: what must happen, and what must not."
tags: [skill:<right-skill>, skill:<sibling>, trigger, capability]
max_turns: 8
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

<the prompt, as a user would type it>
```

```bash
# evals/<case>/fixture.sh — runs as you, outside the sandbox, in the empty workspace
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init                          # .myspec.json, CLAUDE.md binding, ${aiDir} tree, .claude/rules/
add_feature feature-invoice-export-flawed invoice-export draft   # or copy_tree project-billing
git_commit_all "chore: fixture"
```

```markdown
<!-- evals/<case>/graders/right-skill.md -->
---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:myspec:)?<right-skill>"'
---

<!-- evals/<case>/graders/not-<sibling>.md -->
---
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:myspec:)?<sibling>"'
min: 0
max: 0
arm: both
---
```

For `code-review`, `doctor` and `init` write `"myspec:<name>"` without the optional group: Claude Code ships built-in skills with those names, and the bare call is not ours.

`evals/_fixtures/lib.sh` provides `myspec_init [name] [description] [stack]`, `add_feature <fixture-dir> <feature> <status> [phase] [priority]`, `register_feature <feature> <status>`, `copy_tree <fixture-dir>` and `git_commit_all <message>`. Shared fixture trees live beside it (`project-billing/`: a Python billing app with three features, a stale manifest and an orphan folder). A fixture used by one case lives in that case's directory (`tech-spec-review-planted-flaws/workspace/`).

## Proving a grader can fail

A grader that cannot fail is worthless, and a case that passes whether or not the plugin did its job measures nothing.

- **Regex graders:** add a `pass` and a `fail` sample to `grader-samples.json`. The fail sample is the plausible wrong answer: the review that maps REQ-004 to a step, the verdict "Approve", the spec with no User Stories heading. `node scripts/evals/check-graders.mjs` (run by `scripts/tests/eval-graders.test.sh`) fails when a grader rejects its pass sample, accepts its fail sample, or has no samples. It also checks every Skill grader against synthetic calls.
- **Against the baseline:** `MYSPEC_EVAL_ABLATION=with-without scripts/evals/run.sh --mode full --runs 1 --models sonnet --case <case>` runs a no-plugin arm next to the plugin arm. Right-skill graders must fail there; planted-flaw and contract graders should fail more often there than with the plugin. If a case scores the same in both arms, the plugin is not what makes it pass.
- **Stability:** run it with `--runs 3` or more before tagging it `regression`. A case that flips between runs is worse than no case.

## Known gotchas

- **Hooks don't load.** The eval sandbox never loads myspec's hooks (the plugin's root `hooks.json` isn't on Claude Code's plugin-hook path, and projects get hooks from `init`). The scaffold therefore installs no `.claude/hooks/` or `.claude/settings.json`. Hook behaviour stays with `hooks/tests/`.
- **Project instructions don't load either.** The scaffold writes `CLAUDE.md` and `.claude/rules/`, but the run never sees them: a canary rule in both was absent from the model's context (2026-09-29). A routing change in `framework-files/rules/` cannot be measured here; only skill descriptions and bodies can.
- **Two-arm mode hides the skill signal.** Under `--ablation with-without`, `tool_used: Skill` graders become unscored "plugin-fired indicators", so a case can score 1.0 while its skill never fired. `run.sh` defaults to `--ablation none`, where they count, and its `FIRED` column reads them either way. Sibling graders carry `arm: both` so they are scored in both modes.
- **Haiku as judge gives false negatives.** The judge is pinned to Sonnet. Prefer a regex for long outputs.
- **Turns.** A run that hits `max_turns` is recorded with an error but still graded on what it produced. Trigger cases set a low cap on purpose: the Skill call happens in the first turns, and the rest of the skill's work costs money without informing the grade.
- **No user.** Runs are non-interactive and `AskUserQuestion` is not granted, so skills that stop for confirmation either stop or carry on. Prompts that need a finished artifact say "don't ask me anything".
- **`--case` takes one glob.** Braces and repeated `--case` flags don't work (the last one wins). That is why `--mode changed` invokes claude once per case.
- **No `---` inside grader frontmatter values.** A `pattern:` containing `---` breaks the frontmatter parser ("Unexpected EOF"); write `-{3}`.
- **Errored runs look like regressions.** A run that ends in an error (offline, proxy down, usage limit, timeout) is still graded, on an empty or truncated transcript, and the suite is not marked partial. Every `max: 0` sibling grader passes there by default. `summary.mjs` therefore drops such runs from SCORE, FIRED and WRONG, shows them in an ERRORS column, and exits 2. The one exception is hitting `max_turns`: trigger cases cap turns on purpose.
- **`auth status` passes offline.** It reads local state only, so `run.sh` also probes the API URL before launching anything; offline, it fails in seconds instead of minutes of retries.
- **Workspace `.claude/skills/` would load.** Keep fixture SKILL.md files outside `.claude/skills/` (`nearmiss-skill-verify` uses `tools/agent-skills/`), or they become project skills in the run.
