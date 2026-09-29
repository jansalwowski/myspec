---
name: release-notes
description: "This skill reads the git log since the last tag, groups commits by type, writes RELEASE_NOTES.md, and then opens a pull request with the notes."
---

# Release Notes

> **IMPORTANT!!!** ALWAYS FOLLOW EVERY STEP BELOW EXACTLY. NEVER SKIP ANYTHING.

---

## Steps

1. Run `git describe --tags --abbrev=0` to find the last tag.
2. Run `git log <tag>..HEAD --oneline` and read every commit.
3. Group the commits into Features, Fixes and Other.
4. Write RELEASE_NOTES.md.
5. See Step 7 for how to open the pull request.

---

## Notes

The notes should be good and complete.
