---
title: "Auto-Memory Style Guide"
purpose: "Length budget, cut list, and write-time consolidation for user-level auto-memory entries"
load_when: always
updated: 2026-05-11
---

# Auto-Memory Style Guide

Governs entries in the harness-managed user-level auto-memory store at
`~/.claude-personal/projects/<encoded_cwd>/memory/`.

**Out of scope**: project-level myspec memory at `${aiDir}/memory/` — those use
their own typed templates in `${aiDir}/.templates/`.

## Why this exists

Auto-memory entries grow long over time. A typical bloated entry has:
- A narrative of the originating incident
- A full code block
- A "where applied: file:line, PR #X" footer

None of that is the lesson. The lesson is the **rule** plus the **trigger** plus
the **minimal pattern**. Everything else is a token tax paid on every recall.

This file sets a length budget and a cut list so entries stay essence-shaped
both at creation time and during `/myspec:memory-sanitize` COMPRESS passes.

## Length budget

| Type      | Body target | Hard cap |
|-----------|-------------|----------|
| feedback  | ≤ 12 lines  | 20       |
| project   | ≤ 15 lines  | 25       |
| semantic  | ≤  8 lines  | 15       |
| reference | ≤  6 lines  | 10       |

Index lines in `MEMORY.md`: ≤ 150 characters per line. Long index hooks bury
the takeaway.

## Keep (the essence)

| Element                  | Length      | Purpose                                                |
|--------------------------|-------------|--------------------------------------------------------|
| Rule statement           | 1 line      | What to do (or not do)                                 |
| Trigger / detection cue  | 1–2 lines   | How a future agent recognises this situation           |
| Why (only if non-obvious)| 1 line      | Skip when the rule is self-explanatory                 |
| How to apply             | 1–3 lines   | Minimal pattern, signature, or command                 |
| Critical caveat          | 1–2 lines   | Gotcha not findable in docs (magic numbers, edge case) |

## Cut (disposable)

- The originating incident ("user reported X after picking a point in Tver, Russia")
  — it's the seed, not the lesson
- Full code blocks when a one-line pattern, signature, or command suffices
- "Where applied: file:line, PR #X" — rots fast, `grep` finds current usage
- Framework-quirk subsections that restate the rule in different words
- Date-bound references ("as of 2026-04-30", commit SHAs, "in version X.Y") —
  rot fast and are rarely load-bearing

## Code blocks

- **One block max** per entry
- ≤ 6 lines
- Only when the pattern cannot be expressed in prose
- No imports, no boilerplate — just the load-bearing call

## Worked example

A 41-line feedback memory about Google Street View pano coverage.

### Before (41 lines — excerpt)

```
Instantiating new google.maps.StreetViewPanorama at coordinates with no Street
View coverage gives a black render with no error — the panorama just stays
blank. This is what the user reported as "the view doesn't work" after picking
a point in Tver, Russia (no Google SV coverage).

Why: Google's API is forgiving by design — it doesn't throw when no panorama
exists at a coordinate; it just renders nothing. UI feedback is the consumer's
job.

How to apply:
[20-line code block with imports, callback boilerplate, snap logic]

50m radius matches what Google Maps' own UI uses when you click on a non-covered
road. Larger radii start grabbing wrong panoramas; smaller radii fail too easily
near the edge of coverage.

Status comparison: use string 'OK' not google.maps.StreetViewStatus.OK — the
local Google Maps .d.ts (apps/web/src/features/map-making/composables/...) doesn't
declare StreetViewStatus as a typed enum...

Where applied: apps/web/src/pages/admin/StreetViewScreenshotPage.vue (PRs #114,
#117). Also wired into the modal picker so picks on uncovered points show
inline error before committing.
```

### After (11 lines)

```
Before `new StreetViewPanorama({position})` or `setPosition()`, snap to the
nearest covered pano. Off-coverage coords render black with no error.

How: call `StreetViewService.getPanorama({location, radius: 50})`. If status
!== 'OK' or data === null → show "no coverage" error and do not instantiate.
Otherwise update your stored lat/lng to `data.location.latLng` before
instantiating.

Caveats:
- 50m matches Google Maps' own snap radius. >50 grabs wrong panos; <50 fails at edges.
- Compare status against string `'OK'`, not `google.maps.StreetViewStatus.OK` —
  the local `.d.ts` doesn't declare it as a typed enum.
```

73% reduction; loses no actionable content. The Tver anecdote, the full code
block, and the PR refs are gone. The 50m magic number and the string-vs-enum
gotcha (the two pieces a future agent could not guess from the API alone)
survive.

## Pre-write consolidation (ADD / UPDATE / NO-OP)

Before writing a new auto-memory file:

1. Read `MEMORY.md` — scan hook lines for keyword overlap with the planned entry
2. For each candidate hit, read the linked file's body
3. Decide:
   - **NO-OP** — an existing memory already covers this. Tell the user
     "Already covered by `{file}` — open it?" and skip writing.
   - **UPDATE** — an existing memory is close but missing this nuance. Propose
     a verbatim diff (new lines to append/insert into the existing file). Do
     not create a new file.
   - **ADD** — truly novel. Write a new file respecting the length budget above.

Never write a new file when an UPDATE fits. Append-style growth is the bloat path.

## Conflict resolution

When two KEEP memories contradict (e.g., one says "always do X", another says
"never do X when Y"):

- Newer wins.
- Older becomes `status: superseded` in its frontmatter, body collapses to a
  single line: `Superseded by [{survivor-filename}](./{survivor-filename}).`
- Remove the older entry from `MEMORY.md`.
- Keep the file on disk as an audit trail.

This is non-destructive: history is preserved, but only the current rule is
indexed and recallable.
