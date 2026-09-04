---
name: docs-sanitize
description: "Retired in myspec 2.0, not replaced."
disable-model-invocation: true
allowed-tools: [Read]
---

# docs-sanitize (retired)

This skill was retired in myspec 2.0 with no direct replacement.

## Workflow

1. Tell the user this skill is retired and where its three jobs went:
   - naming-convention violations under `${aiDir}` → `/myspec:doctor` surface C
   - misplaced session files → `/myspec:session-clean`
   - references to renamed or moved files → `/myspec:doctor` surface C
2. Stop.

## Rules

- Do nothing else. Do not run the old procedure from memory.
- Do not invoke a replacement on the user's behalf — name it and let them choose.
- `disable-model-invocation: true` keeps this out of the always-loaded description budget; it stays reachable as a slash command.
- Remove this stub one minor cycle after 2.0.

## Verification Checklist

- [ ] Told the user the skill is retired
- [ ] Named where each of the three jobs went
- [ ] Ran no audit, edit, or move
