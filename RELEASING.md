# Releasing myspec

> The repo-local `/release` skill (`.claude/skills/release/` — maintainer tooling, not shipped with the plugin) automates this entire process: preflight, semver suggestion, bump, tag, notes. This document stays the authoritative reference; if the skill and this file disagree, this file wins.

## Why the version is in five places

myspec ships through three plugin manifests (Claude marketplace, Claude plugin, Codex plugin) and is consumed by projects that read a fourth (`framework-files/manifest.json`). Plus a local-source wrapper used by the Codex agents marketplace. All five must agree, or one of three things breaks:

| If this is stale                          | Symptom                                                                                              |
|-------------------------------------------|------------------------------------------------------------------------------------------------------|
| `framework-files/manifest.json`           | `/myspec:update` reports "Already up to date" and ships nothing — even though new files exist        |
| `.claude-plugin/plugin.json`              | Claude reports the wrong version after `/plugin install`                                              |
| `.claude-plugin/marketplace.json`         | Claude pins to a stale git ref; users get an old snapshot                                            |
| `.codex-plugin/plugin.json`               | Codex shows the wrong version                                                                        |
| `plugins/myspec/.codex-plugin/plugin.json`| Local-source install (Codex marketplace pointing at `./plugins/myspec`) shows the wrong version      |

## The bump script

`scripts/bump-version.sh` updates all five in one shot. Requires `jq`.

```bash
./scripts/bump-version.sh 1.7.0
```

It:

1. Validates the X.Y.Z format
2. Warns if the working tree has uncommitted changes
3. Rewrites the five JSON files (`jq` reformats them as a side effect — consistent indentation)
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

1. Runs the full eval suite on HEAD: every case, 3 runs, Sonnet and Haiku agents, Sonnet judge (`run.sh --mode full`).
2. Resolves each model alias to the model id it maps to today, with one tiny `claude -p` call per model (about $0.03 in total). An id that cannot be resolved is stored with the reason, never as null.
3. Gets the previous release's scores from `quality/baselines/v<prev>.json` where they still hold. Otherwise it re-runs the previous tag in a temporary `git worktree` with HEAD's `evals/` copied in (same cases, old plugin). The worktree is removed, and a running eval killed, on every exit path.
   - **Whole suite** when the file is missing, `evals/_fixtures/` changed, or the Claude Code version differs. Any version change counts, because patch releases change skill triggering; `--cc-match minor` relaxes this to major.minor.
   - **One model** when its resolved id differs, or is unresolved now or in the baseline.
   - **One case** when its `evals/<case>/` directory changed or is new (the baseline stores a content hash per case).
4. Compares the two case by case (`scripts/evals/compare.mjs`) and prints the report. It covers:
   - the mean paired score delta, with a paired-bootstrap 95% CI (seeded, 10,000 resamples)
   - a sign test
   - pass@k and pass^k
   - flaky cases
   - cases present in only one set (listed, left out of the statistics)
5. Stages `quality/baselines/vX.Y.Z.json`, the re-run previous baseline (if any) and a trend line in `<out>/staged/`. **Nothing touches `quality/` yet.** The baseline holds per-case run scores, model ids, the Claude Code version, case hashes, cost and duration.
6. After a go decision, `release-check.sh --record <out>` copies the staged files into `quality/`. It refuses a `--case` run.

**Verdict**, per model. A case **regressed** when either:

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

**Cost.** HEAD's full run costs about $8 and takes about 7 minutes (Sonnet ≈ $5.8 and Haiku ≈ $2.0 at 3 runs; at 1 run the Sonnet suite measured $1.94 and 109 s). A whole-suite re-run of the previous tag doubles that. A changed case adds only that case's cost. The first release after this lands has no stored baseline, so it pays the double once. `--head-results <dir>` reuses a finished HEAD run on a retry.

**Skip.** `release-check.sh --version X.Y.Z --skip "<reason>"` runs nothing and records `{"version", "date", "skipped": "<reason>"}` in `quality/trend.jsonl`. Commit it the same way.

**Abort.** Before `--record`, nothing needs undoing. After `--record`, `git checkout -- quality && git clean -fd quality` restores it. After the `chore(quality)` commit, the commit is local and ahead of `origin/main`:

1. Confirm it is the only commit ahead: `git log --oneline origin/main..HEAD`.
2. Drop it: `git reset --hard origin/main`.

`git pull` still reports "Already up to date" while main is ahead, so the release preflight also checks `git status -sb` for `ahead`.

**Exit status:**

- 0: done. The run was report-only, not regressed, insufficient-data, or a `--case` run.
- 1: a model in `gateModels` regressed with the gate on.
- 2: infrastructure error: usage limit, logged out, eval run failed, or interrupted; or a `gateModels` list that would gate nothing (below). An exit 2 says nothing about the plugin.

**The gate.** `quality/release-check.json` sets `"gate": true` (#267): a `regressed` release verdict exits 1 and `/release` aborts; the maintainer no longer decides. It was report-only until five recorded releases (2.8.0–2.11.0 in `quality/trend.jsonl`) showed no false regression against the calibration above. It blocks only on the models `"gateModels"` lists, `["sonnet"]` (maintainer decision, 2026-10-05): the suite still runs and reports both models and the baseline records both, but a Haiku-only `regressed` prints a report-only warning and exits 0. A Haiku verdict says too little to block a release on: its pass catches 2 broken cases only 37% of the time, so read its column as a signal. With no `gateModels` key every model that ran gates. With the gate on, a `gateModels` list that would gate nothing exits 2 instead of passing: an empty list, or an entry (matched exactly, so `Sonnet` is not `sonnet`) that `--models` does not run, checked before any eval, or that the comparison does not hold, checked after it. A `--case` run, `insufficient-data`, and an exit 2 never block. The same file holds `seed` and `resamples`; `"gate": false` returns the check to report-only.

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
- A dropped harness (Codex, #143) or a dropped supported stack
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

**Cutting the major.** Write `docs/myspec-<N>.0-breaking-changes.md` and `docs/upgrading-to-<N>.0.md` from the milestone, as `docs/myspec-2.0-breaking-changes.md` and `docs/upgrading-to-2.0.md` were for 2.0.

## When in doubt

The single most consequential field is `frameworkVersion` in `framework-files/manifest.json` — that's what gates whether existing consumer projects see new framework files via `/myspec:update`. If you touched anything under `framework-files/`, the version must bump (minor at minimum), and the script must run.
