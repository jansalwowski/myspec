---
name: "update"
description: "Use when an existing project's myspec framework files need refreshing after the plugin updated. Keywords: upgrade framework, sync framework files. Do NOT use for first-time setup (init)."
---

# Update

**Announce at start:** "Updating myspec framework files."

Updates framework-owned files in an existing project while preserving project customizations.

## Prerequisites

- `.myspec.json` exists in project root (project is initialized)
- myspec plugin has been updated in the host tool

→ If `.myspec.json` does not exist: stop and tell user to run the `init` skill first.

## Workflow

### Step 1: Read Current Version

Read `.myspec.json` from project root. Extract `frameworkVersion` and `aiDir`.

Read `framework-files/manifest.json` from the plugin directory. Extract `frameworkVersion`.

Resolve the plugin directory in this order:
1. `$CLAUDE_PLUGIN_ROOT` if set.
2. The directory containing this `SKILL.md`, walking up until a sibling `framework-files/manifest.json` is found (typically `…/myspec/{version}/framework-files/manifest.json`).
3. If neither resolves, stop and tell the user: "Cannot locate plugin manifest. Verify the myspec plugin is installed."

Compare versions. If they match, tell the user: "Already up to date (v{version}). No changes needed." and stop.

**Upgrade base.** 2.0 migrates from 1.28.0 or later only. If the project's `frameworkVersion` is missing or lower than 1.28.0, stop with:

"This project is on v{version}; myspec 2.0 upgrades from 1.28.0 or later. Run the 1.28 update first: check out the plugin at tag v1.28.0 (`git clone --branch v1.28.0 https://github.com/jansalwowski/myspec`), start Claude with `--plugin-dir <that checkout>`, run `/myspec:update`, then return to this version."

The 1.x updates carried migrations (legacy memory-index headers, hand-written `frameworkFiles` inventories) that 2.0 no longer ships.

### Step 1.5: Run One-Shot Migrations

`manifest.json` lists `migrations`, the one-shot moves this version of the framework needs; `.myspec.json` lists the ones already applied under `migrations`. Run each manifest entry the project has not recorded, in manifest order, and append its id to `.myspec.json` `migrations` the moment it completes — so an interrupted run resumes where it stopped and a re-run is a no-op. Never run one twice. A project without a `migrations` key has run none.

| id | What it does |
|---|---|
| `2.0.0-schema` | **`aiDir`:** if the key is missing, decide once from disk — `.ai` if `.ai/` exists, else `ai` if `ai/` exists, else `.ai` — and write it; strip any trailing slash. This replaces the runtime detection the 1.x hooks carried, so it lands before any hook runs against the new lib. **`frameworkFiles`:** drop `version` and `lastUpdated` from every entry (bookkeeping nothing ever read); drop entries left empty; drop the key when no pins remain. Since 2.0 the block holds pins only. |
| `2.0.0-doctor-rule` | `.claude/rules/ai-setup-audit.md` → `.claude/rules/doctor.md` via `git mv` when only the old name exists (the `doctor` skill reads only the new one). Both present → leave both, report it, and tell the user to merge by hand. |
| `2.0.0-sessions` | Live session logs move from `{aiDir}/memory/sessions/active/` to `.claude/state/sessions/` in the primary checkout (gitignored). Move every `*.md` there with plain `mv` (they were never tracked), delete `active/` and its `.gitkeep` (`git rm` if tracked), leave `archive/` where it is. A 1.x log lacks a `## Files touched` section; the hook adds it on the next edit. |
| `2.0.0-base-agents` | The user-scope `worker-base` / `reviewer-base` subagents backed the orchestrator agent-chain mode, retired in 2.0. For each of `~/.claude/agents/`, `~/.cursor/agents/`, `~/.codex/agents/` that exists, list the `worker-base.{md\|toml}` and `reviewer-base.{md\|toml}` files present and ask once: "Delete these N files? They are inert since 2.0. (y/n, default: n)". On `n`, leave them and say so. Delete nothing else in those directories, and never touch project-scope agent dirs. |

List every migration run under `Migrations` in the Step 6 summary.

### Step 2: Inventory Files to Update

From `manifest.json`, collect all files. Each file has a `type`:

- **`overwrite`** — replace the destination file entirely with the plugin's version
- **`marker-merge`** — replace the framework-owned region (line 1 through `<!-- myspec:framework-end -->`), preserving the project section after it

