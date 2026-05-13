---
name: "feature-complete"
description: >
  Use when feature implementation is complete and all plan tasks are checked off.
  Keywords: feature done, complete feature, finish feature, update feature status,
  implementation merged, archive plan, branch merge, finish PR.
  Do NOT use mid-implementation or before all planned tasks are done.
tags: [feature, documentation, completion, workflow, branch, merge, pr]
---

# Feature Complete

## Prerequisites
- Implementation is complete (all planned tasks done)

---

## Phase 1 — Docs Sync

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
   - Update `status` (in-progress → complete, or add note)
   - Add/update `note:` for partial completion
   - Update `phase` if documentation phase changed

   **Note**: If this is a sub-feature, update the feature-level `${aiDir}/features/{parent}/index.yaml` instead of the main index.yaml.

7. **Archive Implementation Plan**
   - Check if `implementation-plan.md` exists in the feature directory
   - If it exists:
     - Read the plan's `title` frontmatter → convert to kebab-case for the archive filename
     - Create `plans/` directory if it doesn't exist
     - Move `implementation-plan.md` → `plans/{YYYY-MM-DD}-{kebab-title}.md` (use today's date)
     - Add `archived: {date}` field to the archived plan's frontmatter
     - If filename collision (same date + name already exists), append `-2`, `-3` suffix
     - If `CHANGELOG.md` doesn't exist, create it:
       ```markdown
       # {Feature Name} Changelog

       | Date | Plan | Summary | Status |
       |------|------|---------|--------|
       ```
     - Prepend a new row to `CHANGELOG.md`:
       `| {date} | [{plan title}](plans/{filename}.md) | {one-sentence summary of what this plan implemented} | {complete|partial} |`
     - Use `partial` status if any plan tasks were deferred or skipped
   - If no `implementation-plan.md` exists: skip silently (backward compatible)

8. **Cross-Reference Check**
   - If dependencies changed, update `dependencies.md` bidirectionally
   - If this feature is now usable by others, update their docs

---

- [ ] All implementation steps in tech-spec.md marked `[x]`
- [ ] File Inventory updated to match actual created/modified files
- [ ] `status` in `${aiDir}/features/index.yaml` updated to `complete`
- [ ] `last_updated` in tech-spec.md frontmatter updated to today
- [ ] Implementation plan archived to `plans/` directory (if plan existed)
- [ ] `CHANGELOG.md` updated with new entry (if plan was archived)
- [ ] Run project documentation audit command if configured

---

## Phase 2 — Verification

1. Read `.claude/verification.json` and run each required check
2. Run project documentation audit command if configured
3. If all pass → continue to Phase 3

**If failures detected:**
- Analyze failures against files changed in this feature branch
- **Failures are related to this feature → hard stop. Fix before proceeding.**
- Failures appear unrelated (pre-existing or from parallel changes) → ask user to confirm before continuing

---

## Phase 3 — Branch Integration

1. **Detect worktree** — run `git worktree list | grep $(git branch --show-current)`

2. **Present options:**
   ```
   Implementation complete. What would you like to do?

   1. Merge back to <base-branch> locally
   2. Push and create a Pull Request
   3. Keep the branch as-is (I'll handle it later)
   4. Discard this work

   Which option?
   ```

3. **Execute choice:**

   **Option 1 — Merge locally:**
   ```bash
   git checkout <base-branch>
   git pull
   git merge <feature-branch>
   # Run verification again on merged result
   git branch -d <feature-branch>
   ```

   **Option 2 — Push and create PR:**
   ```bash
   git push -u origin <feature-branch>
   gh pr create --title "<title>" --body "$(cat <<'EOF'
   ## Summary
   <2-3 bullets of what changed>

   ## Test Plan
   - [ ] <verification steps>
   EOF
   )"
   ```

   **Option 3 — Keep as-is:** Report branch name and stop.

   **Option 4 — Discard:**
   Confirm first:
   ```
   This will permanently delete:
   - Branch <name>
   - All commits: <commit-list>

   Type 'discard' to confirm.
   ```
   Wait for exact `discard` input, then:
   ```bash
   git checkout <base-branch>
   git branch -D <feature-branch>
   ```

4. **Worktree cleanup** (only for options 1 & 4, and only if worktree was detected):
   ```bash
   git worktree remove <worktree-path>
   ```

---

## Integration

**Called by:** `/myspec:feature-implement` (after implementation is complete)
