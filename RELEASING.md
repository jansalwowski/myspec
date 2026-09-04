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
2. From a clean working tree: `./scripts/bump-version.sh X.Y.Z`
3. `git diff` — review the version bumps
4. `git add -A && git commit -m "chore: bump to vX.Y.Z"`
5. **Write the release notes now**, before the tag exists — see step 8 for why. Draft from the PRs since the previous tag, and include an **Upgrading** section whenever anything under `framework-files/`, `hooks/`, or `lib/` changed.
6. `git tag vX.Y.Z`
7. `git push && git push --tags`
8. Pushing the tag **auto-publishes the GitHub release** — `.github/workflows/release.yml` runs `gh release create "$TAG" --title "$TAG" --generate-notes`, with no `--draft`. The release is public within about a minute of the tag landing, titled with the bare tag and carrying nothing but a list of PR titles.

   **So have the notes written before you push the tag.** Between the push and your edit there is a live release that says nothing useful; for a patch that is noise, and for a major it is the version most people will read on the day.

   Enrich it with `gh release edit`, not `create` — the release already exists, so `gh release create` fails with HTTP 422:

   ```bash
   gh release view vX.Y.Z --json body --jq .body > /tmp/generated.md   # the PR links
   cat notes.md /tmp/generated.md > /tmp/final.md                      # yours first, links last
   gh release edit vX.Y.Z --title "vX.Y.Z — short theme" --notes-file /tmp/final.md
   ```

   Keep the generated "What's Changed" and "Full Changelog" lines at the bottom — they are the only per-PR attribution the release carries. If no release object exists after ~30s the workflow failed: check its run, then `gh release create vX.Y.Z --notes-file /tmp/final.md` by hand.

   To close the live window instead of racing it, add `--draft` to the workflow's `gh release create` and publish with `gh release edit --draft=false` once the notes are in. That trades a public gap for a release that does not exist until someone finishes it.

## Versioning rules (semver)

| Bump  | When                                                                                              |
|-------|---------------------------------------------------------------------------------------------------|
| Patch | Bug fixes in skill bodies. No new files, no manifest changes, no `.myspec.json` schema changes.   |
| Minor | New skills, new framework files, new manifest entries. Backward-compatible.                       |
| Major | Breaking changes to `.myspec.json` schema, removed/renamed skills, workflows requiring migration. |

## When in doubt

The single most consequential field is `frameworkVersion` in `framework-files/manifest.json` — that's what gates whether existing consumer projects see new framework files via `/myspec:update`. If you touched anything under `framework-files/`, the version must bump (minor at minimum), and the script must run.