For `files` entries: destination is `{aiDir}/{filename}` — **except** `templates/{name}` entries, which install to `{aiDir}/.templates/{name}` (the dot-directory `init` creates; skills read templates from there — never create `{aiDir}/templates/`).
For `rules` entries: source is `framework-files/rules/{filename}`, destination is the `dest` path (e.g., `.claude/rules/workflow.md`).
For `hooks` entries: source is `hooks/{filename}`, destination is the `dest` path (e.g., `.claude/hooks/guard-worktree-context.sh`).
For `lib` entries: source is `lib/{filename}`, destination is the `dest` path (e.g., `.claude/lib/path-normalize.sh`).

**Renamed entries — migrate the destination before applying.** A `files` or `rules` entry may carry `renamedFrom: "<old key>"`. It means the framework changed a file's name, and the project on disk still holds the old one. Before applying such an entry:

1. If the new destination exists → nothing to migrate; apply the entry normally.
2. If it does not exist and the old destination does → `git mv` (or plain move) the old file to the new name **and** rename its `.myspec.json` `frameworkFiles` key in place if one exists, keeping any `pinned` value. Then apply the entry to the renamed file, so a `marker-merge` merges into the project's real content instead of a fresh copy. List it under `Renamed` in the Step 6 summary.
3. If neither exists → create from source as usual. If `.myspec.json` still carries the **old** key (a project that renamed by hand and pinned the old name so update would stop recreating it), drop that key and report "already renamed locally".
4. If **both** exist → the project renamed by hand before the framework carried the rename. Show the project section of each (everything after `<!-- myspec:framework-end -->`) and offer to append the old file's project section to the new file's, then delete the old file and drop its key. On decline, leave both untouched and report it; the doctor keeps naming the pair as `framework-renamed` until one goes. Never merge unasked: only the user knows which one their blueprints wrote to.

Skipping step 2 is what makes this dangerous: `overwrite`/`marker-merge` both treat a missing destination as "create from source", so the entry would land a *fresh empty-project-section* file beside the real one, and every blueprint that writes to the new name would write to the empty duplicate.

Never invent a `renamedFrom`; it comes from the manifest only. A pinned renamed entry is still renamed — move the file and the key, then skip the content apply.

**Pinned files — skip, never overwrite.** A project may carry a locally-customized copy of a framework file. `.myspec.json` records that as `frameworkFiles["<manifest key>"].pinned`, whose value is a short reason string. Before applying any entry, look up its key (`rules/workflow.md`, `hooks/guard-worktree-context.sh`, `lib/branch-cleanup.sh`, `templates/session-log.md`, …) and skip it if `pinned` is set. Collect these for the summary.

Without this, a sync silently reverts local edits: the file carries no marker distinguishing "customized" from "stale", so `overwrite` treats deliberate local content as drift. That has happened — a sync reverted four rules whose upstream copies had not changed at all, costing ~690 tokens of always-loaded context until it was noticed.

Pinning is the project's call, not the skill's. Never add or remove a pin on the project's behalf; report pinned files and let the user decide whether the local reason still holds.

**Pin reconciliation.** A pinned rule never receives the plugin copy, so a pin taken to trim always-loaded context outlives the trim upstream. When a pinned entry's plugin copy is now *smaller* than the local one (`wc -c` both), the reason for the pin has probably been absorbed: show both sizes and the pin reason, and ask — keep the pin, take the plugin copy and drop the pin, or see a diff first. Apply the answer; never decide alone. Report the outcome under `Pinned` in the Step 6 summary.

**Removed entries — delete, then unwire.** The manifest's `removed` block lists files the framework retired: `"<old key>": { "dest": "<path>", "since": "<version>" }`. For each, when `dest` exists (after `${aiDir}` substitution): `git rm` it if tracked, else delete it; drop its `frameworkFiles` key; and when `dest` is under `.claude/hooks/`, delete every `settings.json` hook entry whose `command` names it (Step 3 owns the rest of the wiring). A pinned entry is a deliberate local keep — leave the file and the pin, report it as "retired upstream, kept locally". List deletions under `Removed` in the Step 6 summary.

For `hooks` and `lib`: only process if `.claude/hooks/` directory exists (hooks and their helper lib travel together). If it doesn't exist, skip all hooks AND lib entries and note: "Hooks directory not found — skipping Claude hook + lib updates. Run the `init` skill with Claude hooks enabled to set them up."

### Step 3: Apply Updates

