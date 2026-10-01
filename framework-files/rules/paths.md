---
title: "Path Conventions"
purpose: "How to reference files in committed artifacts so they stay portable across machines and users"
paths:
  - ${aiDir}/**
  - .claude/**
  - docs/**
updated: 2026-10-01
---

# Path Conventions

Committed artifacts (anything under `${aiDir}/`, `docs/`, `.claude/`, or the repo root) must use paths that are valid on every machine and user. Absolute homedir paths leak the author's filesystem layout and break for everyone else.

| Reference target | Use | Do not use |
|---|---|---|
| Framework-managed doc (during skill or blueprint authoring) | `${aiDir}/features/foo/spec.md` | Resolved value (`ai/features/...`) hardcoded into skills |
| Codebase file in a tech-spec, plan, or memory note | Repo-relative: `src/auth/login.ts` | `/Users/<name>/project/src/auth/login.ts`, `~/project/src/...` |
| Cross-doc link inside `${aiDir}/` | Explicitly relative: `./sub/spec.md` | Bare `sub/spec.md` (ambiguous) |
| Example that must show an absolute path | Placeholder: `<repo_root>/src/...` or `~/.claude-personal/projects/<encoded_cwd>/...` | Real `/Users/...` or `/home/...` |

Checked by `.claude/hooks/no-absolute-paths.sh`. It runs after a Write or Edit (PostToolUse), so the file is already on disk: when the new content adds a homedir or encoded-cwd path, it flags the file, points at the line and asks for a fix. It checks doc files (`.md`, `.mdx`, `.txt`, …) anywhere and every file under `${aiDir}/`, `docs/` and `.claude/`, and skips gitignored files, files outside the repository, and app code. A script that must convert a captured absolute path sources `.claude/lib/path-normalize.sh` (`normalize_path`, `encode_cwd`).
