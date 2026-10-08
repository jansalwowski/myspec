# Releasing myspec

> The repo-local `/release` skill (`.claude/skills/release/` — maintainer tooling, not shipped with the plugin) automates this entire process: preflight, semver suggestion, bump, tag, notes. This document stays the authoritative reference; if the skill and this file disagree, this file wins.

## Why the version is in three places

myspec ships through two plugin manifests (Claude marketplace, Claude plugin) and is consumed by projects that read a third (`framework-files/manifest.json`). All three must agree, or one of three things breaks:

| If this is stale                          | Symptom                                                                                              |
|-------------------------------------------|------------------------------------------------------------------------------------------------------|
| `framework-files/manifest.json`           | `/myspec:update` reports "Already up to date" and ships nothing — even though new files exist        |
| `.claude-plugin/plugin.json`              | Claude reports the wrong version after `/plugin install`                                              |
| `.claude-plugin/marketplace.json`         | Claude pins to a stale git ref; users get an old snapshot                                            |

## The bump script

`scripts/bump-version.sh` updates all three in one shot. Requires `jq`.

```bash
./scripts/bump-version.sh 1.7.0
```

It:

1. Validates the X.Y.Z format
2. Warns if the working tree has uncommitted changes
3. Rewrites the three JSON files (`jq` reformats them as a side effect — consistent indentation)
4. Prints next-step commands
5. Does **not** commit, tag, or push — review the diff first

## Release workflow

1. Land all changes for the release on `main`
2. Run the eval comparison (next section): `scripts/evals/release-check.sh --version X.Y.Z`. Read the report; a Sonnet regression exits 1 and stops the release (the gate; a Haiku-only regression is a report-only warning), and on a failed run decide whether to retry or skip. Only on a go, record it and commit it on its own, before the bump, so the bump diff stays version files only:
   `scripts/evals/release-check.sh --record <the out dir it printed>`, then `git add quality && git commit -m "chore(quality): record vX.Y.Z eval baseline"`
3. From a clean working tree: `./scripts/bump-version.sh X.Y.Z`
4. `git diff` — review the version bumps
5. `git add -A && git commit -m "chore: bump to vX.Y.Z"`
6. **Write the release notes now**, before the tag exists — see step 9 for why. Draft from the PRs since the previous tag, and include an **Upgrading** section whenever anything under `framework-files/`, `hooks/`, or `lib/` changed.
7. `git tag vX.Y.Z`
8. `git push && git push --tags`
9. Pushing the tag **auto-publishes the GitHub release** — `.github/workflows/release.yml` runs `gh release create "$TAG" --title "$TAG" --generate-notes`, with no `--draft`. The release is public within about a minute of the tag landing, titled with the bare tag and carrying nothing but a list of PR titles.

   **So have the notes written before you push the tag.** Between the push and your edit there is a live release that says nothing useful; for a patch that is noise, and for a major it is the version most people will read on the day.

   Enrich it with `gh release edit`, not `create` — the release already exists, so `gh release create` fails with HTTP 422:

   ```bash
   gh release view vX.Y.Z --json body --jq .body > /tmp/generated.md   # the PR links
   cat notes.md /tmp/generated.md > /tmp/final.md                      # yours first, links last
   gh release edit vX.Y.Z --title "vX.Y.Z — short theme" --notes-file /tmp/final.md
   ```

   Keep the generated "What's Changed" and "Full Changelog" lines at the bottom — they are the only per-PR attribution the release carries. If no release object exists after ~30s the workflow failed: check its run, then `gh release create vX.Y.Z --notes-file /tmp/final.md` by hand.

   To close the live window instead of racing it, add `--draft` to the workflow's `gh release create` and publish with `gh release edit --draft=false` once the notes are in. That trades a public gap for a release that does not exist until someone finishes it.

## Eval comparison

`scripts/evals/release-check.sh --version X.Y.Z` answers "did this release make the plugin worse than the last one?" It runs locally on the maintainer's Claude Code login (see `evals/README.md`); there is no CI job.

