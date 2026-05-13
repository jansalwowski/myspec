# Agent Conventions for myspec

This file applies to agents working **on** the myspec framework itself (this repo). For agents working **with** myspec in a downstream project, see the per-project AGENTS.md / CLAUDE.md that `init` writes.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) — `<type>(<scope>): <subject>`.

**Types used in this repo:**

| Type | Use for |
|------|---------|
| `feat` | New skill, new capability, new convention |
| `fix` | Bug fix in a skill, hook, template, or framework file |
| `refactor` | Restructuring without behavior change (decoration removal, dedup, voice cleanup) |
| `refine` | Local convention for quality refinement of an existing skill (e.g., applying skill-verify guidance) |
| `docs` | README, AGENTS.md, comments — not skill bodies (those are `feat`/`fix`/`refactor`) |
| `chore` | Version bumps, dependency updates, repo maintenance |
| `ci` | Hooks, GitHub Actions, automation |

**Common scopes:** `skills`, `<skill-name>` (e.g. `skill-verify`, `feature-implement`), `plugin`, `paths`, `upstream-sync`.

**Rules:**

- Subject line under ~70 chars, imperative mood, no trailing period.
- Multi-skill changes: use `skills` scope and list skill names in the body.
- Single-skill changes: use the skill name as the scope (e.g. `fix(feature-plan): ...`).
- Body explains the *why* — the *what* should be visible from the diff.

## Skill changes touch two trees

The repo keeps two parallel skill trees: `skills/` (top-level) and `plugins/myspec/skills/` (plugin tree). They must stay in sync — when you edit a SKILL.md in one, mirror to the other in the same commit. The recent `chore(plugin): reconcile skill drift` commit exists because this slipped.

## Skill quality

When writing or editing skills, follow the principles enforced by the `skill-verify` skill (`skills/skill-verify/SKILL.md`). The two highest-impact rules:

- **Descriptions are triggers, not summaries.** Start with "Use when…", avoid sequential workflow verbs ("analyzes X, generates Y, validates Z") — the agent will skip loading the body.
- **Format SKILL.md for the model, not humans.** No decorative blockquotes, horizontal rules inside body, ASCII diagrams, or all-caps imperative walls without rationale. Tables and numbered procedures are good; decoration is paid for in tokens on every load.

## Paths in skills, blueprints, and templates

Everything in `skills/`, `blueprints/`, `framework-files/`, and `templates/` is read by downstream models inside other people's repos. Hardcoded absolute paths (`/Users/<you>/...`) and resolved aiDir values (`ai/features/...`) leak local layout.

- Use `${aiDir}/...` for any framework-managed doc — `init` substitutes per-project.
- Use repo-relative paths (`src/foo.ts`) for codebase file references in examples and tables.
- Use `<repo_root>` / `<encoded_cwd>` placeholders when an example genuinely needs to show an absolute path.
- The `no-absolute-paths.sh` PostToolUse hook will block writes that violate this; the rule it enforces is also shipped to downstream projects as `framework-files/rules/paths.md`.
