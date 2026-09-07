---
name: "backbone-sync"
description: "Use when the project topology file (backbone.yml) needs checking against the repository it describes, or has drifted. Keywords: backbone drift, topology audit, backbone out of date, update backbone, stale topology. Do NOT use to create one for the first time (setup backbone) or for feature docs (feature-spec-sync)."
allowed-tools: [Bash, Read, Edit, Grep, Glob]
tags: [topology, maintenance, verification, sync]
---

# Backbone Sync

Check the topology file named by `.myspec.json` → `topologyFile` against the repository, then fix what drifted. `bootstrap` reads this file at session start and `feature-tech-spec` enumerates `packages:` from it for the reuse audit — so a wrong backbone misleads every session, and a package missing from it is invisible to every future reuse audit. That is the cost being paid down here, not tidiness.

**Core principle:** the script owns what is decidable, you own what is not. Never remove a backbone entry on a liveness signal alone, and never call a run clean while its NOT CHECKED block has entries.

## Workflow

### 1. Run the engine

From the project root:

```bash
node "${CLAUDE_PLUGIN_ROOT}/lib/backbone-audit/audit.mjs"
```

| Exit | Meaning | Response |
|------|---------|----------|
| `0` | no findings from the checks that ran | read NOT CHECKED before reporting clean |
| `1` | high-severity findings | fix them |
| `2` | critical findings | fix them first |
| `3` | the audit could not run | the message says why: no topology file (offer `/myspec:setup backbone`), an unreadable one, or a YAML construct the parser refuses to guess at |

| Flag | Purpose |
|------|---------|
| `--file=<path>` | Audit a topology file `.myspec.json` does not name |
| `--only=<name>` | One app or package; skips the project-wide sweeps |
| `--severity=<low\|medium\|high\|critical>` | Hide findings below the threshold (display only — the exit code always reflects every finding) |
| `--stale-days=<n>` | Liveness threshold (default 365, or `audit.stale_days`) |
| `--no-liveness` | Skip the git-backed sweep |
| `--json` | Machine-readable |

### 2. Read NOT CHECKED first, then the three sweeps

**NOT CHECKED** lists every check that could not run and why — no workspace globs to enumerate (lerna, nx, rush, go.work and non-JS services are not covered), a shallow clone, a command whose shape cannot be resolved, untracked files git grep cannot see. These say nothing about the topology file either way. A run with entries here is not a clean bill of health, and reporting it as one is the failure this whole tool exists to prevent.

- **STALE** — declared in the file, gone or changed on disk. Mechanically decided; act on it.
- **MISSING** — in the repo, absent from the file. Also mechanically decided, and the half that matters most: this is what makes a backbone quietly incomplete rather than visibly wrong.
- **LIVENESS SIGNALS** — declared, present, possibly dead. **Not findings.** Step 3 exists because of these.

### 3. Adjudicate the liveness signals

Every signal is a cheap proxy for "still alive", and each lies in a specific way. The engine's `check:` line is the counter-check — it deliberately searches the **working tree**, because the signal itself came from `git grep`, which reads only tracked files. Running `git grep` again would reproduce the wrong answer rather than test it.

| Signal | What it cannot see | Counter-check |
|--------|--------------------|---------------|
| `no-importers` | tsconfig/bundler path aliases, relative-directory imports, `#subpath` imports, dynamic `import()`, gitignored or untracked consumers, submodules, consumers in other repos | run the `check:` line, then grep for the unscoped name and check consumers' `package.json` dependencies |
| `used-by-stale` | the same list — an alias or relative import never spells the package name | run the `check:` line against that one consumer |
| `stale-signal` | code that is finished rather than abandoned: parsers, adapters, vendored protocol code | `git log --oneline -5 -- <path>`, then read the entry's `purpose:`. Old, small and stable is normal |
| `outside-workspace` | a second workspace config, or a build tool that globs its own inputs (turbo, nx, bazel, go.work) | check that build tool's config, not the package manager's |

A signal that survives its counter-check is still not a delete. Report it as *"nothing references this — confirm before removal"* and let the user decide; removing a real but dormant unit hides it from every future reuse audit, which is the exact failure this skill exists to prevent.

