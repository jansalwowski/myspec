# `/myspec:memory-sanitize` — examples

Audits the user-level auto-memory store at `~/.claude-personal/projects/{encoded-cwd}/memory/`. Triages every entry into one of eight buckets (KEEP / DROP-stale / DROP-trivial / DROP-duplicate / PROMOTE / MERGE / COMPRESS / CONFLICT), then drops, promotes, merges, compresses, or supersedes with explicit per-action confirmation. Never touches the project's own `ai/memory/` (myspec system) — that has separate skills.

> **Related**: For *creating* user-level auto-memories, the harness handles that automatically as you work — see the `auto memory` instructions in your system prompt and the project-level rule at `.claude/rules/auto-memory-style.md` (length budget + cut list + pre-write ADD/UPDATE/NO-OP consolidation). For *project-level* memory in `ai/memory/`, use [`/myspec:memory-create`](memorize.md), [`/myspec:memory-lookup`](memory-lookup.md), and [`/myspec:session-clean`](session-clean.md). `memory-sanitize` is the periodic groomer for the *user-level* store only.

**Contents**

- [Routine triage — mixed buckets](#routine-triage--mixed-buckets)
- [Promotion needs a routing decision](#promotion-needs-a-routing-decision)
- [Compressing a bloated entry](#compressing-a-bloated-entry)
- [Resolving a conflict between two KEEP memories](#resolving-a-conflict-between-two-keep-memories)
- [Nothing to do — clean store](#nothing-to-do--clean-store)

---

## Routine triage — mixed buckets

The everyday case: the user hasn't sanitized in a couple of months and the memory dir has grown to a dozen entries of varying quality.

### Setup

User runs the skill from `/Users/jane/public_html/myproj`. The resolved memory dir is `~/.claude-personal/projects/-Users-jane-public-html-myproj/memory/` (note `_` → `-` and `/` → `-`).

`MEMORY.md` lists 12 entries. A representative sample:

| File | Type | Age | Content (excerpt) |
|---|---|---|---|
| `user_role.md` | user | 4mo | Senior backend engineer, deep Go, new to React |
| `feedback_terse.md` | feedback | 3mo | User wants terse responses, no trailing summaries |
| `feedback_no_mocks.md` | feedback | 5mo | Integration tests must hit real DB — Q3 2025 incident |
| `feedback_ask_user.md` | feedback | 2mo | Prefer AskUserQuestion over inline yes/no prompts |
| `project_auth_rewrite.md` | project | 6mo | Auth middleware rewrite driven by legal compliance |
| `project_freeze.md` | project | 4mo | Merge freeze begins 2025-11-15 for mobile cut |
| `reference_linear_ingest.md` | reference | 5mo | Pipeline bugs tracked in Linear project "INGEST" |
| `feedback_use_pnpm.md` | feedback | 1mo | Use pnpm not npm in this repo |
| `feedback_pnpm_only.md` | feedback | 3w | Always pnpm, never npm or yarn — package-lock.json deleted from repo |
| `project_old_oncall.md` | project | 7mo | Alex is oncall for the API team |
| `feedback_test_runner.md` | feedback | 4mo | Use `pnpm test:fast` for the inner loop |
| `user_typescript_strict.md` | user | 3d | User wants `strict: true` everywhere |

There's also a stray file `notes_scratch.md` not linked from `MEMORY.md`.

### Invocation

```
/myspec:memory-sanitize
```

### Skill flow

#### 1. Inventory + integrity

> Resolving memory dir: `~/.claude-personal/projects/-Users-jane-public-html-myproj/memory/`. Reading MEMORY.md and 12 linked entries.

Integrity report:

```
Orphan files (in dir, not in MEMORY.md):
  - notes_scratch.md

Broken links (in MEMORY.md, no file):
  (none)
```

> 1 orphan flagged — will surface in the triage table as ORPHAN, not auto-deleted.

#### 2. Per-entry triage with cheap verifications

| File | Bucket | Cheap check | Reason |
|---|---|---|---|
| `user_role.md` | KEEP | — | Stable user profile, still accurate |
| `feedback_terse.md` | KEEP | — | Output style; project-specific judgment, frequently relevant |
| `feedback_no_mocks.md` | PROMOTE | — | Belongs in `.claude/rules/testing.md` (incident-grounded testing rule) |
| `feedback_ask_user.md` | PROMOTE | — | Belongs in `CLAUDE.md` Core Principles (tool selection) |
| `project_auth_rewrite.md` | KEEP | grep `auth-middleware` → still present in `apps/api/src/auth/` | Compliance context still load-bearing |
| `project_freeze.md` | DROP-stale | date 2025-11-15 in past | Freeze long over |
| `reference_linear_ingest.md` | KEEP | — | External reference, low-cost to retain |
| `feedback_use_pnpm.md` | MERGE | — | Same scenario as `feedback_pnpm_only.md` |
| `feedback_pnpm_only.md` | MERGE | — | Same scenario as `feedback_use_pnpm.md` |
| `project_old_oncall.md` | DROP-stale | grep `Alex` in CODEOWNERS → not present | Personnel change, no longer accurate |
| `feedback_test_runner.md` | KEEP | check `pnpm test:fast` exists in `package.json` ✓ | Still valid |
| `user_typescript_strict.md` | SKIP | mtime 3d ago | Under 7-day floor — too fresh to triage |
| `notes_scratch.md` | ORPHAN | — | Not in MEMORY.md; ask user before touching |

#### 3. Cluster pass

Two pnpm files fire in the same scenario ("user runs a package command") → propose MERGE into a single `feedback_pnpm.md` consolidating both points (use pnpm; never npm/yarn; package-lock.json deliberately removed).

#### 4. Audit report

```
## Memory Sanitize Audit

KEEP (5):
  user_role.md, feedback_terse.md, project_auth_rewrite.md,
  reference_linear_ingest.md, feedback_test_runner.md

DROP-stale (2):
  project_freeze.md          — freeze date 2025-11-15 long past
  project_old_oncall.md      — Alex no longer in CODEOWNERS

PROMOTE (2):
  feedback_no_mocks.md   →   .claude/rules/testing.md (new "Database tests" section)
  feedback_ask_user.md   →   CLAUDE.md > Core Principles (after tool selection bullet)

MERGE (1 cluster):
  feedback_use_pnpm.md + feedback_pnpm_only.md  →  feedback_pnpm.md

SKIP (1):
  user_typescript_strict.md  — mtime 3d ago, under 7-day floor

ORPHAN (1):
  notes_scratch.md  — not in MEMORY.md; needs user decision

Summary: 5 keep, 2 drop, 2 promote, 1 merge cluster, 1 skipped, 1 orphan.
```

#### 5. Confirm and execute

**Drops** (batched, single confirmation):

> Before deleting, grepping repo for live citations…
>
> ```
> grep -r project_freeze.md       → no matches
> grep -r project_old_oncall.md   → no matches
> ```
>
> Both safe. Proceed with 2 deletes? (yes / no / selective)

User: `yes`. Both files removed.

**Promotion 1 — `feedback_no_mocks.md`** (individual confirmation via AskUserQuestion):

> **Source memory** (full text):
>
> ```
> Integration tests must hit a real database, not mocks.
> Why: Q3 2025 incident — mocked tests passed but the prod migration broke. Mock/prod divergence masked it.
> How to apply: in any new test file under apps/api/tests/, wire up a real DB fixture. No jest.mock for the data layer.
> ```
>
> **Destination**: `.claude/rules/testing.md`, after the "## Test scope" section, as a new "## Database tests" subsection.
>
> **Insertion text** (verbatim):
>
> ```markdown
> ## Database tests
>
> Integration tests under `apps/api/tests/` must hit a real database, not mocks. Wire up the real DB fixture; do not `jest.mock` the data layer.
>
> Origin: Q3 2025 incident — mocked tests passed while a prod migration silently broke, because mock/prod divergence masked the failure.
> ```
>
> Apply? (yes / no / edit)

User: `yes`. Skill edits `.claude/rules/testing.md`, deletes `feedback_no_mocks.md`, removes its line from `MEMORY.md`.

**Promotion 2 — `feedback_ask_user.md`**:

> **Source memory**: "Prefer AskUserQuestion over inline yes/no prompts when there's a real branch in behavior."
>
> **Destination**: `CLAUDE.md`, "## Core Principles" section, immediately after the existing "Tool selection" bullet (line 47).
>
> **Insertion text**:
>
> ```markdown
> - When a user decision branches behavior, surface it via the AskUserQuestion tool rather than asking inline. Inline yes/no in chat is fine for confirmation; multi-option decisions should use the tool.
> ```
>
> Apply? (yes / no / edit)

User: `yes`. CLAUDE.md updated, source memory deleted, MEMORY.md re-indexed.

**Merge** — pnpm cluster:

> **Proposed merged file**: `feedback_pnpm.md`
>
> ```markdown
> ---
> name: package manager — pnpm
> description: This repo uses pnpm exclusively; npm and yarn are forbidden
> type: feedback
> ---
>
> Always use pnpm in this repo. Never npm or yarn.
>
> Why: package-lock.json was deliberately deleted — the lockfile is pnpm-lock.yaml. Mixing managers will regenerate the wrong lockfile and break CI.
> How to apply: any time you suggest or run a package command (`install`, `add`, `run`, etc.), use pnpm. Reject the temptation to fall back to `npm install` even when copying example commands from upstream docs.
> ```
>
> **Source files to delete**: `feedback_use_pnpm.md`, `feedback_pnpm_only.md`.
>
> Apply? (yes / no / edit)

User: `yes`. New file written, sources deleted, MEMORY.md updated to point to the merged file.

**Orphan** — `notes_scratch.md`:

> `notes_scratch.md` exists in the dir but is not linked from MEMORY.md. Options: link it (treat as a real memory and re-triage), delete it, or leave alone.

User: `delete`. File removed.

#### 6. Verify

```
$ grep -c '^- \[' MEMORY.md
6
$ ls memory/ | grep -v MEMORY.md | wc -l
6
```

Match. Audit report archived to `~/.claude-personal/projects/-Users-jane-public-html-myproj/memory/audit-2026-05-04.md`.

#### Final summary

> Sanitized: 2 dropped (stale), 2 promoted (CLAUDE.md + .claude/rules/), 2 merged into 1, 1 orphan deleted. 5 kept, 1 skipped (too fresh). MEMORY.md re-indexed; counts match.

### Why this example matters

- **The bucket table is the deliverable.** The user reads it once, decides per-bucket whether to proceed, and then individually approves each promotion and merge. That structure makes the skill safe to run on a stale store full of mixed-quality entries — no "promote everything that looks like a rule" surprises.
- **Promotion shows verbatim text and exact destination.** "Will summarize and add to CLAUDE.md" is unacceptable — the user has to see the literal bytes that will land in the destination file. Otherwise the skill becomes a content-rewriter masquerading as a triage tool.
- **Drop guards are mechanical, not judgment-based.** Repo-wide grep before every delete; refuse if cited. Mtime floor of 7 days. Orphans never auto-deleted. These rails matter precisely because the rest of the workflow is judgment-heavy.
- **The 7-day floor saves new memories.** `user_typescript_strict.md` (3 days old) might look trivial, but the user just saved it — the agent doesn't yet know how it'll be used. Skip and revisit next sweep.

---

## Promotion needs a routing decision

Sometimes a memory is clearly worth promoting but its destination is ambiguous. The skill refuses to guess and reclassifies as KEEP with a flag.

### Setup

A single feedback memory:

```
---
name: tsx-only on the frontend
description: All new frontend files use .tsx, never .jsx
type: feedback
---

All new frontend files must be .tsx. .jsx is banned.
Why: half-typed files were causing import resolution failures in the build.
How to apply: any new file under apps/web/src/ uses .tsx, even if it has no JSX in it yet.
```

The promotion routing table offers two plausible destinations:
- `.claude/rules/frontend.md` (frontend-specific pattern) ✓
- `.claude/rules/lint-and-types.md` (a TS rule) ✓

Both fit. Neither file currently exists in the repo.

### Skill flow (excerpt)

#### Phase 4 audit (excerpt)

```
PROMOTE (1):
  feedback_tsx_only.md  →  AMBIGUOUS

  Routing candidates:
    A) .claude/rules/frontend.md       (does not yet exist)
    B) .claude/rules/lint-and-types.md (does not yet exist)

  Per skill rule: when destination is ambiguous, leave as KEEP and flag. Reclassifying.

KEEP (1, flagged):
  feedback_tsx_only.md  ⚠ promotion deferred — needs human routing decision
```

#### Final summary

> 0 dropped, 0 promoted (1 deferred, ambiguous routing), 0 merged. To resolve: pick one of `.claude/rules/frontend.md` or `.claude/rules/lint-and-types.md`, create it, then re-run sanitize.

### Why this example matters

- **Ambiguity is a signal, not an obstacle.** When two valid destinations both exist for one rule, the agent shouldn't roll dice — it should hand the choice back. The flag stays in the audit log so the user can resolve it deliberately.
- **Reclassification preserves the memory.** A deferred promotion stays a working memory in the meantime; it doesn't get dropped because routing failed.
- **Most-common mis-routing reminder.** The verification checklist explicitly calls out `skill-optimization.md` as a frequent wrong landing zone — it's for skill-*authoring* meta-rules, not arbitrary lint rules. The ambiguity gate exists in part to stop that drift.

---

## Compressing a bloated entry

A KEEP memory whose rule is still correct but whose body exceeds the length budget in `.claude/rules/auto-memory-style.md`. The skill proposes a verbatim rewrite that conforms to the budget.

### Setup

A single feedback memory, 41 lines:

```
---
name: Always snap to nearest panorama before instantiating StreetViewPanorama
description: new google.maps.StreetViewPanorama at off-coverage lat/lng silently renders black
type: feedback
---
Instantiating `new google.maps.StreetViewPanorama({ position: { lat, lng } })` at
coordinates with no Street View coverage gives a **black render with no error** —
the panorama just stays blank. This is what the user reported as "the view
doesn't work" after picking a point in Tver, Russia (no Google SV coverage).

**Why:** Google's API is forgiving by design — it doesn't throw when no panorama
exists at a coordinate; it just renders nothing. UI feedback is the consumer's
job.

**How to apply:**

```typescript
const NEAREST_PANO_SEARCH_RADIUS_METERS = 50

const svc = new google.maps.StreetViewService()
svc.getPanorama(
  { location: { lat, lng }, radius: NEAREST_PANO_SEARCH_RADIUS_METERS },
  (data, status) => {
    if (status !== 'OK' || data === null) {
      // Show user-facing "no coverage" error — DO NOT instantiate panorama at this lat/lng
      return
    }
    const snapped = data.location?.latLng
    if (snapped) {
      lat = snapped.lat()
      lng = snapped.lng()
    }
    // Instantiate / setPano with data.location?.pano
  },
)
```

**50m radius** matches what Google Maps' own UI uses when you click on a non-covered road...

**Status comparison: use string `'OK'` not `google.maps.StreetViewStatus.OK`** — the local Google Maps `.d.ts` doesn't declare `StreetViewStatus` as a typed enum...

**Where applied**: `apps/web/src/pages/admin/StreetViewScreenshotPage.vue` (PRs #114, #117). Also wired into the modal picker...
```

`wc -l` reports 41 lines. Per the style guide, feedback bodies target ≤12 lines (hard cap 20). Triage flags it as **COMPRESS**.

### Skill flow

#### Phase 4 audit (excerpt)

```
COMPRESS (1):
  feedback_streetview_snap_to_pano.md   41 → 11 lines (73% reduction)
    Cuts: originating-incident narrative ("Tver, Russia"), 20-line code block
          (replaced by one-paragraph prose), "Where applied" footer with PR refs.
    Keeps: rule, trigger, snap procedure, 50m magic number, string-vs-enum gotcha.
```

#### Phase 5 confirmation (verbatim rewrite shown inline)

> **Source** (41 lines) — see above.
>
> **Proposed rewrite** (11 lines, verbatim):
>
> ```markdown
> Before `new StreetViewPanorama({position})` or `setPosition()`, snap to the
> nearest covered pano. Off-coverage coords render black with no error.
>
> How: call `StreetViewService.getPanorama({location, radius: 50})`. If status
> !== 'OK' or data === null → show "no coverage" error and do not instantiate.
> Otherwise update your stored lat/lng to `data.location.latLng` before
> instantiating.
>
> Caveats:
> - 50m matches Google Maps' own snap radius. >50 grabs wrong panos; <50 fails at edges.
> - Compare status against string `'OK'`, not `google.maps.StreetViewStatus.OK` —
>   the local `.d.ts` doesn't declare it as a typed enum.
> ```
>
> Apply? (yes / no / edit)

User: `yes`. The file body is replaced in place; the frontmatter `name`/`description` are unchanged; the index hook in `MEMORY.md` is unchanged.

#### Final summary

> Compressed 1 entry, total reduction 73%, store now 779 lines (was 819).

### Why this example matters

- **COMPRESS is exempt from the 7-day age floor.** Rewriting for length is non-destructive — the same rule survives in a shorter form. DROP is the destructive action that needs the floor.
- **The cut list is mechanical, not creative.** The agent removes the originating incident, oversized code block, and "where applied" footer — but it must not reinterpret the rule. If the proposed rewrite changes the *meaning*, the user should reject.
- **The 50m magic number and the string-vs-enum gotcha survive.** Those are the two pieces a future agent could not guess from the API alone. The narrative around them is disposable; they are not.

---

## Resolving a conflict between two KEEP memories

Two memories that contradict are paired in Phase 3. Newer wins; older becomes a one-line stub pointing at the survivor and drops out of `MEMORY.md`. The file stays on disk as an audit trail.

### Setup

Two feedback memories with overlapping triggers:

```
feedback_no_console_log.md         (mtime: 2025-12-10)
  Body: "Never use console.log in this repo. Use console.warn or console.error
        only. Extension code uses debugLogService."

feedback_logging_policy.md         (mtime: 2026-04-22)
  Body: "Use console.warn or console.error only — no console.log, no
        console.info, no console.debug. Extension code uses debugLogService
        (writes to popup debug panel). Server code uses the structured logger
        in apps/api/src/lib/logger.ts; never raw console in API routes."
```

Both fire on "what logger should I use?" — but the newer one is strictly more specific (covers info/debug, calls out the server-side logger). The older one is a subset.

### Skill flow

#### Phase 3 pairing

```
CONFLICT (1 pair):
  feedback_no_console_log.md  (2025-12-10)  ← LOSER (older, less specific)
  feedback_logging_policy.md  (2026-04-22)  ← WINNER (newer, supersedes)

  Resolution: mark feedback_no_console_log.md as superseded, body collapsed.
  Newer is strictly more specific — no information lost.
```

#### Phase 5 confirmation

> **Two contradicting (or one-superseding-the-other) memories:**
>
> [shows both bodies side by side]
>
> **Proposed action:**
> - **Keep**: `feedback_logging_policy.md` (newer, broader)
> - **Supersede**: `feedback_no_console_log.md` — body becomes:
>   ```markdown
>   ---
>   name: superseded
>   status: superseded
>   ---
>   Superseded by [feedback_logging_policy.md](./feedback_logging_policy.md).
>   ```
> - Remove `feedback_no_console_log.md` line from `MEMORY.md`.
> - **The file stays on disk** as audit trail.
>
> Apply? (yes / override winner / no)

User: `yes`. Stub written, `MEMORY.md` updated.

#### Verify

```
$ grep -c '^- \[' MEMORY.md
N-1                          # one entry removed from index

$ ls memory/ | grep -vE '^(MEMORY\.md|audit-)' | wc -l
N                            # file count unchanged — loser still on disk

$ cat memory/feedback_no_console_log.md
---
name: superseded
status: superseded
---
Superseded by [feedback_logging_policy.md](./feedback_logging_policy.md).
```

The mismatch between index count (N-1) and file count (N) is **expected** for superseded files. The verification command in the skill's checklist accounts for this — superseded files don't count toward the active index.

### Why this example matters

- **Newer wins by default, but the user can override.** If the older memory carries more nuance (rare), the user picks "override winner" and the newer one becomes the stub instead.
- **Supersession is non-destructive.** The file stays on disk so future audits can see *what was once believed* and *why it changed*. This matters when the user later wonders "did we used to forbid X?" — the audit trail answers without spelunking through git history.
- **CONFLICT is different from MERGE.** MERGE combines two compatible rules that fire in the same scenario. CONFLICT pairs two **incompatible** rules where only one can be current. Different downstream actions; different bucket.

---

## Nothing to do — clean store

The store has been groomed recently and everything is current. The skill should exit cleanly without inventing work.

### Setup

`MEMORY.md` lists 4 entries, all written or last verified within the last 30 days, all referencing live code or active personnel. No orphans, no broken links.

### Skill flow

```
Resolving memory dir: ~/.claude-personal/projects/-Users-jane-public-html-myproj/memory/.

Reading MEMORY.md and 4 linked entries. No orphans. No broken links.

Triage:

| File                       | Bucket | Reason                                      |
|----------------------------|--------|----------------------------------------------|
| user_role.md               | KEEP   | stable                                       |
| feedback_terse.md          | KEEP   | active output-style preference               |
| project_q2_migration.md    | KEEP   | grep target file → still present             |
| reference_grafana.md       | KEEP   | external reference                           |

Summary: 4 keep, 0 drop, 0 promote, 0 merge, 0 skipped, 0 orphan.

Nothing to sanitize.
```

No prompts, no mutations, no archive report (none warranted).

### Why this example matters

- **A clean store is the goal state, not a failure mode.** The skill is meant to be safe to run on a monthly cron or as part of a "tidy up" habit — most of the time on a well-maintained store, it'll find nothing.
- **Still prints the audit table.** Even with everything in KEEP, the user gets a one-glance view of what was checked. If a future bug ever caused the skill to *not* check a file (silent skip), that file would be missing from the table — and the user would notice.
- **No archive when no actions taken.** The audit report is only written when there's something to remember; otherwise the memory dir would accumulate `audit-*.md` snapshots from every clean run.