For each file in the manifest:

**`overwrite` strategy:**
1. Read the source file from `framework-files/{filename}` (or `framework-files/rules/{filename}` for rules, `hooks/{filename}` for hooks, `lib/{filename}` for lib)
2. **`files` and `rules` only:** replace `${aiDir}` placeholders with the configured `aiDir` value. **Copy `hooks` and `lib` byte-for-byte** — see the rule below
3. Write to destination, replacing the existing file entirely
4. For hooks and lib: run `chmod +x {dest}` after writing. Some helpers are sourced and some are invoked directly (`branch-cleanup.sh`, `memory-claim-id.sh`) — setting the bit on all of them is harmless for the sourced ones and required for the rest.

**`marker-merge` strategy:** the file has two regions. Everything from line 1 through `<!-- myspec:framework-end -->` — frontmatter, title, standing note, and the marked framework section — is framework-owned; everything after the end marker is the project section and is never touched.
1. Read the source file from `framework-files/{filename}` and replace `${aiDir}` placeholders
2. Read the destination file and locate `<!-- myspec:framework-end -->`
3. Write the source's framework-owned region (line 1 through its own end marker) followed by the destination's project section, unchanged
4. If the destination has no end marker, stop for that file and report it (the doctor names it `marker-missing`); do not guess where the project section starts

