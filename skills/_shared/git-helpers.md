# Git Helpers (shared reference)

Reusable git logic referenced by skills that ask about commits, branches, or
worktrees. Not a skill — do not invoke via `Skill`. Read inline when a skill
points to this file.

## Detect the default branch

Run this cascade; first one that succeeds is authoritative:

1. `git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'`
2. `git rev-parse --verify --quiet main` → if exit 0, default is `main`
3. `git rev-parse --verify --quiet master` → if exit 0, default is `master`
4. Ask the user which local branch is the trunk

Cache the result for the current turn — don't re-run the cascade per prompt.

## Detect current state (for prompt defaults)

| Signal | Command | Use for |
|--------|---------|---------|
| Current branch | `git rev-parse --abbrev-ref HEAD` | Decide if HEAD is the default branch |
| Working tree clean? | `git status --porcelain` (empty = clean) | Block worktree creation when dirty |
| Existing worktree for {name}? | `git worktree list --porcelain \| grep -F "feat-{name}"` | Recommend "use existing worktree" |
| Branch exists? | `git rev-parse --verify --quiet feat/{name}` | Recommend "checkout existing" vs "create" |

## Conventions

- **Worktree path:** `.claude/worktrees/feat-{feature-name}` (matches `worktree-clean` and `feature-implement`)
- **Feature branch name:** `feat/{feature-name}` (conventional, kebab-case)
- **Commit message:** `feat({feature-name}): {summary}` — conventional commits, matches existing feature-plan rule

## Commit message defaults

| Skill | Suggested default |
|-------|-------------------|
| `feature-spec` | `feat({name}): add spec and dependencies` |
| `feature-plan` | `feat({name}): add implementation plan` |

Always **show the draft and let the user accept-or-edit** before committing.
Do not commit silently.

## Recommendation rules for the flow prompt

When asking "where should this go?", compute which option to mark
`(Recommended)` based on detected state:

- HEAD == default branch → recommend "new feature branch"
- HEAD is already a feature branch and clean → recommend "commit to {HEAD}"
- A worktree for this feature exists → recommend that worktree
- Plan has `[parallel:*]` groups and no worktree yet → recommend "worktree"
- Working tree dirty → require resolve (commit/stash) before any branch switch
