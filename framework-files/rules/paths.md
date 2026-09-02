---
title: "Path Conventions"
purpose: "How to reference files in committed artifacts so they stay portable across machines and users"
updated: 2026-09-02
---

# Path Conventions

Committed artifacts (anything under `${aiDir}/`, `docs/`, `.claude/`, or the repo root) must use paths that are valid on every machine and user. Absolute homedir paths leak the author's filesystem layout and break for everyone else.

## Rules

| Reference target | Use | Do not use |
|---|---|---|
| Framework-managed doc (during skill or blueprint authoring) | `${aiDir}/features/foo/spec.md` | Resolved value (`ai/features/...`) hardcoded into skills |
| Codebase file in a tech-spec, plan, or memory note | Repo-relative: `src/auth/login.ts` | `/Users/<name>/project/src/auth/login.ts`, `~/project/src/...` |
| Cross-doc link inside `${aiDir}/` | Explicitly relative: `./sub/spec.md` | Bare `sub/spec.md` (ambiguous) |
| Example that must show an absolute path | Placeholder: `<repo_root>/src/...` or `~/.claude-personal/projects/<encoded_cwd>/...` | Real `/Users/...` or `/home/...` |

## What gets blocked

`.claude/hooks/no-absolute-paths.sh` (installed by `init`) hard-fails any Write or Edit that emits a path matching `/Users/<name>`, `/home/<name>`, or the encoded-cwd forms `-Users-<name>-...` / `-home-<name>-...`. The block message points at the offending line and suggests the placeholder form.

## Helpers

`.claude/lib/path-normalize.sh` exposes `normalize_path`, `resolve_repo_root`, `encode_cwd`, and `detect_absolute_paths`. Source it from a script that needs to convert a captured absolute path before writing it.
