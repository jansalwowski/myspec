---
name: "release"
description: "Use when cutting a new version of the myspec plugin — semver bump, tag, push, release notes. Repo-local maintainer skill (not shipped with the plugin). Keywords: release, publish version, cut a release, bump version, tag version, ship release. Do NOT use for merging PRs."
---

# Release

Cut a myspec release from `main`. Repo-local maintainer skill — lives in `.claude/skills/`, deliberately not shipped in the plugin (useless in consumer projects). Automates the process in `RELEASING.md` — the five version files must stay in lockstep, and the tag-push automation (not `gh release create`) produces the release.

**Announce at start:** "Preparing a myspec release."

## Prerequisites

- Working in the myspec framework repo: `framework-files/manifest.json` and `scripts/bump-version.sh` exist at repo root. If not → stop; this skill releases the framework itself. Consuming projects pull framework changes with `/myspec:update`.
- `gh` CLI authenticated, `jq` installed.

## Workflow

### Step 1: Preflight

Run all checks; any failure → report it and stop (fix first, never release around a failure):

1. On `main` (`git rev-parse --abbrev-ref HEAD`), clean tree (`git status --porcelain` empty), synced (`git pull` reports up to date).
2. Mirror parity — the same diffs CI runs: `diff -r skills plugins/myspec/skills`, `diff -r hooks plugins/myspec/hooks`, `diff hooks.json plugins/myspec/hooks.json`, `diff -r lib plugins/myspec/lib`, `diff -r .codex-plugin plugins/myspec/.codex-plugin`.
3. Hooks parse: `bash -n` every `hooks/*.sh`.
4. Latest CI run on main succeeded: `gh run list --branch main --limit 1`. If not green, show the failure and ask for explicit confirmation before continuing.

### Step 2: Determine the Version

1. Last tag: `git describe --tags --abbrev=0`. Commits since: `git log {last_tag}..HEAD --oneline`.
2. Suggest a bump from the RELEASING.md semver table: breaking `.myspec.json` schema change, removed/renamed skill, or migration-requiring workflow → **major**; new skills, new framework files, new manifest entries, or any change under `framework-files/` → **minor**; body-only bug fixes → **patch**.
3. Call `AskUserQuestion` with the suggested version first, marked `(Recommended)`, plus the other two bump levels. Wait for the choice.

### Step 3: Bump, Commit, Tag, Push

1. `./scripts/bump-version.sh {X.Y.Z}`
2. Show `git diff` — the only changes must be version fields (and the marketplace `ref`) in the five files. Anything else → stop and investigate.
3. `git add -A && git commit -m "chore: bump to v{X.Y.Z}"`
4. `git tag v{X.Y.Z}` then `git push && git push --tags`

### Step 4: Release Notes

Pushing the tag auto-drafts a GitHub release with generated PR links — `gh release create` will fail with HTTP 422 once it exists. Enrich the draft instead:

1. Poll `gh release view v{X.Y.Z}` (retry a few times over ~30s) until the auto-draft appears.
2. Draft highlights from the commits/PRs since the previous tag — group by fixes / features / docs. If anything under `framework-files/`, `hooks/`, or `lib/` changed, include an **Upgrading** section telling consumers to run `/myspec:update`.
3. Show the draft notes; accept-or-edit before publishing.
4. `gh release edit v{X.Y.Z} --title "v{X.Y.Z} — {short theme}" --notes "{notes}"` — keep the auto-generated "What's Changed" PR links and "Full Changelog" line at the bottom of the notes.
5. Fallback: if no auto-draft appears after ~30s, `gh release create v{X.Y.Z} --title ... --notes ...`.

### Step 5: Verify

- `gh release view v{X.Y.Z}` shows the enriched notes.
- All five version files report `{X.Y.Z}`: `grep -r '"version"\|frameworkVersion\|"ref"' framework-files/manifest.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json plugins/myspec/.codex-plugin/plugin.json`.
- `git status` clean; local `main` matches `origin/main`.

## Rules

- Never release from a branch other than `main`, or with a dirty tree — the tag must point at exactly what CI validated.
- Never hand-edit the five version files; only `scripts/bump-version.sh` writes them.
- Show the bump diff and the notes draft before committing/publishing — no silent releases.
- The Upgrading note is required whenever `framework-files/` changed since the last tag: that is what gates `/myspec:update` for every consumer.

## Verification Checklist

- [ ] Preflight fully passed (main, clean, synced, mirrors identical, hooks parse, CI green or explicitly overridden)
- [ ] Version confirmed by the user against the semver table
- [ ] Bump diff contained only the five version files; committed as `chore: bump to v{X.Y.Z}`
- [ ] Tag pushed; notes landed via `gh release edit` on the auto-draft (or `create` fallback after the ~30s window)
- [ ] Release page shows enriched notes with PR links preserved; Upgrading section present if framework-files changed

## Integration

**Called after** [OPTIONAL]: merging release-bound PRs to `main`
**Reference** [REQUIRED]: `RELEASING.md` — the authoritative process this skill automates; if they disagree, RELEASING.md wins and this skill needs a fix
