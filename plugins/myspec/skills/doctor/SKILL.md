---
name: doctor
description: "Use when checking whether the project's myspec and agent setup is healthy, or auditing and optimizing it — CLAUDE.md, .claude/rules, skills, agents, hooks, ${aiDir} docs, memory tree, feature manifest. Takes an optional surface (A–F or its name) to check just one. Keywords: healthcheck, health check, is my setup broken, doctor, audit ai setup, optimize ai workflows, context bloat, token budget, rules drift, stale skills, broken hooks. Do NOT use for application code (code-review), one skill (skill-verify), one feature (feature-verify), manifest-only checks (features-status-audit), or memory grooming (memory-sanitize, memory-optimize)."
tags: [audit, maintenance, hooks, context-budget, drift]
---

# Doctor

Health check over every surface that shapes agent behavior in the project. Finds broken wiring, forked framework files, invalid rules, stale anchors, contradictions, dead config, and token bloat; then, with user approval, applies fixes as grouped PRs.

Scope is the *setup*: the framework install and the context, rules, skills, hooks, and indexes an agent reads. It is not a check of the project's own code, features, or specs — the `Do NOT use for` routes in the description own those.

Runs without configuration. An optional per-repo extension file `.claude/rules/doctor.md` (format below) adds project-specific anchors, read-only files, and extra checks.

## Three tiers — pick the cheapest one that answers the question

| Tier | Invocation | Cost | Answers |
|---|---|---|---|
| 0 | `node .claude/lib/setup-doctor.mjs` | ~1s, no model | Is anything mechanically broken or drifted? |
| 1 | `/myspec:doctor <surface>` | one subagent | Is surface X coherent? |
| 2 | `/myspec:doctor` | six subagents + PRs | Full pass over everything |

Tier 0 is not an optional preliminary — it is where every mechanical fact comes from, and
tiers 1 and 2 both start by running it (Phase 0). Reach for tier 2 when the whole setup is
due for a pass; reach for tier 1 when the user named a surface or tier 0 pointed at one.

## Constraints

- **Verify before reporting, re-verify before fixing.** Every finding carries a command-produced evidence line (ls / grep / measured tokens / executed hook). A subagent's finding is a lead, not a fact — the controller re-checks every finding acted on with its own command. Token counts = `wc -c` / 4.
- **No edits before the user approves the Phase 3 report.**
- **Never touch gitignored personal files** (`.claude/settings.local.json`) or anything listed under the extension's `## Read-only` — report findings there as recommendations only.
- **The doctor owns mechanical truth.** File-content drift against the plugin, hook registration and executability, `bash -n`, schema validity of `.myspec.json` / `.claude/verification.json` / `${aiDir}/features/index.yaml`, always-loaded token budgets, dead path and skill references: `setup-doctor.mjs` decides all of these, and its Phase 0 output is handed to the subagents as given. A subagent that re-derives one of them is spending a model on a `diff` and will disagree with the script sooner or later. Judgment — duplication, contradiction, a claim that disagrees with the code, a description that will not trigger — is what the subagents are for.
- **Severity follows false-positive rate.** Report a finding as blocking only when it is deterministic and has no plausible innocent reading. Everything a project might be doing on purpose is a recommendation. The doctor already grades its own findings this way; match it.
- **Delegate, don't duplicate.** Deep single-skill rework → `/myspec:skill-verify`. Single-feature health → `/myspec:feature-verify`. Session archiving → `/myspec:session-clean`. User-level auto-memory grooming → `/myspec:memory-sanitize`. This skill finds and routes; those skills own the deep passes.

## Workflow

### Phase 0 — Load configuration

