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
2. Run the eval comparison (next section): `scripts/evals/release-check.sh --version X.Y.Z`. Read the report; on a regressed verdict or a failed run, decide whether to go on. Only on a go, record it and commit it on its own, before the bump, so the bump diff stays version files only:
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

"Broken" means the case fails one grader on every run, the way a skill that stopped triggering would. The previous rule (a CI below 0, or pass^3 dropping by more than 0.10) cried regression in 8–17% of A/A trials per model. Haiku's cases are too noisy to catch one or two broken cases reliably, so read the Haiku verdict as a signal, not a block. Before switching the gate on, compare these rates with what a few recorded releases actually show in `quality/trend.jsonl`.

**Cost.** HEAD's full run costs about $8 and takes about 7 minutes (Sonnet ≈ $5.8 and Haiku ≈ $2.0 at 3 runs; at 1 run the Sonnet suite measured $1.94 and 109 s). A whole-suite re-run of the previous tag doubles that. A changed case adds only that case's cost. The first release after this lands has no stored baseline, so it pays the double once. `--head-results <dir>` reuses a finished HEAD run on a retry.

**Skip.** `release-check.sh --version X.Y.Z --skip "<reason>"` runs nothing and records `{"version", "date", "skipped": "<reason>"}` in `quality/trend.jsonl`. Commit it the same way.

**Abort.** Before `--record`, nothing needs undoing. After `--record`, `git checkout -- quality && git clean -fd quality` restores it. After the `chore(quality)` commit, the commit is local and ahead of `origin/main`:

1. Confirm it is the only commit ahead: `git log --oneline origin/main..HEAD`.
2. Drop it: `git reset --hard origin/main`.

`git pull` still reports "Already up to date" while main is ahead, so the release preflight also checks `git status -sb` for `ahead`.

**Exit status:**

- 0: done. The run was report-only, not regressed, insufficient-data, or a `--case` run.
- 1: regressed with the gate on.
- 2: infrastructure error: usage limit, logged out, eval run failed, or interrupted. An exit 2 says nothing about the plugin.

**The gate.** The check is report-only: a regressed verdict prints the report and exits 0, and the maintainer decides. Once the calibration above holds up against a few recorded releases, make it a hard gate by changing one line in `quality/release-check.json`:

```json
  "gate": true,
```

The same file holds `seed` and `resamples`.

## Versioning rules (semver)

| Bump  | When                                                                                              |
|-------|---------------------------------------------------------------------------------------------------|
| Patch | Bug fixes in skill bodies. No new files, no manifest changes, no `.myspec.json` schema changes.   |
| Minor | New skills, new framework files, new manifest entries. Backward-compatible.                       |
| Major | Breaking changes to `.myspec.json` schema, removed/renamed skills, workflows requiring migration. |

## When in doubt

The single most consequential field is `frameworkVersion` in `framework-files/manifest.json` — that's what gates whether existing consumer projects see new framework files via `/myspec:update`. If you touched anything under `framework-files/`, the version must bump (minor at minimum), and the script must run.
