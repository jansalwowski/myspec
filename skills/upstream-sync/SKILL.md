---
name: "upstream-sync"
description: "Use when tracked upstream repos should be checked for changes worth porting into local skills. Surfaces a per-mapping diff and commit history for the pairs in upstream-sources.yml. Do NOT use for dependency bumps."
---

# Upstream Sync

Check tracked upstream repos for new commits, diff each upstream path against its local counterpart, and propose adoptions. The skill **proposes** — every file change still goes through the normal Edit-tool approval path. Never silently overwrite local files.

## Config

Source of truth: `plugins/myspec/upstream-sources.yml` (resolved relative to repo root).

Shape:

```yaml
sources:
  - name: <short-name>            # e.g. "superpowers"
    repo: <owner>/<repo>          # e.g. "obra/superpowers"
    branch: main
    last_checked_sha: <sha>       # "" on first run = show full history
    last_checked_date: YYYY-MM-DD
    mappings:
      - upstream: <path-in-upstream>     # e.g. "skills/brainstorming"
        local: <path-in-our-repo>        # e.g. "plugins/myspec/skills/brainstorm"
        divergences:                     # intentional differences — do NOT re-propose
          - "<one-line rationale>"
```

`divergences` are intentional. If a diff hunk matches one, mention it as "matches divergence #N, skipped" but do not propose it.

## Workflow

Complete in order. Process **one mapping at a time** — do not batch.

1. **Preflight** — `gh auth status` must succeed; `gh` is the only network dep. If it fails, stop and ask the user to authenticate.
2. **Parse args** — if the user passed an argument (e.g. `/myspec:upstream-sync brainstorm`), filter mappings whose `local` or `upstream` path contains the arg. Otherwise process all.
3. **Read config** — load `plugins/myspec/upstream-sources.yml`. If missing, offer to scaffold it from a template.
4. **For each source** (in config order):
   1. Fetch HEAD: `gh api repos/<repo>/commits?sha=<branch>&per_page=1` → record new HEAD sha.
   2. For each mapping (filtered by args):
      1. Fetch commits since last check:
         `gh api 'repos/<repo>/commits?path=<upstream>&since=<last_checked_date>T00:00:00Z&per_page=100'`
         If `last_checked_date` empty, fetch full history (`per_page=100`).
      2. If zero commits → print "`<source>/<mapping>` up to date" and continue.
      3. Fetch each upstream file in the mapping path:
         - Single file: `gh api repos/<repo>/contents/<upstream> -H 'Accept: application/vnd.github.raw' > /tmp/upstream-<slug>`
         - Directory: list contents, fetch each file individually (do not recurse blindly — depth 1 unless config says otherwise).
      4. Diff against local: `diff -u <local> /tmp/upstream-<slug>` (or per-file for directories).
      5. **Render the per-mapping report** (see template below).
      6. **Ask the user** via `AskUserQuestion` so the choice is selectable:
         ```
         question: "How should I handle <upstream>?"
         header:   "Upstream sync"
         options:
           - "Adopt"                 → write upstream changes to local file(s)
           - "Skip"                  → ignore this mapping for now
           - "Record-as-divergence"  → append a note under the mapping's `divergences:`
           - "Show-full-diff"        → display the full diff before deciding
         ```
      7. If Adopt: make Edit calls to the local file(s). Each edit shown for normal review.
      8. If Record-as-divergence: append a line under the mapping's `divergences:`.
5. **Write back to config** — after all mappings for a source processed, update its `last_checked_sha` and `last_checked_date` (today). Do this even if user skipped some mappings — skipping is a decision; the next run should not re-show the same commits unless the user asks for `--since=<sha>`.
6. **Summary** — print one-line totals: sources checked, adoptions made, divergences added.

## Per-mapping report template

```
─── <source-name> : <upstream-path> → <local-path> ───

N new commits since <last_sha> (<last_date>):

Substantive (paths matching SKILL.md or the file you map):
  <sha>  <subject>
  ...

Other (scripts, helpers, ancillary files):
  <sha>  <subject>
  ...

Known divergences (from config, NOT re-proposed):
  • <divergence note>

Diff summary (substantive only, abridged to ~30 lines):
  <unified diff snippet, with hunks that match a divergence annotated as
   [matches divergence #N, skipped]>

What do you want to do?
  A) Adopt: apply <count> additive changes inline
  B) Skip this mapping for now
  C) Record one of these as a new divergence (which?)
  D) Show full diff
```

Classify commits into **Substantive** (touches files mirrored in the mapping's local path) vs **Other** (touches sibling files not pulled locally, e.g. scripts/, examples/, README). Use the commit's `files[].filename` from the API to classify.

## Filtering hunks against divergences

After diffing, walk each hunk:
- If the hunk only adds content the local file already lacks because of a divergence (e.g. upstream adds a HARD-GATE block, divergence note says "Output is optional"), annotate `[matches divergence #N, skipped]` and exclude from the "Adopt" count.
- Match is heuristic — keyword overlap between the hunk and the divergence text. When in doubt, present it as a proposal anyway and let the user record it as a new divergence.

## Adoption guardrails

- **Never** `git checkout`, `git reset`, or `git pull` from the upstream.
- **Never** apply the diff with `patch` or `git apply` — translate each accepted hunk into an Edit call so the user sees the change.
- One mapping's adoptions get one logical commit (or none — committing is up to the user).
- If a hunk depends on a file the local skill does not ship (e.g. upstream adds a section referencing `scripts/server.cjs` that has no local counterpart), flag this and ask before adopting.

## Preflight for visual / scripted assets

If a mapping points at a directory that includes runtime assets (scripts, HTML, server code), check whether the local mapping has its own copy of those assets before proposing adoption of fixes:

```bash
test -d <local>/scripts || echo "MISSING: <local>/scripts — runtime fixes from upstream are non-portable"
```

When local is missing the runtime, list those commits under "Other (skipped — local has no runtime)" and do not propose them.

## Args

- No arg → process all mappings.
- One arg (string) → filter mappings whose `local` or `upstream` path contains the string. Example: `/myspec:upstream-sync brainstorm`.
- `--full-history` → ignore `last_checked_sha`; show everything. Useful on first run after adding a source.
- `--dry-run` → do everything except write Edits or update the config.

## Verification Checklist

- [ ] `gh auth status` succeeded before any network call
- [ ] Processed one mapping at a time, in config order
- [ ] Classified commits into Substantive vs Other
- [ ] Annotated hunks that match known divergences
- [ ] Every file change went through Edit (not patch / not silent write)
- [ ] Updated `last_checked_sha` and `last_checked_date` after processing each source
- [ ] Printed a one-line summary at the end