1. Read `.myspec.json` for `aiDir` (default `.ai`); use it everywhere `${aiDir}` appears below.
2. Read the project extension if present — `.claude/rules/doctor.md`, falling back to `.claude/rules/ai-setup-audit.md` (its name before this skill was renamed; still read, so an existing extension keeps working). Take its `## Project anchors`, `## Read-only`, and `## Extra checks` sections. When only the old name is present, say so once and suggest renaming it. Neither present → note "no project extension; auditing framework surfaces only."
3. Detect the default branch: `git symbolic-ref --short refs/remotes/origin/HEAD`, falling back to `main`/`master`.
4. Run the deterministic checks and keep the result — it is the ground truth every later phase quotes:

   ```bash
   node .claude/lib/setup-doctor.mjs --json --plugin-root "${CLAUDE_PLUGIN_ROOT}"
   ```

   Each record is `{ id, group, path, detail, remediation: { commands, text } }`. Group them by
   `group` and carry them forward: `install` and `wiring` records go into surface E's brief,
   `schema` into E and F, `budget` and `refs` into A. The brief says *these are established
   facts, verified by command — do not re-check them, and do not report a finding that
   contradicts one*. A `NOTE` about an unresolved plugin root means the `install` group did not
   run; say so in Phase 3 rather than filling the gap by hand.

   Missing script (project predates it) → note "tier 0 unavailable — run /myspec:update" and
   run the surfaces the old way, accepting that they will be slower and less reproducible.

### Phase 1 — Fan out read-only audit subagents

**Addressability.** Invoked with an argument (`A`, `hooks`, `skills`, `memory`, …), dispatch
only the matching surface and skip straight to Phase 2 for it. The six-way fan-out is the
default, not a requirement — a user who has been pointed at one surface should not pay for
the other five.

Dispatch six parallel read-only agents (Agent tool, general-purpose), one per surface. Each brief: the surface's checklist below, plus items from `## Extra checks` tagged for that surface, plus "return structured findings: file, category (invalid | stale-anchor | duplication | contradiction | over-budget | dead | meaningless | restructure), one-line evidence, one-line recommendation, token saving; per-file token table; raw data, no prose". Forbid edits.

**A. Always-loaded context** — `CLAUDE.md` (repo + parent dir), every `.claude/rules/*.md`.
Tier 0 has already measured the budgets (`over-budget`) and resolved every path and
`/myspec:*` reference (`dead-path-ref`, `dead-skill-ref`); those records are in the brief. What
is left is judgment:
- Duplication across files and against `${aiDir}/pre-flight.md` / `${aiDir}/memory/index.md`; contradictions (session lifecycle, routing, vocabularies)
- Rules with no actionable content (things any agent does anyway); sections compressible to a line or table
- For each `over-budget` record, *what* to cut: which sections are compressible, and which are relevant only to a specific activity and should carry `paths:` frontmatter gating instead of loading always
- Hooks a rule file *describes* but that are wired to a different event than the prose claims — tier 0 sees registration, not whether the description matches

**B. Skills + agent definitions** — `.claude/skills/*/SKILL.md`, `.claude/agents/*.md`, audited against `.claude/rules/skill-optimization.md` and `.claude/rules/skill-self-test.md`:
- Anchor verification is the core job: every file path, script name (checked against the package manifest that owns it — monorepo sub-packages have their own), CLI flag, tool/MCP server name (must match a really-registered prefix), alias, tag, and table format the body relies on — check against disk, plus everything in `## Project anchors`
- Cross-agent contract coherence: values one agent's output contract emits must be the only values its consumers branch on (no phantom vocabulary); commands an agent is told to run must sit inside its declared tools
- Descriptions: trigger keywords + "Do NOT use for", never a workflow summary; if a skill triggers on a common word, its body must meet the frequent-load budget (< 200 words)
- Flag skills needing deep rework for a follow-up `/myspec:skill-verify` run instead of re-auditing them inline

**C. `${aiDir}` core docs** — everything under `${aiDir}/` outside `features/`, `memory/`, `ideas/` (README, INDEX, pre-flight, conventions/, backbone, key components):
- Spot-check 3–5 load-bearing claims per doc against code: lint flags, ports, directory locations, "not implemented" / "do not do X" claims, architecture framing
- Dead links; docs for tools that left the repo; index files whose `updated:` predates the content they index; advertised-but-empty directories
- Duplication clusters — if a fact is stated in 3+ docs, give it one home + cross-refs