**Never** propose removing an entry the topology marks under `boundaries.never_modify` or `boundaries.generated_do_not_edit` — those are supposed to look dead. The engine already exempts them.

### 4. Check what no script can see

The engine validates paths, names, shapes and command targets. Read the file once and check the prose against reality:

- `purpose:` and `stack:` lines describing what a unit used to be
- `relationships:` still matching how the apps actually talk
- `conventions:` contradicted by the code the convention governs (spot-check 2–3)
- `# TODO:` markers left from generation — the engine treats them as "not filled in yet" and skips those values, so they are invisible until someone reads them
- units NOT enumerable from a workspace config: Go, Python, Rust, JVM services, and lerna/nx/rush layouts. NOT CHECKED names this when it applies; walk the repo root by hand and compare against `apps:` + `packages:`

### 5. Present, then fix

Group findings by sweep, show the line number for each, and wait for approval. Then edit the topology file **with Edit, not a script** — the section banners (`# ── STRUCTURE ──`) and TODO markers are what make the file readable, and a YAML round-trip destroys them.

| Finding | Fix |
|---------|-----|
| `path-missing`, `entry-missing`, `src-missing`, `config-missing` | repoint if the thing moved (search for it first), delete the key if it is gone |
| `package-name-mismatch` | take the name from the real `package.json` |
| `package-name-undeclared` | add `package:` so a later rename is detectable |
| `unit-malformed`, `path-undeclared`, `no-units` | the entry was hand-edited into a shape with no fields — restore it or remove it |
| `command-missing` | repoint at the surviving script, or drop the command |
| `workspace-config-missing` | correct it — the MISSING sweep is blind until it resolves |
| `boundary-missing` | a protected path that moved is protection that stopped applying; repoint it |
| `workspace-member-unlisted` | add the unit — read its `package.json` and entry file for a real `purpose:` and `stack:`, do not write `TODO` |
| `command-unlisted`, `root-config-unlisted`, `src-unlisted` | add it, or record the deliberate omission under `audit:` → `ignore:` |
| `used-by-missing` | drop the consumer |
| `database-unlisted` | add the block with real schema/migration paths |
| `ignore-stale` | remove it — it mutes anything created at that path later |
| `topology-unrecorded` | add `"topologyFile"` to `.myspec.json` |

Record a deliberate omission in the file rather than leaving it undocumented:

```yaml
audit:
  ignore:
    - packages/legacy-shim   # kept for the 1.x adapter, not part of the build
  stale_days: 540
```

### 6. Confirm

Re-run the engine. Every fixed finding must be gone, no new one may appear, and NOT CHECKED must be no longer than it was.

## Refusals and blind spots

The engine aborts (exit 3) rather than half-reading a construct, because a partly-read file drops the keys around it — and dropping `boundaries:` or `audit.ignore` turns exemptions off silently. It refuses block scalars, anchors, aliases, merge keys, flow mappings, tab indentation, duplicate top-level keys and multi-document files. The fix is to rewrite that line in the shape the blueprint emits, not to work around the refusal.

What it does not cover, whatever the exit code: workspace layouts outside pnpm/npm/yarn/bun (announced in NOT CHECKED), source directories holding fewer than three files, and any claim written in prose. Step 4 is the only coverage those have.

## Verification Checklist

- [ ] Ran the engine from the project root
- [ ] Read NOT CHECKED before characterising the result
- [ ] Every liveness signal got its `check:` line run, and the command is in the report
- [ ] No entry removed on a signal alone
- [ ] Read the file for stale prose the engine cannot see (step 4)
- [ ] User approved before any edit
- [ ] Edits preserved section banners and comments
- [ ] Re-ran the engine: clean, or the remainder recorded under `audit.ignore`

## Integration

**Call after:** refactors that move or rename a package, adding an app or workspace member, `/myspec:feature-complete` when a feature introduced one.
**Complements** [OPTIONAL]: `/myspec:doctor` — surface C runs this engine rather than re-deriving it.
**See also** [OPTIONAL]: `/myspec:setup backbone` creates the file this skill maintains; `/myspec:feature-spec-sync` handles feature docs, not topology.
