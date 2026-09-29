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

Nothing else selects a case. Changes to `framework-files/`, `scaffolding/`, `hooks/` or `lib/` are left to the full suite, even though the scaffold copies `framework-files/` into every workspace. The exception is an always-loaded rule in `framework-files/rules/`: regenerating the [project instructions](#project-instructions) rewrites every `case.yaml`, which selects every case.

Tag a case with **every** skill its graders name, siblings included. A description change in `code-review` can start stealing `skill-verify`'s prompts, so `nearmiss-skill-verify` carries `skill:code-review` too.

## The cases

| Case | Family | What it proves |
|---|---|---|
| `trigger-new-feature` | trigger | "start a new feature … write the requirements" → feature-spec, spec.md written |
| `route-spec-review` | trigger, near-miss | "before the technical design, check the requirements doc" → feature-spec-review, not tech-spec-review or code-review |
| `trigger-memorize` | trigger | a named fact to keep → memorize, not memorify or session-complete |
| `nearmiss-personal-preference` | near-miss | "remember that I prefer short answers" → auto-memory, not memorize or memorify |
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

`nearmiss-personal-preference` is a `capability` case until it has been run across releases. Two cases started in `capability` and moved to `regression` once a description fix made them fire:
- `trigger-memorize`: Claude Code's built-in auto-memory took "remember this" prompts (0 of 7 runs fired). Once memorize's description claimed project facts over auto-memory, it fired in 10 of 10.
- `code-review-planted-bug`: Sonnet ran `git diff` and reviewed the change itself (0 of 5). Once the code-review description quoted natural review phrasing and said to use the skill instead of reading the diff, it fired in 5 of 5.

## Project instructions

A real myspec project loads its `CLAUDE.md` and the always-loaded rules in `.claude/rules/` (`workflow.md`, `memory-system.md`, `auto-memory-style.md`) into every session, and some routing lives there: `memory-system.md` sends "remember …" to memorize and a new session to bootstrap. The eval harness loads neither. It starts the agent with `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` and `--setting-sources user`, and no case field or setting turns that off. So each case carries its instructions as `execution.append_system_prompt` in `case.yaml`, generated from what its scaffold writes:

```bash
evals/_fixtures/project-instructions.sh            # rewrite the generated block in every case.yaml
evals/_fixtures/project-instructions.sh --check    # exit 1 naming each stale case; the test suite runs this
```

- For each case the script runs `fixture.sh` in a scratch workspace, then renders `CLAUDE.md` and every `.claude/rules/**/*.md` without a `paths:` key, sorted, under the headers Claude Code gives project instructions. The text is the actual scaffolded files, which `myspec_init` copies from `framework-files/`, so it matches what `init` installs.
- The block sits between `# BEGIN project-instructions` and `# END project-instructions` at the end of `case.yaml`. Don't edit it. Put other `execution:` keys in `prompt.md` frontmatter; the script refuses a `case.yaml` with its own `execution:` block.
- **Re-run the script** after adding a case, or after changing a fixture, `_fixtures/lib.sh`, or anything in `framework-files/rules/`. `scripts/tests/eval-project-instructions.test.sh` fails in CI while any block is stale or missing, and checks each block against an independent rendering.
- **Default: on.** Every case scaffolds an initialised project, and every initialised project loads these files, so a score without them describes a setup no user has. A description change is measured with the rules loaded too, because that is what it ships into.
- **Opt out** with the tag `description-only` in `prompt.md`, then re-run the script to drop the block. Use it only for a case that models a project where `init` never ran (plugin installed, no rules), so only skill descriptions and bodies decide. No current case opts out.

Limits: the text goes into the system prompt, while Claude Code puts `CLAUDE.md` in the first user turn. A `paths:` rule, which a real session loads once the agent reads a matching file, never loads here. A canary codeword in `CLAUDE.md` and in the last-sorted rule was quoted back in 3 of 3 Sonnet runs, and absent in 3 of 3 under `description-only`; a codeword in a `paths:` rule stayed absent (2026-09-29).

Mechanisms that don't work on 2.1.284, so nobody retries them: copying the files into the run's user config dir (CLAUDE.md loading is disabled outright); a `SessionStart` hook in that dir's `settings.json` (the harness writes that file itself, exclusively, when Bash is granted, and the run fails with `EEXIST`); `managed-settings.json` there (not read); a helper plugin with the hook listed in `plugins:` (a plugin inside `evals/` must sit inside the case directory, and one outside `evals/` is missing from the older release worktree `release-check.sh` builds).

## Adding a case

1. Create `evals/<case>/` with `case.yaml`, `prompt.md`, `fixture.sh`, `graders/`, and `grader-samples.json` if it has regex graders.
2. Phrase the prompt the way a user types it. Never name the skill.
3. Give it **at least one deterministic grader** (`tool_used`, `regex`, `file_exists`, `tool_order`). An `llm` grader may add to it but never replace it: a judge's verdict varies between runs, and the default Haiku judge voted FAIL three times on a review that plainly passed.
4. Tag it: `skill:<name>` for every skill its graders name, the family (`trigger`, `near-miss`, `planted-flaw`, `artifact-contract`), and `capability`. Add `description-only` only for the opt-out in [Project instructions](#project-instructions).
5. Run `evals/_fixtures/project-instructions.sh <case>` to append the generated project instructions to its `case.yaml`.
6. Prove each grader can fail (next section), then run it a few times before promoting it to `regression`.

```yaml
# evals/<case>/case.yaml — hand-written part; the script appends the generated block
schema_version: "1.1"
name: <case>
context:
  scaffold_script: fixture.sh

# BEGIN project-instructions: generated by evals/_fixtures/project-instructions.sh, do not edit
execution:
  append_system_prompt: |
    Codebase and user instructions are shown below. …
# END project-instructions
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

`evals/_fixtures/lib.sh` provides `myspec_init [name] [description] [stack]`, `add_feature <fixture-dir> <feature> <status> [phase] [priority]`, `register_feature <feature> <status>`, `copy_tree <fixture-dir>` and `git_commit_all <message>`. `project-instructions.sh` beside it generates each case's project instructions from the finished workspace. Shared fixture trees live beside it (`project-billing/`: a Python billing app with three features, a stale manifest and an orphan folder). A fixture used by one case lives in that case's directory (`tech-spec-review-planted-flaws/workspace/`).

## Proving a grader can fail

A grader that cannot fail is worthless, and a case that passes whether or not the plugin did its job measures nothing.

- **Regex graders:** add a `pass` and a `fail` sample to `grader-samples.json`. The fail sample is the plausible wrong answer: the review that maps REQ-004 to a step, the verdict "Approve", the spec with no User Stories heading. `node scripts/evals/check-graders.mjs` (run by `scripts/tests/eval-graders.test.sh`) fails when a grader rejects its pass sample, accepts its fail sample, or has no samples. It also checks every Skill grader against synthetic calls.
- **Against the baseline:** `MYSPEC_EVAL_ABLATION=with-without scripts/evals/run.sh --mode full --runs 1 --models sonnet --case <case>` runs a no-plugin arm next to the plugin arm. Right-skill graders must fail there; planted-flaw and contract graders should fail more often there than with the plugin. If a case scores the same in both arms, the plugin is not what makes it pass.
- **Stability:** run it with `--runs 3` or more before tagging it `regression`. A case that flips between runs is worse than no case.

## Known gotchas

- **Hooks don't load.** The eval sandbox never loads myspec's hooks (the plugin's root `hooks.json` isn't on Claude Code's plugin-hook path, and projects get hooks from `init`). The scaffold therefore installs no `.claude/hooks/` or `.claude/settings.json`. Hook behaviour stays with `hooks/tests/`.
- **Project instructions don't load on their own.** The harness disables `CLAUDE.md` loading and project settings, so a scaffolded `CLAUDE.md` and `.claude/rules/` are invisible (canary, 2026-09-29). Each case gets them through a generated `append_system_prompt` instead; see [Project instructions](#project-instructions). Path-scoped rules are still never loaded.
- **Two-arm mode hides the skill signal.** Under `--ablation with-without`, `tool_used: Skill` graders become unscored "plugin-fired indicators", so a case can score 1.0 while its skill never fired. `run.sh` defaults to `--ablation none`, where they count, and its `FIRED` column reads them either way. Sibling graders carry `arm: both` so they are scored in both modes.
- **Haiku as judge gives false negatives.** The judge is pinned to Sonnet. Prefer a regex for long outputs.
- **Turns.** A run that hits `max_turns` is recorded with an error but still graded on what it produced. Trigger cases set a low cap on purpose: the Skill call happens in the first turns, and the rest of the skill's work costs money without informing the grade.
- **No user.** Runs are non-interactive and `AskUserQuestion` is not granted, so skills that stop for confirmation either stop or carry on. Prompts that need a finished artifact say "don't ask me anything".
- **`--case` takes one glob.** Braces and repeated `--case` flags don't work (the last one wins). That is why `--mode changed` invokes claude once per case.
- **No `---` inside grader frontmatter values.** A `pattern:` containing `---` breaks the frontmatter parser ("Unexpected EOF"); write `-{3}`.
- **Errored runs look like regressions.** A run that ends in an error (offline, proxy down, usage limit, timeout) is still graded, on an empty or truncated transcript, and the suite is not marked partial. Every `max: 0` sibling grader passes there by default. `summary.mjs` therefore drops such runs from SCORE, FIRED and WRONG, shows them in an ERRORS column, and exits 2. The one exception is hitting `max_turns`: trigger cases cap turns on purpose.
- **`auth status` passes offline.** It reads local state only, so `run.sh` also probes the API URL before launching anything; offline, it fails in seconds instead of minutes of retries.
- **Workspace `.claude/skills/` would load.** Keep fixture SKILL.md files outside `.claude/skills/` (`nearmiss-skill-verify` uses `tools/agent-skills/`), or they become project skills in the run.