**D. Memory tree** — `${aiDir}/memory/` against `${aiDir}/memory-system.md` (layer budgets, 30-day consolidation), `.claude/rules/memory-system.md`, and `.claude/rules/auto-memory-style.md`:
- Layer-1 index at its ~200-token budget; entry anchors still grep-match their targets; episodic entries > 30 days old with `persistent: false` and never consolidated; entries over the length caps; ID collisions across namespaces; `sessions/active/` empty of terminal-status files; user-level auto-memory `MEMORY.md` overlap with project memory

**E. Hooks + harness config** — `.claude/settings.json`, every `.claude/hooks/*.sh`, `.claude/lib/*.sh`, `.claude/verification.json`, `.myspec.json`. Tier 0 owns existence, registration, executability, `bash -n`, framework and hook content drift, and schema validity; its `install`, `wiring`, and `schema` records are in the brief and are not to be re-derived. This surface is behavior, which no script can settle:
- Execute each hook with synthetic stdin JSON (`printf '{"tool_input":{...},"cwd":"..."}' | bash <hook>`) for both the should-block and the should-pass case, and check the decision against what the hook claims to do. A hook can exist, be wired, be executable, parse cleanly — and still approve everything
- Environment assumptions: commands run where the convention says (host vs container); the worktree case degrades gracefully; a `tooling-absent` record from tier 0 means some gate is currently passing without running
- `verification.json` commands actually exercise this project (right package manager, right workspace) — tier 0 only knows whether a command string is present
- Whether each derived pattern survives its config value, beyond the `aiDir` trailing slash tier 0 catches

