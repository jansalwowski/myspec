---
title: "Work Isolation"
purpose: "The user picks develop or worktree before the first source edit; hooks enforce it"
updated: 2026-10-10
---

# Work Isolation

Before the first source edit (any edit on the default or integration branch, or a detached HEAD), the user picks `develop` (edit this checkout) or `Worktree` (linked worktree, PR at the end); never pick for them. `require-isolation-decision.sh` and `guard-worktree-context.sh` enforce it. A block message says what to do next; the full procedure is `${aiDir}/work-isolation.md`. Never write files through an interpreter one-liner: the hooks cannot see it.

Your session id comes only from a block message. Never take one from `.claude/state/sessions/`: every session has a file there.
