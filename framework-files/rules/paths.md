---
title: "Path Conventions"
purpose: "How to reference files in committed artifacts so they stay portable across machines and users"
paths:
  - ${aiDir}/**
  - .claude/**
  - docs/**
updated: 2026-10-06
---

# Path Conventions

Committed artifacts (anything under `${aiDir}/`, `docs/`, `.claude/`, or the repo root) must use paths that are valid on every machine and user. Absolute homedir paths leak the author's filesystem layout and break for everyone else.

| Reference target | Use | Do not use |
|---|---|---|
| Framework-managed doc (during skill or blueprint authoring) | `${aiDir}/features/foo/spec.md` | Resolved value (`ai/features/...`) hardcoded into skills |
| Codebase file in a tech-spec, plan, or memory note | Repo-relative: `src/auth/login.ts` | `/Users/<name>/project/src/auth/login.ts`, `~/project/src/...` |
| Cross-doc link inside `${aiDir}/` | Explicitly relative: `./sub/spec.md` | Bare `sub/spec.md` (ambiguous) |
| Example that must show an absolute path | Placeholder: `<repo_root>/src/...` or `<config_dir>/projects/<encoded_cwd>/...` | Real `/Users/...` or `/home/...` |

Checked by the myspec plugin's `no-absolute-paths.sh` hook. It runs before a Write or Edit lands (PreToolUse) and reads only what the call adds (a Write's content, an Edit's new text): when that contains a homedir or encoded-cwd path, it denies the call, points at the line and says what to write instead. It never rescans the file, so a path already in it blocks no edit that leaves it alone. It checks doc files (`.md`, `.mdx`, `.txt`, …) anywhere and every file under `${aiDir}/`, `docs/` and `.claude/`, and skips gitignored files, files outside the repository, and app code. A write the hook cannot see (a Bash heredoc, `sed -i`, `tee`) is checked by the Stop gate on the lines it added, with the same message, before the session ends. A script that must convert a captured absolute path sources the plugin's `lib/path-normalize.sh` (`normalize_path`, `encode_cwd`); the hook's message prints its path.