**F. Features tree + ideas** — `${aiDir}/features/`, `${aiDir}/ideas/` (structural pass, don't deep-read specs):
- Run the features-status-audit engine first: `node "${CLAUDE_PLUGIN_ROOT}/lib/features-status-audit/audit.mjs"` — it owns manifest ↔ disk drift, orphans, status vocabulary, missing docs
- Add only what the script doesn't cover: manifest `note:` fields carrying embedded history (belongs in CHANGELOG.md); largest-file outliers; index freshness (spot-check 3 mapped paths); ideas queue vs shipped reality

### Phase 2 — Verify and rank

1. Spot-check every finding intended for action with a fresh command (minimum: the top finding per surface).
2. If a finding does not reproduce, drop it. If a rule and reality disagree (e.g. a mandated spelling that 0-of-N files use), the cheaper, non-breaking side wins — usually fixing the rule.
3. Rank: broken mechanisms > false documentation > contradictions > token waste > restructuring.

### Phase 3 — Report and get approval

Present: per-surface findings with evidence, token table (now → target), the fix grouping below, and a needs-user-decision list. Wait for the user before editing anything. Always needs a user decision: feature status transitions (`/myspec:feature-complete`'s job), orphan-feature promotion, anything in `settings.local.json` or `## Read-only` files.

### Phase 4 — Apply as grouped PRs

One worktree + branch per group, created from the fresh default branch (`git worktree add .claude/worktrees/<name> -b <branch> origin/<default>`). Standard grouping — if a group has fewer than 3 findings, merge it into a neighbor:

1. `fix/` broken contracts in skills/agents (highest urgency, zero judgment)
2. `fix/` hook repairs — every hook fix ships with a before/after behavioral test in the PR body
3. `docs/` accuracy — false claims, dead refs, deletions, merges
4. `docs/` context diet — always-loaded compression (separate PR so token cuts are reviewable apart from semantic changes)
5. `chore/` corpus — mechanical volume (status normalization, frontmatter, memory compression, manifest bloat); high-volume mechanical edits may be drafted by a subagent against an exact work order, but the controller diff-reviews before committing

Per PR: scan the staged diff for absolute paths (`git diff --cached | grep -nE '/(Users|home)/'` — the same rule `no-absolute-paths.sh` enforces on writes); PR body lists defect → effect → fix with evidence and cross-links the sibling PRs.

## Known bug classes (regression greps — check these first, they recur)

The **Owner** column says what already decides the class. A row owned by a script is not a
subagent's job: read its verdict from the Phase 0 records. The rest recur because nothing
mechanical can see them.

| Class | Shape | Owner |
|---|---|---|
| Config value breaks derived pattern | trailing slash in a configured dir → derived glob `dir//*` matches nothing; consumer silently dead | tier 0 `aidir-trailing-slash` |
| Promised binary absent | `timeout` assumed, absent on macOS → "120s cap" runs unbounded | tier 0 `tooling-absent` (jq/node); judgment otherwise |
| Mixed status vocabularies | frontmatter statuses outside the manifest's allowed enum | `audit.mjs` (surface F) |
| ID collision across namespaces | framework P001 vs project P001 in one index | `memory-doctor.mjs` `duplicate-id` |
| Framework file silently forked | a rule hand-edited at a matching version; an update that half-applied | tier 0 `framework-drift` |
| Hook copied but never wired | the file is there, no settings entry, nothing ever runs it | tier 0 `hook-unregistered` / `wiring-incomplete` |
| Tool/server name drift | agent declares `mcp__db__*`; the real server registers under a different prefix | judgment (surface B) |
| Phantom contract vocabulary | a consumer branches on labels its producer is forbidden from emitting | judgment (surface B) |
| Defaults that don't exist | a documented default flag value names a project/target that was never defined | judgment (surface B) |
| Script referenced ≠ script defined | docs say `lint --fix`, the manifest defines `lint:fix`; config file present but never wired as a script | judgment (surface B) |
| Allowlist missing self | a guard hook blocks edits to its own file | judgment (surface E, behavioral run) |
| Temporary ban outlives reality | "DO NOT implement X yet" beside shipped, working X | judgment (surface C) |
| Frozen index | INDEX.md lists 2 of 15 features | judgment (surface C/F) |
| History embedded in hot files | multi-KB changelog inside a manifest `note:` field | judgment (surface F) |

## Project extension format

`.claude/rules/doctor.md` (or the legacy `.claude/rules/ai-setup-audit.md`), hand-authored, all sections optional. Section headings are the contract — keep the exact names:

```markdown
## Project anchors
Repo-specific facts surface B must verify (one per line, with the authoritative source).
- Playwright project names: defined in e2e/tests/utils/projects.ts
- e2e/ has its own package.json — check yarn scripts there, not at root

## Read-only
Files the audit may flag but never edit.
- ${aiDir}/invariants.md

## Extra checks
Additional per-surface checklist items, tagged [A]–[F].
- [E] hooks must run inside the dev container, not the host
```

## Verification Checklist

- [ ] Tier 0 run in Phase 0 and its records handed to the surfaces; no subagent finding contradicts or re-derives one
- [ ] Every reported finding carries command evidence; every applied fix was re-verified by the controller, not just the subagent
- [ ] Edited hooks: `bash -n` passes AND a behavioral stdin test was run for the block and pass cases
- [ ] Edited YAML: parsed with `python3 -c "import yaml; yaml.safe_load(open('<file>'))"`
- [ ] Edited `${aiDir}` markdown: frontmatter starts at line 1 with an identity field and a temporal field (`updated`/`created`/`started`/`date` — the validate-frontmatter hook enforces both)
- [ ] Token counts measured before/after (`wc -c` / 4) and stated in each diet PR
- [ ] `git status` clean on the main checkout; every group pushed with an open PR cross-linking the others
- [ ] `## Read-only` files and `settings.local.json` untouched

## Integration

**Routes to** [OPTIONAL]: `/myspec:skill-verify` — deep audit of a flagged skill. `/myspec:feature-verify` — deep audit of a flagged feature. `/myspec:session-clean` — dangling session files found in surface D. `/myspec:memory-sanitize` — user-level auto-memory findings.
**See also:** `/myspec:features-status-audit` — surface F runs its engine; invoke it standalone for a manifest-only check. `node .claude/lib/setup-doctor.mjs` — tier 0 standalone; `bootstrap` reports its summary every session and `update` verifies itself with it.
