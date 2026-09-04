---
name: worktree-cleanup
description: "Retired in 2.0 → /myspec:worktree-clean. Do NOT auto-invoke."
---

# worktree-cleanup (retired)

This skill was retired in myspec 2.0. Its replacement is `/myspec:worktree-clean`.

Why: renamed for consistency with `session-clean`.

**Do nothing else.** Tell the user the new name and stop — do not run the old procedure
from memory, and do not invoke the replacement on their behalf.

This stub exists because plugins have no alias mechanism: without it the old name fails
with nothing to point at. It is removed one minor cycle after 2.0.
