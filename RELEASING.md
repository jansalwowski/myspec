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
5. `git tag vX.Y.Z`
6. `git push && git push --tags`
7. Pushing the tag **auto-drafts the GitHub release** (repo automation) with generated PR links — a subsequent `gh release create` fails with HTTP 422. Enrich the draft instead: `gh release edit vX.Y.Z --title "..." --notes "..."`, keeping the auto-generated "What's Changed" links at the bottom. Only if no draft appears after ~30s, fall back to `gh release create vX.Y.Z --generate-notes`.

## Versioning rules (semver)

| Bump  | When                                                                                              |
|-------|---------------------------------------------------------------------------------------------------|
| Patch | Bug fixes in skill bodies. No new files, no manifest changes, no `.myspec.json` schema changes.   |
| Minor | New skills, new framework files, new manifest entries. Backward-compatible.                       |
| Major | Breaking changes to `.myspec.json` schema, removed/renamed skills, workflows requiring migration. |

## When in doubt

The single most consequential field is `frameworkVersion` in `framework-files/manifest.json` — that's what gates whether existing consumer projects see new framework files via `/myspec:update`. If you touched anything under `framework-files/`, the version must bump (minor at minimum), and the script must run.
