# `/myspec:idea-intake` — examples

Triages a new idea file in `ideas/` into the priority queue (`ideas/PRIORITY-LISTING.md`). The skill validates format, asks priority + dependency questions, and updates the queue. **Always asks clarifying questions** — there's no auto-priority.

**Contents**

- [Standard new idea with clear priority](#standard-new-idea-with-clear-priority)
- [Idea that needs scope clarification](#idea-that-needs-scope-clarification)
- [Idea blocked by unsatisfied dependencies](#idea-blocked-by-unsatisfied-dependencies)

---

## Standard new idea with clear priority

The base case: a small, well-scoped idea that the user knows they want soon.

### Setup

The user dropped a quick file at `ideas/keyboard-shortcut-help.md`:

```markdown
# Keyboard shortcut help overlay

Press `?` to bring up an overlay listing all available keyboard shortcuts in the current page. priority HIGH

depends on: nothing
```

### Invocation

```
/myspec:idea-intake keyboard-shortcut-help
```

### Skill flow

#### 1. Read

The skill reads `ideas/keyboard-shortcut-help.md` and `ideas/PRIORITY-LISTING.md`. Notes:

- Priority: HIGH (specified inline).
- Dependencies: none specified.
- Scope: clear — single overlay, single trigger key.

#### 2. Clarifying questions

Even with everything specified, the skill asks one or two:

> Quick checks:
>
> 1. Should the shortcut list be **dynamic** (auto-discovered from registered shortcuts) or **static** (manually curated per page)?
> 2. Any features in flight that this should wait for, or is it standalone?

**User**: dynamic; standalone.

#### 3. Validate format

The idea file has the minimum (title, description, priority, deps). The skill leaves it as-is.

#### 4. Update queue

Edits `ideas/PRIORITY-LISTING.md`:

```markdown
## HIGH

- [ ] **keyboard-shortcut-help** — `?` overlay listing keyboard shortcuts on the current page (dynamic, auto-discovered).
  - Depends on: (none)
  - Notes: standalone, can ship independently.
```

The skill ends:

> Added to HIGH priority queue. Run `/myspec:idea-process` when ready to convert it to a feature spec.

### Why this example matters

- **Even "complete" ideas get one or two questions.** The dynamic-vs-static question is a behavioral fork the idea file didn't address — answering it before queueing prevents `idea-process` from re-asking later.
- **Notes column captures the standalone signal.** `idea-process` uses this to know it can pick this idea even when other dependencies are unmet.

---

## Idea that needs scope clarification

The user wrote down something that's actually three ideas. The skill flags it.

### Setup

User added `ideas/dashboard-improvements.md`:

```markdown
# Dashboard improvements

Make dashboards better. Specifically:
- Drag-to-rearrange widgets
- Custom color themes
- Public sharing via link

priority MEDIUM
```

### Invocation

```
/myspec:idea-intake dashboard-improvements
```

### Skill flow

#### 1. Read + analyze

The skill notices three distinct capabilities, each with different effort and risk:

- **Drag-to-rearrange** — UI-only, contained.
- **Custom color themes** — UI + persistence, theming system.
- **Public sharing** — auth-bypass routes, security review, abuse prevention.

#### 2. Scope question

> This file lists three distinct capabilities, each with different scope and risk. Should it be:
>
> 1. **Single idea** — process together as one big feature (will likely need decomposition later).
> 2. **Staged idea** — keep one entry but plan to ship in phases at different priorities.
> 3. **Split into three idea files** — track each independently in the queue.
>
> Especially worth flagging: **public sharing** has security implications (auth bypass routes, share-link abuse) that deserve their own treatment. Drag-to-rearrange is much smaller.

**User**: split into three.

#### 3. Splitting

The skill creates:

- `ideas/dashboard-rearrange.md` — extracted from the original.
- `ideas/dashboard-themes.md`
- `ideas/dashboard-public-sharing.md`

Each gets its own priority question:

- Rearrange → MEDIUM (matches original).
- Themes → LOW (nice-to-have).
- Public sharing → MEDIUM but flagged for security review.

The original `dashboard-improvements.md` is **archived** to `ideas/_archive/dashboard-improvements-split-2026-04-30.md` with a note pointing at the three new files.

#### 4. Update queue

Three new rows in `PRIORITY-LISTING.md`:

```markdown
## MEDIUM
- [ ] **dashboard-rearrange** — Drag-to-rearrange widgets on dashboards.
- [ ] **dashboard-public-sharing** — Public share links for dashboards. **Needs security review before processing.**

## LOW
- [ ] **dashboard-themes** — Custom color themes per user.
```

### Why this example matters

- **The skill rebuts the "one big idea" temptation.** A user dumping a brainlist into one file is fine for capture — but the queue needs them split for prioritization to be meaningful.
- **Security concerns get a flag, not just a different priority.** The note on `dashboard-public-sharing` ensures `idea-process` later asks the right questions (and likely routes to a different reviewer).
- **The original file is archived, not deleted.** History matters for "why are these three in the queue?" archaeology a year from now.

---

## Idea blocked by unsatisfied dependencies

A clean idea that can't actually be queued at HIGH because something it depends on isn't done.

### Setup

User added `ideas/scheduled-bulk-export.md`:

```markdown
# Scheduled bulk export

Combine scheduled-reports + bulk-export so users can schedule a recurring CSV
of multiple reports' data, delivered as a single archive.

priority HIGH
depends on: scheduled-reports, bulk-export
```

### Invocation

```
/myspec:idea-intake scheduled-bulk-export
```

### Skill flow

#### 1. Read

The skill reads the file and the priority listing. Then checks the manifest at `ai/features/index.yaml`:

- `scheduled-reports`: status `complete` ✓
- `bulk-export`: **not found** in manifest. Searched `ideas/PRIORITY-LISTING.md` — present, status `[ ]` HIGH, untouched.

#### 2. Dependency question

> Dependency status:
>
> - `scheduled-reports` — shipped, ready to depend on. ✓
> - `bulk-export` — listed in your idea queue at HIGH but not yet processed (no feature spec). This idea can't be processed until bulk-export is at least a draft feature.
>
> Two options:
>
> - **A) Queue at HIGH, with note** — explicit dependency on bulk-export. `idea-process` will refuse until bulk-export is processed first.
> - **B) Queue at lower priority (MEDIUM)** — reflects the practical timeline: nothing happens here until bulk-export ships.
> - **C) Hold off** — don't queue yet. Re-run intake after bulk-export progresses.

**User**: A — queue at HIGH but note the blocker.

#### 3. Update queue

```markdown
## HIGH

- [ ] **scheduled-bulk-export** — Recurring scheduled archive of multiple reports' CSV data.
  - Depends on: scheduled-reports ✓ (shipped), **bulk-export ✗ (queued idea, not yet processed)**
  - Notes: `idea-process` will refuse this until bulk-export is at least a draft feature spec.
```

The skill ends:

> Queued. Note the explicit blocker — work on `bulk-export` first, then this becomes processable.

### Why this example matters

- **Dependency awareness is automatic.** The skill cross-references the manifest and the queue to know what's actually shippable. Without this, ideas pile up at HIGH that can't be acted on.
- **The notes column documents the blocker visibly.** `idea-process` reads this when it picks the next `[ ]` item — a blocked idea gets skipped with a clear reason, not silently held.
- **HIGH priority + explicit blocker is a valid combination.** It's saying "this is important once unblocked." That's different from "this is doable now."
