---
name: "release"
description: "Use when cutting a new version of the myspec plugin — semver bump, tag, push, release notes. Repo-local maintainer skill (not shipped with the plugin). Keywords: release, publish version, cut a release, bump version, tag version, ship release. Do NOT use for merging PRs."
---

# Release

Cut a myspec release from `main`. Repo-local maintainer skill — lives in `.claude/skills/`, deliberately not shipped in the plugin (useless in consumer projects). Automates the process in `RELEASING.md` — the three version files must stay in lockstep, and the tag-push automation (not `gh release create`) produces the release.

**Announce at start:** "Preparing a myspec release."

## Prerequisites

- Working in the myspec framework repo: `framework-files/manifest.json` and `scripts/bump-version.sh` exist at repo root. If not → stop; this skill releases the framework itself. Consuming projects pull framework changes with `/myspec:update`.
- `gh` CLI authenticated, `jq` installed.

## Workflow

### Step 1: Preflight

Run all checks; any failure → report it and stop (fix first, never release around a failure):

1. On `main` (`git rev-parse --abbrev-ref HEAD`), clean tree (`git status --porcelain` empty), synced (`git pull` reports up to date), and not ahead: `git status -sb` must not say `ahead`. `git pull` reports "Already up to date" even when a local commit, such as a `chore(quality)` commit left by an aborted release, sits unpushed; show `git log --oneline origin/main..HEAD` and resolve it (Step 3's Abort) first.
2. Hooks parse: `bash -n` every `hooks/*.sh`.
3. Latest CI run on main succeeded: `gh run list --branch main --limit 1`. If not green, show the failure and ask for explicit confirmation before continuing.

### Step 2: Determine the Version

1. Last tag: `git describe --tags --abbrev=0`. Commits since: `git log {last_tag}..HEAD --oneline`.
2. **No-op guard:** check the shipped surfaces for changes — `git diff --stat {last_tag}..HEAD -- framework-files skills hooks hooks.json lib .claude-plugin scaffolding templates blueprints`. If empty, nothing consumers can receive has changed: report "nothing to release since {last_tag} — all changes are repo-meta (docs, CI, repo-local tooling)" and stop. Only continue past this with explicit user confirmation.
3. **Breaking gate:** list merged PRs labelled `breaking` since the last tag: `gh pr list --state merged --label breaking --search "merged:>=$(git log -1 --format=%cI {last_tag})" --json number,title,url,mergeCommit,baseRefName`. No `--base main`: a stacked PR keeps its parent branch as base after the parent merges, so that filter drops it (#110). It must exit 0; a non-zero exit is a failed check, never "no breaking PRs" — stop and report. Then keep only the PRs in this history, after a `git fetch origin` so their merge commits are local. A PR is in this history when `git merge-base --is-ancestor {mergeCommit.oid} HEAD` exits 0, or, when it exits 1 and `baseRefName` is not `main`, when the PR that merged its base branch is (`gh pr list --state merged --head {baseRefName} --json mergeCommit,baseRefName`, same test, repeated up a deeper stack): a squash-merged parent leaves the child's merge commit on a branch that is never an ancestor of `main`. Exit 128 (`Not a valid commit name`) means the commit is not fetched, not a failed check: fetch and retest, and if it persists the commit is on no branch of origin, so drop the PR. Drop the rest and print them as "merged elsewhere, ignored" (a PR merged into the next major's integration branch, such as `v3`, is listed while a 2.x patch is cut from `main`). A non-empty remaining list means the release is **major**; minor and patch are not offered. To ship a minor anyway, the user removes the label from each listed PR with a comment saying why it is not breaking (RELEASING.md "Breaking changes"), then re-run the breaking gate.
4. **Stub gate:** `scripts/overdue-stubs.sh --version {last_tag with the minor bumped and patch 0}` — always that version, whatever bump is chosen, because its verdict only ever gates a minor. It lists every retirement stub (`skills/*/SKILL.md` with `disable-model-invocation: true` and "Retired in myspec X.Y" in its description) as `shipping`, `due` or `overdue` against that version, and exits 1 while one is overdue (retired two or more minors ago, or in an older major; RELEASING.md "Retirement stubs"). Exit 2 is a failed check (a stub with no readable retirement version) — stop and report. With an overdue stub, a **minor is not offered**; the stubs are deleted first (their own PR) or the release is a major. A **patch is never refused** for a stub — a maintenance branch must not wait on a stub scheduled for the next major. Show `due` stubs as a reminder that the next minor deletes them.
5. Suggest a bump from the RELEASING.md semver table and its "Breaking changes" definition: a breaking change (the breaking-gate list, or one the commits show without a label, which you flag to the user) → **major**; new skills, new framework files, new manifest entries, or any change under `framework-files/` → **minor**; body-only bug fixes → **patch**.
6. Call `AskUserQuestion` with the suggested version first, marked `(Recommended)`, plus the other bump levels the breaking and stub gates allow. Wait for the choice. For a major, also list the open issues still in its milestone (`gh issue list --milestone v{X}.0.0 --state open`) and confirm they are deferred to a later major or done.

### Step 3: Eval Comparison

`scripts/evals/release-check.sh` runs the full eval suite on HEAD (3 runs, Sonnet and Haiku agents, Sonnet judge) and compares it case by case with the previous release. Every run is a real model call on the maintainer's login, so state the cost before starting:

| Situation | Spend | Time |
|---|---|---|
| Stored baseline for the previous tag is reused (the usual case) | about $8 (Sonnet ≈ $5.8, Haiku ≈ $2.0) | about 7 min |
| The previous tag's whole suite is re-run too | about $16 | about 15 min |

The script prints which applies (`baseline REUSE …`, `RERUN <model> <reason>`, `RERUN-CASE <case> <reason>`). RELEASING.md lists the rules: any Claude Code version change, a changed or unresolved model id, or changed `evals/_fixtures/` re-runs the suite; a changed case re-runs only that case. The check writes nothing to `quality/`; it stages files in its output directory.

1. Tell the maintainer the estimate. If they choose to skip (quota, outage, docs-only release), run `scripts/evals/release-check.sh --version {X.Y.Z} --skip "<reason>"`, which records the reason in `quality/trend.jsonl`, and go to item 5.
2. Run `scripts/evals/release-check.sh --version {X.Y.Z}` in the background: it can outlast a 10-minute tool timeout. Wait for it to exit, then show the comparison report and note the output directory it printed (`release-check: output in <out>`).
3. Act on the exit status, not on the output alone:
   - **0, verdict improved, no-change or insufficient-data:** go to item 4. Show any `warning:` line (a single regressed case).
   - **0 with `WARNING: REGRESSED on <models>; report-only`** (a model not in `"gateModels"`, Haiku, regressed and no gating model did): show that model's reasons as a signal and go to item 4; it does not block.
   - **0 with `REGRESSED; report-only`** (only when `"gate": false` was set by hand): show the regressed models, their reasons, and the REGRESSED column. Call `AskUserQuestion`: continue the release, or stop to investigate. On stop, go to Abort.
   - **1** (a model in `"gateModels"`, Sonnet, regressed; `"gate": true` in `quality/release-check.json` is the standing setting): stop and go to Abort. The release does not go out on a gating model's regression while the gate is on.
   - **2 with `gateModels is empty` or `gateModels lists <model>`** (the gate would block on nothing): show the line, fix `quality/release-check.json` or `--models` with the maintainer, and re-run. Never skip the check over it.
   - **2** (infrastructure error: usage limit, logged out, run failed, interrupted): show the last lines it printed. Call `AskUserQuestion`: retry, skip with a reason (item 1), or stop. When HEAD's run finished, retry with `--head-results <out>/head` so it is not paid for twice.
4. On a go: `scripts/evals/release-check.sh --record <out>` copies the staged baselines and trend line into `quality/`.
5. Commit them before the bump: `git add quality && git commit -m "chore(quality): record v{X.Y.Z} eval baseline"`. This keeps the bump diff to version files only.

**Abort**, whenever the release stops after this step:

- Before `--record`, `quality/` is untouched and there is nothing to undo.
- Recorded but not committed: `git checkout -- quality && git clean -fd quality`.
- Committed: the commit is local and ahead of `origin/main`. Show `git log --oneline origin/main..HEAD`. If it lists only the `chore(quality)` commit, run `git reset --hard origin/main`. Otherwise stop and ask.

### Step 4: Bump, Commit, Tag, Push

1. `./scripts/bump-version.sh {X.Y.Z}`
2. Show `git diff` — the only changes must be version fields (and the marketplace `ref`) in the three files. Anything else → stop and investigate.
3. `git add -A && git commit -m "chore: bump to v{X.Y.Z}"`
4. `git tag v{X.Y.Z}` then `git push && git push --tags`

### Step 5: Release Notes

Pushing the tag **auto-publishes** the release — the workflow runs `gh release create --generate-notes` with no `--draft`. It is public within about a minute, titled with the bare tag and carrying only PR titles. `gh release create` then fails with HTTP 422 because the release already exists.

**Write the notes before Step 4 pushes the tag.** Every minute between the push and the edit is a live release that says nothing.

1. Draft highlights from the commits/PRs since the previous tag — group by fixes / features / docs. If anything under `framework-files/`, `hooks/`, or `lib/` changed, include an **Upgrading** section telling consumers to run `/myspec:update`.
2. Show the notes; accept-or-edit **before** the tag is pushed.
3. After the push, poll `gh release view v{X.Y.Z}` (retry over ~30s) until the release object exists.
4. Append the generated body to yours, then land both:
   ```bash
   gh release view v{X.Y.Z} --json body --jq .body > /tmp/generated.md
   cat /tmp/notes.md /tmp/generated.md > /tmp/final.md
   gh release edit v{X.Y.Z} --title "v{X.Y.Z} — {short theme}" --notes-file /tmp/final.md
   ```
   Keep the "What's Changed" PR links and "Full Changelog" line at the bottom — they are the only per-PR attribution the release carries.
5. If no release object appears after ~30s the workflow failed: check its run, then `gh release create v{X.Y.Z} --notes-file /tmp/final.md` by hand.

### Step 6: Verify

- `gh release view v{X.Y.Z}` shows the enriched notes.
- All three version files report `{X.Y.Z}`: `grep -r '"version"\|frameworkVersion\|"ref"' framework-files/manifest.json .claude-plugin/plugin.json .claude-plugin/marketplace.json`.
- `git status` clean; local `main` matches `origin/main`.

## Rules

- Never release from a branch other than `main`, or with a dirty tree — the tag must point at exactly what CI validated.
- Never hand-edit the three version files; only `scripts/bump-version.sh` writes them.
- Show the bump diff and the notes draft before committing/publishing — no silent releases.
- Never release on a regressed or failed eval check without the user's explicit go-ahead, and never on a regressed verdict while the gate is on.
- The Upgrading note is required whenever `framework-files/` changed since the last tag: that is what gates `/myspec:update` for every consumer.

## Verification Checklist

- [ ] Preflight fully passed (main, clean, synced, not ahead of origin, hooks parse, CI green or explicitly overridden)
- [ ] Breaking gate ran (exit 0): no `breaking` PRs in HEAD's history since the last tag (those merged elsewhere printed as ignored), or the release is major
- [ ] Stub gate ran (exit 0 or 1, never 2): no overdue retirement stub, or the release is a patch or a major
- [ ] Version confirmed by the user against the semver table
- [ ] Eval comparison ran or a skip was recorded with its reason; a regressed or failed run was confirmed by the user before `--record`; `quality/` committed as `chore(quality): record v{X.Y.Z} eval baseline` before the bump
- [ ] Bump diff contained only the three version files; committed as `chore: bump to v{X.Y.Z}`
- [ ] Notes written and approved **before** the tag was pushed
- [ ] Notes landed via `gh release edit` (the tag auto-publishes; `create` only as a fallback if the workflow failed)
- [ ] Release page shows enriched notes with PR links preserved; Upgrading section present if framework-files changed

## Integration

**Called after** [OPTIONAL]: merging release-bound PRs to `main`
**Reference** [REQUIRED]: `RELEASING.md` — the authoritative process this skill automates; if they disagree, RELEASING.md wins and this skill needs a fix