Before 2.0 only the marked section was framework-owned, so a title or note corrected upstream never reached an existing project (#55). Owning the header is what fixes that; a project that wants its own wording pins the file.

If a destination file doesn't exist for `marker-merge`, create it from the source (treat as overwrite for missing files).

**Hook wiring (only if hooks were processed).** Copying a hook file does nothing until it is registered in `.claude/settings.json`, and a registered hook without `+x` never runs either. Since 2.0 `update` owns the `hooks` key of that file — and only that key. Run:

```bash
node .claude/lib/setup-doctor.mjs --plugin-root "${CLAUDE_PLUGIN_ROOT}" wiring
```

For each `wiring-incomplete` finding, add the entry from `templates/settings-hooks.json` under the same event (deep-merge: append to the existing array for that event and matcher, create the event when absent, match existing entries by `command`). For each hook deleted by a `removed` entry, delete its `command` entries. If the file has no `hooks` key, add the template's whole block. Never add, remove, or reorder anything outside `hooks`, and never touch `settings.local.json`. Re-run the same command afterwards: `wiring-incomplete` must be gone; report what remains (`hook-not-executable`, `hook-syntax`) with the `run:` line it carries.

If the doctor is not on disk yet (this run is what installs it), do the comparison by hand this once: for each `command` in the template, check whether that exact string appears under the project's `settings.json` `hooks` key, and add the absent ones.

### Step 3.6: Check memory health

Only when lib entries were processed and `{aiDir}/memory/` exists. Since v1.23.0 the index tables are generated from the memory files, and `memory-claim-id.sh` refuses to allocate IDs until the doctor passes — so never skip this.

1. Verify the indexes — must print `memory indexes are up to date`:
   ```bash
   node .claude/lib/memory-index.mjs --check
   ```
   `stale` → regenerate with `node .claude/lib/memory-index.mjs`. Refused because a memory lacks `hook:` → run `node .claude/lib/memory-index.mjs --backfill --dry-run`, show the output (`from heading (review)` means the H1 became the hook — list those for the user to review), apply with `--backfill`, then re-check.
2. Health:
   ```bash
   node .claude/lib/memory-doctor.mjs
   ```
   Report its summary line in Step 6. Remaining errors (duplicate IDs across branches, malformed anchors) are project content: list them, do not fix them silently.
3. Ensure `.gitignore` contains a `.claude/state/` line — the ID registry is per-checkout state and must never be committed. Append it if missing (create `.gitignore` if absent).

If `node` is unavailable, print: "Memory health check skipped — node not found. Run `node .claude/lib/memory-index.mjs --check` when it is available; ID allocation is blocked until the doctor passes."

### Step 3.7: Verify the install

Everything above wrote files; this reads them back. Run the full doctor from the project root:

```bash
node .claude/lib/setup-doctor.mjs --plugin-root "${CLAUDE_PLUGIN_ROOT}"
```

Step 5 is about to stamp `frameworkVersion` to the new version, so run this **before** it — while the versions still differ, content drift is reported as a warning ("update pending"). After the stamp the same drift is an error, which is the point: a `framework-drift` or `framework-missing` error on the next run means this update half-applied.

Read the result as a checklist of this run:

- `framework-missing` / `framework-drift` → a manifest entry did not get written. Re-apply that entry, do not stamp over it. For a `marker-merge` file this covers the header above the start marker too: the framework-owned region is line 1 through the end marker.
- `marker-missing` → a `marker-merge` file lost its `<!-- myspec:framework-start -->` / `<!-- myspec:framework-end -->` markers; restore them from the plugin copy before the next update silently skips the file forever.
- `shipped-drift` / `shipped-missing` on `.claude/hooks/*` or `.claude/lib/*` → a hook or helper is stale or absent; these are `overwrite` entries, so re-copy.
- Anything in the `schema` or `features` group → fix before finishing; an unparseable `.myspec.json` or `verification.json` silently disables the surfaces that read it, and an entry the features parser cannot read is invisible to every status audit.

Report the summary line in Step 6. `myspec-schema-stale` cannot appear here: Step 1.5 ran the schema migration first. If it does, that migration did not complete — re-run it before stamping.

### Step 4: Refresh `${aiDir}` binding in project context

Skills written in v1.10.0+ reference `${aiDir}/...` as a placeholder. Ensure the project's always-loaded context defines it. Determine target file:

- If `AGENTS.md` exists at project root: target it.
- Else if `CLAUDE.md` exists at project root: target it.
- Else: create `AGENTS.md` at project root.

Append (or replace, if a marker section already exists) this block:

```markdown
<!-- BEGIN myspec:paths -->
## myspec paths

Skill instructions reference `${aiDir}/`. Resolve to **`{aiDir}/`** (configured in `.myspec.json`).
<!-- END myspec:paths -->
```

If the markers already exist, replace everything between them with the current value. Do not modify content outside the markers.

### Step 5: Update `.myspec.json`

Update `frameworkVersion` to the new version from `manifest.json`. Nothing else changes here: `frameworkFiles` holds pins only, and Step 1.5 recorded the migrations as they ran.

### Step 6: Print Summary

```
✅ myspec updated to v{newVersion}

Updated files:
  {list each file updated, with strategy used}

Renamed (framework changed the filename; project content preserved):
  {for each renamedFrom entry migrated: "{old} → {new}"; or omit the block}

Migrations (one-shot, recorded in .myspec.json):
  {each migration id run this time with one line of what it did; or "none pending"}

Removed (retired by the framework):
  {each deleted file; "kept locally (pinned)" for pinned ones; or omit the block}

Preserved (project-customized sections):
  {list marker-merge files where project content was kept}

Pinned (skipped — locally customized):
  {list each pinned file with its reason, or "none"}

Hooks: {updated N scripts / skipped — hooks directory not found}
Lib:   {updated N helpers / skipped — hooks directory not found}
Hook wiring: {all N hooks already wired / added M entries, removed K / N finding(s) remain — see above}
Memory: {indexes up to date / regenerated N, backfilled M hook: lines (K from heading — review) / skipped — no memory tree}
        doctor: {clean / N error(s), M warning(s) — see above}
Setup:  {clean / N error(s), M warning(s) — see above / skipped — node not found}

Next: Run the `bootstrap` skill to verify the setup is still correct.
```

**2.0 advisory (print only when a `2.0.0-*` migration ran in this session).** The
mechanical work is done; what remains lives in files this skill is forbidden to
touch. Append:

```
2.0 changed things update cannot fix for you:
  - references to `{aiDir}/memory/sessions/active/` in your own hooks and docs
  - references to the renamed skills: features-status-audit, worktree-cleanup,
    docs-sanitize
  - plans written under 1.x: implementers no longer run tests, so any
    "Run test — expect FAIL" step now has no owner
  Full list, with the greps: docs/upgrading-to-2.0.md in the plugin.
```

Print it once, after the summary, and do not act on any of it — each item is a
judgment call in a file the project owns.

**Generated-config advisory (print only when `.myspec.json` has a `mockups` block):** blueprint-generated files are project-owned and never auto-updated. Read `{aiDir}/conventions/mockup-design.md` frontmatter `myspec_version` (treat a missing key as "unstamped") and append to the summary:

```
Generated config (project-owned, not auto-updated):
  {aiDir}/conventions/mockup-design.md — generated by myspec v{myspec_version | "unstamped"}, plugin now v{newVersion}.
  If release notes since then mention the mockup surface, re-run /myspec:setup mockup
  (it prompts before overwriting; port the Repeated user feedback log forward).
```

Do NOT modify the file — this is advisory only.

## Rules

- **Never substitute `${aiDir}` into a `hooks` or `lib` entry.** Those files resolve `aiDir` at runtime and carry `${aiDir}` as live shell and JS template-literal syntax — `lib/setup-doctor.mjs` alone has eight, including its destination-path computations. Substituting freezes every path to this project's value at install time and leaves helpers ignoring their own `aiDir` argument (`memoryFilesInRefs(root, aiDir)` stops reading its parameter). The corruption is silent: within one project the frozen value is correct, so nothing misbehaves until the value changes. Only the `files` and `rules` blocks carry `${aiDir}` as a placeholder.
- Never overwrite a file whose `frameworkFiles[...].pinned` is set, and never add or clear a pin yourself
- Never overwrite content after `<!-- myspec:framework-end -->` in a `marker-merge` file
- Never modify files not listed in `manifest.json`, with two exceptions this skill owns: the `hooks` key of `.claude/settings.json`, and `.claude/rules/ai-setup-audit.md` for the `2.0.0-doctor-rule` migration
- Never update `.myspec.json` project fields (`name`, `description`, `techStack`); `aiDir` is written only by the `2.0.0-schema` migration, and only when absent or carrying a trailing slash
- Never run a migration whose id is already in `.myspec.json` `migrations`; record each one the moment it completes
- If a source file is missing from the plugin, skip it and warn the user — do not delete the destination
- The plugin ships no subagent definitions. Never write to `~/.{harness}/agents/` outside the `2.0.0-base-agents` migration, and never to project-scope `.claude/agents/`, `.cursor/agents/`, `.codex/agents/`.

## Verification Checklist

After running the skill:

- [ ] `.myspec.json` `frameworkVersion` read and compared to `manifest.json`; stopped early if already current, or with the 1.28 instruction if below 1.28.0
- [ ] Every manifest `migrations` id not yet in `.myspec.json` run in order and recorded as it completed
- [ ] Every `manifest.json` entry processed with its declared strategy (`overwrite` / `marker-merge`)
- [ ] Every entry carrying `renamedFrom` checked before applying: destination migrated and its `frameworkFiles` key renamed, a dead old key dropped, or the both-exist case offered a merge
- [ ] Every `removed` entry deleted (or kept when pinned) and, for hooks, unwired from `settings.json`
- [ ] Entries pinned in `.myspec.json` skipped and listed in the summary; every pin whose plugin copy is now smaller than the local one offered the keep / take / diff choice
- [ ] `templates/*` entries written to `{aiDir}/.templates/` (no `{aiDir}/templates/` created)
- [ ] `marker-merge` files: everything after `<!-- myspec:framework-end -->` left untouched; the region above it taken from the plugin copy
- [ ] `hooks` and `lib` entries processed only when `.claude/hooks/` exists (else both skipped with the note)
- [ ] Each updated hook and lib helper had `chmod +x` applied, and was written byte-for-byte with no `${aiDir}` substitution
- [ ] Memory health checked when a memory tree exists: `--check` clean (after regeneration or backfill where needed), doctor summary reported, `.claude/state/` gitignored
- [ ] `${aiDir}` binding refreshed between `myspec:paths` markers; content outside markers unchanged
- [ ] `.myspec.json` `frameworkVersion` bumped; project fields (`name`, `description`, `techStack`) untouched; `frameworkFiles` holds pins only
- [ ] Hook wiring run via `setup-doctor.mjs wiring` (or by hand when the doctor was not yet installed): missing template entries added and removed hooks unwired under `settings.json` `hooks`, nothing else in that file touched, `wiring-incomplete` gone on re-run
- [ ] Full `setup-doctor.mjs` run in Step 3.7, before the Step 5 version stamp; every `install`-, `schema`- and `features`-group error resolved or reported
- [ ] No file outside `manifest.json` was modified, except `settings.json` `hooks` and the doctor-rule rename
- [ ] Summary printed with `Updated files`, `Migrations`, `Removed`, `Preserved`, `Hooks`, `Lib`, and `Hook wiring` lines
- [ ] Generated-config advisory printed when a `mockups` block exists (`mockup-design.md` read, never modified)
- [ ] 2.0 advisory printed when a `2.0.0-*` migration ran this session, pointing at `docs/upgrading-to-2.0.md`; nothing it names was acted on
