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

A step that names a `references/` file reads it only when its condition holds; the no-op path reads none. Those files write the plugin's lib directory as `<plugin lib>`: it is `${CLAUDE_PLUGIN_ROOT}/lib`.

### Step 0: Preflight

Two checks before anything is read or written:

1. **Host floor** (README "Installation" has the why): Claude Code 2.1.288 or later (`claude --version`; the `myspec:probe-executor` agent's `disallowedTools`, enforced by name in agent teams from 2.1.288) and git 2.31 or later (`git --version`; the memory scripts). When either is older, stop with: "myspec 3.0 needs Claude Code ≥ 2.1.288 and git ≥ 2.31 (found {versions}). Update the host first."
2. **No session in flight.** Print, once: "Finish open sessions before updating: in-flight 2.x session state is not imported." (`docs/stop-gate.md`, "Session writes": the 2.x ledger and markers are read by nothing in 3.0; `/myspec:session-complete` closes a session cleanly, and the leftover files are deleted by hand.)

### Step 1: Read Current Version

Read `.myspec.json` from project root. Extract `frameworkVersion` and `aiDir`.

Read `framework-files/manifest.json` from the plugin directory. Extract `frameworkVersion`.

Resolve the plugin directory in this order:
1. `$CLAUDE_PLUGIN_ROOT` if set.
2. The directory containing this `SKILL.md`, walking up until a sibling `framework-files/manifest.json` is found (typically `…/myspec/{version}/framework-files/manifest.json`).
3. If neither resolves, stop and tell the user: "Cannot locate plugin manifest. Verify the myspec plugin is installed."

Compare versions. If they match, run Step 3.5 alone (rows an earlier update was told "Not now" are offered again), then tell the user "Framework files already up to date (v{version})." followed by its `Mockups` line, and stop.

**Upgrade base.** The manifest's `upgradeFrom` is the oldest version this plugin migrates from, and `upgradeChain` lists the earlier majors' floors (RELEASING.md, "Upgrade base"). Run `node "${CLAUDE_PLUGIN_ROOT}/lib/upgrade-route.mjs" --version "<project frameworkVersion>"` (empty when none is recorded). Exit 0 → continue. Exit 3 → stop and print its stdout verbatim: it names every release to update through, oldest first, so the user never learns the route one refusal at a time. Any other exit (2 is a bad manifest or version; 1 is Node itself failing, e.g. a missing script) → stop, tell the user the upgrade floor check could not run and quote its stderr. Never continue the update without a 0, and never print a non-3 output as the route.
Every migration, rename and removal an older version needed ran in that update; this plugin no longer ships them.

### Step 1.5: Run One-Shot Migrations

`manifest.json` lists `migrations`, the one-shot moves this version of the framework needs; `.myspec.json` lists the ones already applied under `migrations`. A project without a `migrations` key has run none. For each manifest id the project has not recorded, in manifest order, read its own file in [references/migrations/](references/migrations/), `<id>.md`, do what it says, check its *Done when* line, and append the id to `.myspec.json` `migrations` the moment it completes, so an interrupted run resumes where it stopped and a re-run is a no-op. Never run one twice. When every id is recorded, read none of them.

List every migration run under `Migrations` in the Step 6 summary.

### Step 1.6: Ask the visual-questions setting

When `.myspec.json` has no `visualQuestions` key, run the `setup` skill with blueprint `visual-questions`; either answer records the key, so it is asked once per project. Ask before Step 2: the key decides whether the conditional `visual-questions.md` rule applies. A key already set is left alone.

### Step 2: Inventory Files to Update

From `manifest.json`, collect all files. Each file has a `type`:

- **`overwrite`** — replace the destination file entirely with the plugin's version
- **`marker-merge`** — replace the framework-owned region (line 1 through `<!-- myspec:framework-end -->`), preserving the project section after it

A `files` entry installs to `{aiDir}/{filename}`, except `templates/{name}`, which goes to `{aiDir}/.templates/{name}` (never create `{aiDir}/templates/`). A `rules` entry's source is `framework-files/rules/{filename}` and its destination is its `dest`.
**Conditional entries.** A `files` or `rules` entry may carry `when: {"<setting key>": <value>, …}`. It applies only while every named setting has that effective value, schema defaults included: run `node "${CLAUDE_PLUGIN_ROOT}/lib/myspec-config.mjs" when '<the entry's when, as JSON>'` from the project root, which prints `true` or `false`. `true` → the entry is processed like any other (rename, pin, apply, hash). `false` → it is not installed: when its `dest` exists, delete it (`git rm` if tracked) and list it under `Removed`, unless it is pinned, in which case leave the file and the pin and report it as "condition off, kept locally".
There are no `hooks` or `lib` entries since 3.0: the plugin runs its hooks and lib from its own directory, and `frameworkVersion` covers the `files` and `rules` blocks only.

**Renamed entries — migrate the destination before applying.** Run `node "${CLAUDE_PLUGIN_ROOT}/lib/manifest-keys.mjs" renames` from the project root: one tab-separated row per manifest entry carrying `renamedFrom` (old key, old destination, new key, new destination; the old key may be in the other block). A row whose old destination exists, or whose old key is in `.myspec.json` `frameworkFiles`, needs a migration before its entry is applied: read [references/renames.md](references/renames.md) and do it. Any other row needs nothing. Skipping it would land a fresh copy beside the project's real file, because `overwrite` and `marker-merge` both treat a missing destination as "create from source".

**Pinned files — skip, never overwrite.** `.myspec.json` `frameworkFiles["<manifest key>"].pinned` (a reason string) marks a locally customized copy (`rules/workflow.md`, `templates/session-log.md`, …). Skip every pinned entry and list it in the summary. When `frameworkFiles` holds any pin, read [references/pins.md](references/pins.md) after the renames and run its pin reconciliation.

**Removed entries.** The manifest's `removed` block lists files the framework retired: `"<old key>": { "dest": "<path>", "since": "<version>" }`. When any entry's `dest` exists (after `${aiDir}` substitution), read [references/removed.md](references/removed.md) and act on those entries; otherwise there is nothing to do.

### Step 3: Apply Updates

For each file in the manifest whose `when` holds (Step 2, "Conditional entries"):

**`overwrite` strategy:**
1. Render the source file `framework-files/{filename}` (or `framework-files/rules/{filename}` for rules) with `node "${CLAUDE_PLUGIN_ROOT}/lib/aidir-render.mjs" <source>` from the project root. It replaces each `${aiDir}` with the configured value and turns `$${aiDir}` into a literal `${aiDir}`; never substitute by hand, since the doctor and pin-reconcile compare against this output.
2. Write the output to the destination, replacing the existing file entirely

**`marker-merge` strategy:** the file has two regions. Everything from line 1 through `<!-- myspec:framework-end -->` — frontmatter, title, standing note, and the marked framework section — is framework-owned; everything after the end marker is the project section and is never touched.
1. Render the source file `framework-files/{filename}` with `lib/aidir-render.mjs`, as for `overwrite`
2. Read the destination file and locate `<!-- myspec:framework-end -->`
3. Write the source's framework-owned region (line 1 through its own end marker) followed by the destination's project section, unchanged
4. If the destination has no end marker, do not guess where the project section starts: read [references/marker-less.md](references/marker-less.md) and ask its replace / prepend / pin question.

If a destination file doesn't exist for `marker-merge`, create it from the source (treat as overwrite for missing files).

**Hook wiring.** The plugin's `hooks.json` runs the framework hooks; `.claude/settings.json` needs no entry for them, and `update` edits its `hooks` key only to remove framework entries. Run:

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/setup-doctor.mjs" wiring
```

`hook-wired-locally` and `hook-copy-retired` must be gone (a leftover means a copy came back: move it as part (b) of [references/migrations/3.0.0-plugin-hooks.md](references/migrations/3.0.0-plugin-hooks.md) does). Report what remains with the `run:` or `fix:` line it carries: a project-owned hook that is missing, not executable, fails `bash -n` or runs by a relative path is the project's to fix, and a framework entry in `settings.local.json` is deleted by hand. Never add, remove, or reorder anything else in that file.

**State gitignore.** Ensure `.gitignore` contains a `.claude/state/` line; append it if missing (create `.gitignore` if absent). The hooks write per-checkout state there (session logs, isolation decisions, field metrics in `.claude/state/metrics/`, the retired copies under `retired-3.0/`), and the metrics recorder refuses to write while the line is missing.

### Step 3.5: Mockup heading renames and questions

Only when `.myspec.json` has a `mockups` block. From the project root run `node "${CLAUDE_PLUGIN_ROOT}/lib/mockup-config-check.mjs"` and act on its output as [references/mockup-questions.md](references/mockup-questions.md) says (same script, `--apply-renames` and `--stamp`). It never blocks the update.

### Step 3.6: Check memory health

When `{aiDir}/memory/` exists. Since v1.23.0 the index tables are generated from the memory files, and `memory-claim-id.sh` refuses to allocate IDs until the doctor passes — so never skip this.

1. Verify the indexes — must print `memory indexes are up to date`:
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/lib/memory-index.mjs" --check
   ```
   `stale` → regenerate with `node "${CLAUDE_PLUGIN_ROOT}/lib/memory-index.mjs"`. Refused because a memory lacks `hook:` → run it with `--backfill --dry-run`, show the output (`from heading (review)` means the H1 became the hook — list those for the user to review), apply with `--backfill`, then re-check.
2. Health:
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/lib/memory-doctor.mjs"
   ```
   Report its summary line in Step 6. Remaining errors (duplicate IDs across branches, malformed anchors) are project content: list them, do not fix them silently.
3. Ensure `.gitignore` contains a `.claude/state/` line — the ID registry is per-checkout state and must never be committed. Append it if missing (create `.gitignore` if absent).

If `node` is unavailable, print: "Memory health check skipped — node not found. Run `node \"${CLAUDE_PLUGIN_ROOT}/lib/memory-index.mjs\" --check` when it is available; ID allocation is blocked until the doctor passes."

### Step 3.7: Verify the install

Everything above wrote files; this reads them back. Run the full doctor from the project root:

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/setup-doctor.mjs"
```

Step 5 is about to stamp `frameworkVersion` to the new version, so run this **before** it — while the versions still differ, content drift is reported as a warning ("update pending"). After the stamp the same drift is an error, which is the point: a `framework-drift` or `framework-missing` error on the next run means this update half-applied.

When it reports any `install`, `wiring`, `schema` or `features` finding, read [references/doctor-results.md](references/doctor-results.md): it says what each one means for this run and what to do before the stamp.

Report the summary line in Step 6.

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

Removed (retired by the framework, or a `when` condition that no longer holds):
  {each deleted file; "kept locally (pinned)" for pinned ones; or omit the block}

Preserved (project-customized sections):
  {list marker-merge files where project content was kept}

Pinned (skipped — locally customized):
  {list each pinned file with its reason, or "none"}

Hooks: run from the plugin (hooks.json); {unwired N framework entries from .claude/settings.json / none wired locally}
       {the lines references/migrations/3.0.0-plugin-hooks.md gives, when it ran or a returned copy was moved / omit}
       {N finding(s) remain — see above / omit}
Memory: {indexes up to date / regenerated N, backfilled M hook: lines (K from heading — review) / skipped — no memory tree}
        doctor: {clean / N error(s), M warning(s) — see above}
Setup:  {clean / N error(s), M warning(s) — see above / skipped — node not found}
Mockups: {what references/mockup-questions.md says to report / omit without a `mockups` block}

Next: Run the `bootstrap` skill to verify the setup is still correct.
```

## Rules

- **Never copy a hook or lib helper into the project.** Since 3.0 they run from the plugin, and a copy under `.claude/` is dead weight at best and a second, stale run of a gate at worst (a copy is moved to `.claude/state/retired-3.0/`, never written). Only the `files` and `rules` blocks exist, and both carry `${aiDir}` as a placeholder to substitute.
- Never overwrite a file whose `frameworkFiles[...].pinned` is set, and never add or clear a pin yourself — except the `hooks/*` and `lib/*` pins the `3.0.0-plugin-hooks` migration drops, which it reports
- Never overwrite content after `<!-- myspec:framework-end -->` in a `marker-merge` file
- Never modify files not listed in `manifest.json`, with five exceptions this skill owns: the `.myspec.json` `visualQuestions` key (Step 1.6, through the `visual-questions` blueprint), what Step 3.5 writes ([references/mockup-questions.md](references/mockup-questions.md): heading renames without asking, answers and stamps when the user chooses them), the `hooks` key of `.claude/settings.json` (framework entries removed, nothing added), `.claude/state/retired-3.0/` (where the migration moves the retired copies), and the frontmatter `status:` line of feature docs the `3.1.0-doc-status` migration rewrites
- Never update `.myspec.json` project fields (`name`, `techStack`) or `aiDir`. Keys a migration retires are deleted only by it: `codeReview` by `3.0.0-code-review`, `reuseAudit` by `3.0.0-reuse-audit`, `project.description` by `3.0.0-schema-v2`. A pin's `hash` and `upstreamHash` are written only by `pin-reconcile.mjs` (`--backfill`, `--record`)
- Never run a migration whose id is already in `.myspec.json` `migrations`; record each one the moment it completes
- If a source file is missing from the plugin, skip it and warn the user — do not delete the destination
- The plugin ships no subagent definitions. Never write to `~/.{harness}/agents/` or to project-scope `.claude/agents/`, `.cursor/agents/`, `.codex/agents/`.

## Verification Checklist

After running the skill:

- [ ] `.myspec.json` `frameworkVersion` read and compared to `manifest.json`; stopped early if already current, or with `upgrade-route.mjs`'s whole route if below the manifest's `upgradeFrom`
- [ ] Every manifest `migrations` id not yet in `.myspec.json` run in order from its `references/migrations/<id>.md`, its *Done when* line met, and recorded as it completed
- [ ] Every `manifest.json` entry processed with its declared strategy (`overwrite` / `marker-merge`)
- [ ] `manifest-keys.mjs renames` run; every row with an old file or old key migrated per `references/renames.md` before its entry was applied
- [ ] Every `marker-merge` destination without an end marker offered replace / prepend / pin (`references/marker-less.md`), and the answer applied
- [ ] `visualQuestions` asked once through the `visual-questions` blueprint when absent (Step 1.6), before any manifest entry was applied
- [ ] Every entry with `when` evaluated: applied like any entry when it holds; when it does not, its `dest` deleted unless pinned (a pinned one left and reported)
- [ ] Every `removed` entry whose `dest` exists handled per `references/removed.md` (deleted, kept when pinned, or moved as a retired copy)
- [ ] Entries pinned in `.myspec.json` skipped and listed in the summary; when pins exist, `references/pins.md` reconciliation run, every verdict acted on, nothing decided alone
- [ ] `templates/*` entries written to `{aiDir}/.templates/` (no `{aiDir}/templates/` created)
- [ ] `marker-merge` files: everything after `<!-- myspec:framework-end -->` left untouched; the region above it taken from the plugin copy
- [ ] Memory health checked when a memory tree exists: `--check` clean (after regeneration or backfill where needed), doctor summary reported, `.claude/state/` gitignored
- [ ] `${aiDir}` binding refreshed between `myspec:paths` markers; content outside markers unchanged
- [ ] `.myspec.json` `frameworkVersion` bumped; project fields (`name`, `techStack`) untouched; `frameworkFiles` holds pins only
- [ ] `setup-doctor.mjs wiring` run from the plugin: `hook-wired-locally` and `hook-copy-retired` gone, nothing added to `settings.json`, project-hook findings and `settings.local.json` entries reported with their fix line; `.gitignore` has a `.claude/state/` line
- [ ] Full `setup-doctor.mjs` run in Step 3.7, before the Step 5 version stamp; every `install`-, `schema`- and `features`-group error resolved or reported
- [ ] No file outside `manifest.json` was modified beyond the exceptions the Rules list
- [ ] Summary printed with `Updated files`, `Migrations`, `Removed`, `Preserved` and `Hooks` lines
- [ ] Step 3.5 run when a `mockups` block exists, also when the versions matched
