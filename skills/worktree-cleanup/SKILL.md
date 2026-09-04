---
name: worktree-cleanup
description: "Retired in myspec 2.0 — renamed to worktree-clean."
disable-model-invocation: true
allowed-tools: [Read]
---

# worktree-cleanup (retired)

This skill was retired in myspec 2.0. Its replacement is `/myspec:worktree-clean`.

Why: renamed for consistency with `session-clean`.

## Workflow

1. Tell the user the new name: `/myspec:worktree-clean`.
2. Stop.

## Rules

- Do nothing else. Do not run the old procedure from memory.
- Do not invoke the replacement on the user's behalf — name it and let them choose.
- This stub exists because plugins have no alias mechanism: without it the old name fails with nothing to point at.
- `disable-model-invocation: true` keeps this out of the always-loaded description budget; it stays reachable as a slash command.
- Remove this stub one minor cycle after 2.0.

## Verification Checklist

- [ ] Told the user the new name
- [ ] Ran no cleanup and invoked no replacement