1. Runs the release suite on HEAD with a Sonnet judge (`run.sh --mode full`, evals/README.md "Tiers"):
   - Sonnet runs every case: 3 runs of each `regression` case, 1 of each `capability` case (`runs: 1` in its `prompt.md`).
   - Haiku runs only the routing cases, those tagged `trigger` or `near-miss` (`"modelTags"` in `quality/release-check.json`), with the same run counts. It is report-only, and the planted-flaw, artifact-contract and orchestration cases say little about a model that rarely fires the skill.
   - `--runs N` runs every case N times instead.
2. Resolves each model alias to the model id it maps to today, with one tiny `claude -p` call per model (about $0.03 in total). An id that cannot be resolved is stored with the reason, never as null. It also hashes the workspace each case's fixture builds (`workspaces.mjs`, no model call), for the next release's fixture check.
3. Gets the previous release's scores from `quality/baselines/v<prev>.json` where they still hold. Otherwise it re-runs the previous tag in a temporary `git worktree` with HEAD's `evals/` copied in (same cases, same run counts, same `modelTags`, old plugin). The worktree is removed, and a running eval killed, on every exit path.
   - **Whole suite** when the file is missing or the Claude Code major.minor version differs. A patch release reuses the baseline; `--cc-match exact` re-runs on any version change. Measured before relaxing it: a CLI patch (2.1.284 → 2.1.292) made v2.9.0 through v3.0.0 re-run their previous tag, which gives six paired re-runs of v2.8.0–v2.12.0. Across those re-runs, the same plugin on the new patch moved 0 of 110 Sonnet case pairs and 0 of 110 Haiku pairs by 0.34 or more (mean change −0.004 and −0.008), so none would have changed a verdict. Each re-run doubled the release's cost. The baseline is re-recorded every release, so a reused baseline is at most one release behind the CLI.
   - **One model** when its resolved id differs, or is unresolved now or in the baseline.
   - **One case** when its inputs changed or it is new. The baseline stores, per case, a hash of `evals/<case>/` with `case.yaml`'s generated project-instructions block left out. A baseline recorded before #310 has only whole-directory hashes, and those are compared instead.
   - **After an `evals/_fixtures/` change**, one case when the workspace its fixture builds changed. The check builds every case's workspace from the previous tag's plugin with HEAD's fixtures and compares its hash with the stored one. The hash covers every file, the branch and the tree and subject of each commit, with commit ids masked. A comment-only edit to `lib.sh`, or a helper no case's output depends on, re-runs nothing. A baseline without workspace hashes (before #310) still re-runs the whole suite.
4. Compares the two case by case (`scripts/evals/compare.mjs`) and prints the report. It covers:
   - the mean paired score delta, with a paired-bootstrap 95% CI (seeded, 10,000 resamples)
   - a sign test
   - pass@k and pass^k (k is the run count of the paired regression cases)
   - flaky cases
   - cases present in only one set (listed, left out of the statistics)
5. Stages `quality/baselines/vX.Y.Z.json`, the re-run previous baseline (if any) and a trend line in `<out>/staged/`. **Nothing touches `quality/` yet.** The baseline holds per-case run scores, model ids, the Claude Code version, case and inputs hashes, tiers, fixture workspace hashes, cost and duration.
6. After a go decision, `release-check.sh --record <out>` copies the staged files into `quality/`. It refuses a `--case` run.

**Verdict**, per model, over the paired `regression` cases. `capability` cases (the new side's tiers, stored in the baseline) are listed with their scores and any drop as a report-only warning, and stay out of every number below.

A case **regressed** when either:

- it passed every run in the baseline and now passes none, or
- its mean score fell by at least 0.67.

The model verdict is then:

- `regressed`: at least 2 cases regressed, or the CI lies entirely below 0 **and** the sign test gives p ≤ 0.05.
  - A CI whose upper bound is exactly 0 does not count as below 0. That happens when every case that moved went down and the rest tied, and the per-case rule covers those drops.
- `insufficient-data`: fewer than 5 paired cases. There is no verdict, and it never exits 1.
- `improved`: the CI lies entirely above 0 and no case regressed.
- `no-change`: anything else. A single regressed case prints as a warning.

The release verdict is the worst model's.

**Calibration**, the evidence needed before `"gate": true`. `node scripts/evals/calibrate.mjs --trials 1500` runs a seeded Monte Carlo over 15 cases with 3 runs each. `scripts/tests/eval-compare.test.sh` asserts these bounds (1000 trials).

| Scenario | "regressed" rate | Bound in the test |
|---|---|---|
| Sonnet-like A/A (12 stable, 1 flaky, 2 capability cases) | 0.0% | ≤ 5% |
| Sonnet-like A/A with 3 flaky cases | 0.0% | ≤ 5% |
| Haiku-like A/A (graders 0.55–0.95) | 2.0% | ≤ 5% |
| Haiku-like A/A (graders 0.45–0.80) | 1.7% | ≤ 5% |
| Sonnet, 1 stable case broken | 0.3% | reported as a warning |
| Sonnet, 2 stable cases broken | 91.3% | ≥ 80% |
| Sonnet, 3 stable cases broken | 99.5% | ≥ 95% |
| Haiku, 2 cases broken | 36.8% | ≥ 25% |
| Haiku, 3 cases broken | 55.7% | ≥ 40% |

"Broken" means the case fails one grader on every run, the way a skill that stopped triggering would. The previous rule (a CI below 0, or pass^3 dropping by more than 0.10) cried regression in 8–17% of A/A trials per model. Haiku's cases are too noisy to catch one or two broken cases reliably, so the gate (below) does not block on a Haiku `regressed`, and a Haiku pass is only a signal. These rates were checked against five recorded releases before the gate went on (2.8.0–2.11.0 in `quality/trend.jsonl`: one `improved`, four `no-change`, no false regression).

**Reused results and pairing.** Two of the rules above keep stored results where an earlier version re-ran the case (#310):

- A regenerated project-instructions block alone, which every `framework-files/rules/` edit causes in all 25 cases. The stored result ran the previous plugin with its own rule text; HEAD runs with the new text. That compares the two releases as shipped, but the rule change and the plugin change are no longer told apart, and a re-run case still sees HEAD's rules on both sides (evals/README.md, "Project instructions").
- A `_fixtures/` change whose workspaces hash the same. The stored result ran on an identical workspace, so only the session differs, as with any reuse. The hash sees files and git history, not the environment a fixture ran in.

**Cost** (2026-10, Claude Code 2.1.292, from the v3.0.0 per-case costs; 25 cases: 15 `regression`, 10 `capability`, 17 of them routing):

| Side | Before #310 | Now |
|---|---|---|
| Sonnet | 25 cases × 3 runs: $14.69 | 15 × 3 ($6.53) + 10 × 1 ($8.16 / 3 = $2.72): about $9.3 |
| Haiku | 25 cases × 3 runs: $5.01 | 12 routing `regression` × 3 ($1.89) + 5 routing `capability` × 1 ($0.93 / 3 = $0.31): about $2.2 |
| HEAD | $19.70 | about $11.5, about 13 minutes |
| Previous tag, whole suite (any Claude Code version change) | $20.74 | about $12 |
| Previous tag, reused (same Claude Code; changed cases only) | $0 plus each changed case | the same |

So a release check costs about $11.5 with a reusable baseline and about $23.5 when the Claude Code version moved, against $40.44 for 3.0.0. Both fit `run.sh`'s $20 ceiling per side. Claude Code ships often, so the whole-suite re-run is the usual case. `--head-results <dir>` reuses a finished HEAD run on a retry.

**Skip.** `release-check.sh --version X.Y.Z --skip "<reason>"` runs nothing and records `{"version", "date", "skipped": "<reason>"}` in `quality/trend.jsonl`. Commit it the same way.

**Abort.** Before `--record`, nothing needs undoing. After `--record`, `git checkout -- quality && git clean -fd quality` restores it. After the `chore(quality)` commit, the commit is local and ahead of `origin/main`:

1. Confirm it is the only commit ahead: `git log --oneline origin/main..HEAD`.
2. Drop it: `git reset --hard origin/main`.

`git pull` still reports "Already up to date" while main is ahead, so the release preflight also checks `git status -sb` for `ahead`.

**Exit status:**

- 0: done. The run was report-only, not regressed, insufficient-data, or a `--case` run.
- 1: a model in `gateModels` regressed with the gate on.
- 2: infrastructure error: usage limit, logged out, eval run failed, or interrupted; or a `gateModels` list that would gate nothing (below). An exit 2 says nothing about the plugin.

**The gate.** `quality/release-check.json` sets `"gate": true` (#267): a `regressed` release verdict exits 1 and `/release` aborts; the maintainer no longer decides. It was report-only until five recorded releases (2.8.0–2.11.0 in `quality/trend.jsonl`) showed no false regression against the calibration above. It blocks only on the models `"gateModels"` lists, `["sonnet"]` (maintainer decision, 2026-10-05): the suite still runs and reports both models and the baseline records both, but a Haiku-only `regressed` prints a report-only warning and exits 0. A Haiku verdict says too little to block a release on: its pass catches 2 broken cases only 37% of the time, so read its column as a signal. With no `gateModels` key every model that ran gates. With the gate on, a `gateModels` list that would gate nothing exits 2 instead of passing: an empty list, or an entry (matched exactly, so `Sonnet` is not `sonnet`) that `--models` does not run, checked before any eval, or that the comparison does not hold, checked after it. A `--case` run, `insufficient-data`, and an exit 2 never block. The same file holds `seed`, `resamples` and `modelTags` (a model mapped to the tags a case needs one of for that model to run it; `haiku: [trigger, near-miss]`, #310); `"gate": false` returns the check to report-only.

**A release that renames or folds skills** compares only partially, by construction: the baseline keys cases by name and stores a content hash per case, and selection uses `skill:<name>` tags, so every case whose directory or tags changed with the rename re-runs on the previous tag against HEAD's `evals/` (an old plugin without the new skill), and cases present in only one set are listed and left out of the statistics. Read such a report for the unchanged cases only, and expect `insufficient-data` on a large rename. The release records itself as the new baseline (`--record` as usual), and its notes say so, so the next release compares against a complete one.

## Versioning rules (semver)

| Bump  | When                                                                                              |
|-------|---------------------------------------------------------------------------------------------------|
| Patch | Bug fixes in skill bodies. No new files, no manifest changes, no `.myspec.json` schema changes.   |
| Minor | New skills, new framework files, new manifest entries. Backward-compatible.                       |
| Major | Anything under "Breaking changes" below: `.myspec.json` schema, removed/renamed skills, hook and state contracts, a raised host floor, workflows requiring migration. |

## Breaking changes

A change is breaking when a consumer project that runs `/myspec:update` ends up broken or silently different, and nothing in the release fixes it for them. It is not breaking when it ships with its own migration: a manifest rename carrying `renamedFrom`, or a removal listed in the manifest `removed` block, is a minor change.

Breaking, unless a migration ships with it:

- A `.myspec.json` schema change `update` does not migrate
- A removed or renamed skill, or a renamed agent dispatch name (`myspec:<agent>`)
- A renamed or removed config-contract heading (see AGENTS.md, "Config contracts")
- A changed or dropped manifest key without `renamedFrom` or a `removed` entry
- A dropped harness (Codex in 3.0, #143) or a dropped supported stack
- A workflow change that needs consumers to act, such as a new required plan field that old plans lack and a skill now rejects
- A changed hook contract: the JSON a hook reads or returns, or a renamed, removed or repurposed exported variable (`MYSPEC_SESSION_FILES`, `MYSPEC_BASE_REF`, `MYSPEC_CHECK_RUN_ID`, `MYSPEC_CHECK_WORKDIR`; the `env` section of `lib/myspec-config.schema.json`). Consumers' checks, cleanups and install steps read them. A new variable is minor.
- A changed session-state file format (`.claude/state/sessions/<sid>.jsonl`, the event types and fields `lib/session-event.sh` documents): a renamed, dropped or retyped event or field. A new event or field is minor, as is a one-minor import of the old store (`docs/stop-gate.md`).
- A renamed, dropped or retyped `verification.json` key (`checks[].paths`, `checks[].runIn`, `checks[].cleanup`, `checks[].diffCommand`, `containers`; the `verification.*` entries of the schema). A new optional key is minor (`cleanup`, `docs/verify-check-escapes.md`).
- A changed `.claude/state/` layout (AGENTS.md, "Config contracts"): a moved or renamed `sessions/<sid>.md`, `sessions/<sid>.jsonl` or `memory-ids.json`, which the hooks of a session open across the upgrade still write at the old path.
- A changed framework-file marker (`<!-- myspec:framework-start -->`/`-end`, `<!-- BEGIN myspec:paths -->`/`END`) or a moved `${aiDir}` directory (`features/`, `memory/`, `ideas/`). The 2.0 move of live session logs out of `${aiDir}/memory/sessions/active/` was major for this reason (`docs/upgrading-to-2.0.md`).
- A raised host floor: the minimum Claude Code or git version the plugin runs on, as README.md states it. Declaring a floor where none was stated is not breaking; raising one is.
- A changed always-loaded rule file (`framework-files/rules/` without `paths:`) when a consumer's pin of it would then do the opposite of what it was set for: the 2.0 trim shrank four rules "for the always-loaded context budget", the reason consumers had pinned them, and `update` never writes over a pin, so the pinned copy was now the larger one (`docs/myspec-2.0-breaking-changes.md`, change 4). A new always-loaded rule file is minor; a rewording that leaves routing and size alone is a patch.

**Retirement stubs.** A removed or renamed skill leaves a stub at the old name (`skills/<old>/SKILL.md` with `disable-model-invocation: true`, "Retired in myspec X.Y" in its description and a "Remove this stub" rule) that names the replacement and stops; plugins have no alias mechanism. A stub ships for one minor cycle after the release that retired it and is deleted in the next: retired in X.Y, it ships through X.(Y+1).*, and X.(Y+2).0 ships without it. `scripts/overdue-stubs.sh --version <X.Y.Z>` lists every stub as `shipping`, `due` or `overdue` against that version and exits 1 while one is overdue; `/release` runs it as its stub gate (Step 2, beside the breaking gate), against the last tag with the minor bumped, and refuses a minor while any is overdue. A patch is never refused for a stub, so a maintenance branch can ship fixes while a stub waits for the next major. The 2.0 stubs shipped for eleven minors because nothing checked (#267).

**Tracking.** Every candidate gets an issue with the `breaking` label, in the next major's milestone (currently [v3.0.0](https://github.com/jansalwowski/myspec/milestone/1)). That milestone is the major's roadmap; do not keep one anywhere else. A PR that lands a breaking change carries the `breaking` label too, which is what the release gate reads.

**Gate.** `/release` lists merged PRs carrying `breaking` since the last tag and refuses a minor or patch bump while any exist. Only PRs whose merge commit is an ancestor of HEAD count: once a major's integration branch exists, a breaking PR merged there is listed by `gh pr list` while a 2.x patch is cut from `main`, and is ignored as "merged elsewhere". Those PRs are either released in the major or have the label removed with a comment saying why they are not breaking.

**Upgrade base.** A major upgrades only from the last minor of the previous major: 2.0 from 1.28, 3.0 from 2.12. `update` refuses an older `frameworkVersion` and tells the user to run that minor's `update` first (check out its tag, start Claude with `--plugin-dir` at the checkout, run `/myspec:update`, return). Every consumer therefore reaches the major with the previous line's migrations, renames and removals already applied, so the major deletes each one-shot migration, `renamedFrom` and `removed` entry the floor minor already carried. Keep only what the floor minor itself still needs on its first major `update`. The manifest's `upgradeFrom` holds the floor and is set by hand when the major is cut; `lib/tests/manifest-regression.test.sh` fails on a migration or `removed` entry dated at or below it. When cutting the major, move the old `upgradeFrom` onto the end of `upgradeChain` (the earlier majors' floors, oldest first): `lib/upgrade-route.mjs` reads both so the refusal names every release a project must update through, not just the next one.

**Cutting the major.** Write `docs/myspec-<N>.0-breaking-changes.md` and `docs/upgrading-to-<N>.0.md` from the milestone, as `docs/myspec-2.0-breaking-changes.md` and `docs/upgrading-to-2.0.md` were for 2.0.

## When in doubt

The single most consequential field is `frameworkVersion` in `framework-files/manifest.json` — that's what gates whether existing consumer projects see new framework files via `/myspec:update`. If you touched anything under `framework-files/`, the version must bump (minor at minimum), and the script must run.
