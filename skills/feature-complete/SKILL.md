---
description: "Use when finishing a feature implementation. Updates tech-spec.md, index.yaml, and validates documentation matches code. Do NOT use mid-implementation."
---

# Complete Feature Implementation

Validate and update documentation after feature implementation is complete.

## Path Resolution

1. Read `.myspec.json` from project root
2. Extract `aiDir` value (e.g., ".ai" or "ai")
3. All paths below use `${aiDir}` — resolve before use
4. If `.myspec.json` not found: STOP and tell user to run `/myspec:init`

## Prerequisites
- Implementation is complete (all planned tasks done)
- Tests pass (if applicable)

## Instructions

1. **Read Current State**
   - Read `${aiDir}/features/{feature}/tech-spec.md`
   - Read `${aiDir}/features/{feature}/spec.md`
   - Read `${aiDir}/features/index.yaml` entry for this feature

2. **Validate Implementation Steps**
   For each step in tech-spec.md Implementation Steps:
   - [ ] Mark completed with [x]
   - [ ] If skipped or deferred, add note explaining why
   - [ ] If done differently, update description to match reality

3. **Update File Inventory**
   Compare planned vs. actual:
   - Add files that were created but not planned
   - Remove files that were planned but not created
   - Update "Action" column to reflect what actually happened
   - Update "Purpose" if it changed

4. **Document Decisions Made**
   For any decisions made during implementation:
   - Add to Decisions section with ADR format
   - If decision contradicts original plan, update relevant sections

5. **Update Frontmatter**
   - Update `last_updated` to today's date
   - If spec changed, verify `based_on_spec_version` matches

6. **Update Feature Manifest**
   In `${aiDir}/features/index.yaml` (or `${aiDir}/features/{feature}/index.yaml` for sub-features):
   - Update `status` (in-progress -> complete, or add note)
   - Add/update `note:` for partial completion
   - Update `phase` if documentation phase changed

   **Note**: If this is a sub-feature, update the feature-level `${aiDir}/features/{parent}/index.yaml` instead of the main index.yaml.

7. **Cross-Reference Check**
   - If dependencies changed, update `dependencies.md` bidirectionally
   - If this feature is now usable by others, update their docs

## Output
Summarize changes made to documentation.
