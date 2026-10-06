# myspec 3.0 — Breaking-Change Plan (draft)

Prepared 2026-10-04 against `origin/main` at v2.11.0 + PR #251. Sources: all 34 open issues, 76 closed issues, 150 PRs, `docs/`, the maintainer's auto-memory stores (7 projects) and the six consumer checkouts on disk. Every claim names its source; consumer-repo claims were verified on disk, repo claims by grep.

Goal: everything that can only ship in a major goes into 3.0.0, so 3.x can live as long as 2.x did without another forced migration.

## 1. State of play

A 3.0 stack already exists as open PRs. Merge order from their bodies:

| PR | Base | Breaking | What |
|---|---|---|---|
| #252 | main | no | `hook-command-relative` becomes an error for framework hooks in `settings.json` |
| #253 | main | floor | `lib/hook-core.sh`; drops Codex payload cwd fields; needs git ≥ 2.31 (hooks fail open below, documented only) |
| #254 | main | no | one `.claude/state/sessions/<sid>.jsonl` replaces the `/tmp` ledger, legacy marker, `isolation/<sid>.json`, `implement-in-progress.json`; **introduces a new one-release import shim** |
| #255 | main | yes | container checks must declare `runIn` + `containers`; per-check `cwd` |
| #256 | #255 | yes | provision writes `.claude/state/provision.json`; Stop gate compares the record; `lib/dependency-map.sh` removed (closes #239) |
| #257 | #256 | yes-ish | stop gate split into `lib/stop-gate/`, 300 s budget, `timeout: 330` in settings template; missing settings reader blocks instead of guessing |
| #258 | main | yes | remove `code-review` skill (#150) — `codeReview` block / `rules/code-review.md` fate undecided |
| #259 | #257 | yes | drop the 1.x→2.0 shims; `upgradeFrom: "2.11.0"`; removes the three overdue stubs |
| #260 | #259 | yes | drop Codex, `plugins/myspec/`, `.codex-plugin/`, root `hooks.json`, `sync-check.yml` (#143) |

v3.0.0 milestone: #143, #150, #239 — all covered by the stack. `docs/upgrading-to-3.0.md` exists in #259/#260 as a stub; this file is the `docs/myspec-N.0-breaking-changes.md` RELEASING.md requires.

## 2. Breaking changes NOT in the stack

Ranked by how much it costs to do later.

### 2.1 Hook delivery model — decide before merging #260

**Problem.** Every hook and lib is copied per project (`framework-files/manifest.json`, all `overwrite`). Every consumer on disk runs the v2.9.0 hook copies byte-for-byte, so the fixes already on main for the `2>/dev/null` phantom-session bug (`hooks/mark-code-changed.sh:33-34`) and the inherited-isolation-marker bug (`hooks/guard-worktree-context.sh:359-363`) are live in zero consumers. Consumers hand-patch (image-generation-app ×2 files, translate `guard-git-branch.sh`) or pin executable code (new-sporticos-frontend `lib/memory-files.mjs`), and `update` overwrites the patches. Consumer memory: new-sporticos-frontend P046, lockin `feedback_stop_hook_vitest_warnings` ("fix belongs in myspec hooks/, overwritten by update").

**Options.**
- A. Run hooks from the plugin: keep a root `hooks.json` with `${CLAUDE_PLUGIN_ROOT}/hooks/…` commands (the Claude Code plugin hooks contract), declare it in `.claude-plugin/plugin.json`, stop copying `hooks/` and `lib/` into `.claude/`. `update` unwires the eight framework commands from `settings.json`. Hook fixes ship with the plugin version; `frameworkVersion` shrinks to rules + aiDir files. Cost: teammates without the plugin lose the gates (the reason 2.0 kept copies, `docs/myspec-2.0-breaking-changes.md:206-207`); `verification.json` and the `lib/myspec-config.sh` reader path must be re-based on `CLAUDE_PLUGIN_ROOT`.
- B. Keep copies, but make it a 3.x non-event: the "teammates without the plugin" case already fails for skills, so the gates are partial for them anyway.

**Why now.** #260 deletes the root `hooks.json`. If 3.0 later wants option A, re-adding plugin hooks changes where hooks run — a second major. Option A is also the only thing that fixes friction #4/#10 fleet-wide. Recommendation: A, with `update` leaving project-owned hooks (lockin's `guard-release-branch.sh`, `lint-on-edit.sh`; translate `cleanup-worktrees.sh`) untouched in the same arrays.

**Contract facts (verified in PR #272 against the plugin docs).** Hooks are declared in the plugin's `hooks.json` (`.claude-plugin/plugin.json` `"hooks"` key); `${CLAUDE_PLUGIN_ROOT}` is substituted in hook commands and in skill Markdown at load, but is **not exported to the Bash tool** — a rule under `.claude/rules/` or an `${aiDir}` doc cannot name a lib path by variable. Anything that tells the model to run a lib helper must live in a skill (substituted) or print the resolved path (hook block messages do). A plugin hook and a `settings.json` copy of the same handler both run, so a 2.12 consumer on the 3.0 plugin runs every hook twice until `update` unwires the copies — that is why `hook-wired-locally` is an error. Retired copies are moved to `.claude/state/retired-3.0/`, never deleted.

### 2.2 PostToolUse rescan gates → diff-scoped

`require-reuse-audit.sh` rescans the whole tech-spec on any edit and retro-blocks pre-hook specs; opt-out is repo-global (`hooks/require-reuse-audit.sh:3-5,20,52-57`). `no-absolute-paths.sh` scans the whole new content after the file is already written (`hooks/no-absolute-paths.sh:3-5,139`). Both are the top two hook complaints in lockin and new-sporticos-frontend (`feedback_reuse_audit_hook_retro_blocks_tech_specs`, `feedback_no_absolute_paths_false_positive`, P171, S039). Bash/heredoc writes bypass all three PostToolUse guards and leave no session log (NSF `project_bash_edits_bypass_session_hook`, lockin P100).

Change: guards check the session's own diff (the #254 session-state file already lists it) at Stop, or at PreToolUse on the proposed content, not the file after the fact. Breaking because the gate semantics (what blocks, when) change and `reuseAudit.enabled` moves from a repo-global switch to a per-file marker. Ride on #254/#257, which already touch the same files.

### 2.3 Skill surface — finish it in one cut

Removed/renamed skill names are breaking (RELEASING.md:150), so every rename happens now or never.

| Change | Source | Decision |
|---|---|---|
| Delete 3 stubs | #259 | done in stack |
| Delete `code-review` | #258 | decide `codeReview` block (drop; doctor already warns `setting-unknown-key`) and `rules/code-review.md` (leave; project-owned) |
| Move `upstream-sync` out of the fleet | `skills/upstream-sync/SKILL.md:12,38` reads `plugins/myspec/upstream-sources.yml` — maintainer-only | move to `.claude/skills/` with `release` and `triage`; #260 moves the yml to root, which keeps shipping a maintainer tool |
| Fold `feature-scenario` + `feature-seed-data` into `feature-spec` | no inbound route since 2.0 (`docs/myspec-2.0-breaking-changes.md:163`; `rules/workflow.md:21` is the only mention); `idea-process` re-implements them | fold, or delete if field metrics (`.claude/state/metrics/runs.jsonl`) show zero invocations |
| Fold `feature-mockup-review` into `feature-mockup --review` | reverted in 2.0 for autocomplete | leave — the autocomplete argument stands |
| `memorize`/`memorify` vs `memory-*` | naming only | leave — the collapse was tried and reverted (#65) |
| Add `agents/probe-executor.md` (`myspec:probe-executor`) | #171, blocked on #143; Q1 answered on #134 (plugin agents resolve as `<plugin>:<name>`) | ship in 3.0.0: the dispatch name becomes API, so introduce it at the major |

Description cap: 2.0 set ≤350 chars; `code-review` 589, `memorize` 569, `doctor` 354 and total 11,747 chars (plan: 10,137). Add the cap to `scripts/lint-skills.mjs` (currently 1024) so it stops regressing. Non-breaking.

### 2.4 `.myspec.json` schema — one edit

Non-breaking individually, but each additive key is a catalogue bump and a doctor release; do them together and declare `lib/myspec-config.schema.json` `version: 2` as the contract.

- Drop `project.description` (written by `init`, read by nothing) and `codeReview` (#258).
- Add `mockups` — written by `blueprints/mockup.md:125`, read by `feature-mockup`, absent from the schema: doctor warns `setting-unknown-key … nothing reads it` on every mockup-enabled consumer (reproduced).
- Add `frameworkFiles[key].hash` for #160 (pin reconciliation compares `wc -c` today, `skills/update/SKILL.md:82`; NSF carries one stale pin and one upstreamed pin that never clear). Backfill in the 3.0.0 migration pass.
- Add `orchestration.featureImplement` (#247), the port source (#196) and scratch-env script (#197) keys.
- Route the five raw readers through `lib/myspec-config.{sh,mjs}` (`hooks/require-isolation-decision.sh:125-128`, `hooks/validate-frontmatter.sh:108`, `hooks/verify-before-stop.sh:103`, `lib/memory-claim-id.sh:92`, `lib/memory-files.mjs:97`) so defaults live in one place.

### 2.5 Manifest `removed` entries

`templates/index-{procedural,semantic,episodic}.md` are installed to `${aiDir}/.templates/` and read by nothing (`init` copies from the plugin, `lib/memory-index.mjs:63-71` generates headers). Add `removed` entries `since: "3.0.0"`. #259 deletes the 2.0.0 entries but adds none.

### 2.6 Host floors and legacy output

Declare in README and `update`: Claude Code ≥ (the version with `hookSpecificOutput` + `stop_hook_active`), git ≥ 2.31 (#253). Then drop the dual `decision: block` PreToolUse output (`hooks/guard-worktree-context.sh:60-69`, `hooks/require-isolation-decision.sh:28-32`) and the `CLAUDE_STOP_HOOK_ACTIVE` env fallback. No floor is declared anywhere today; evals pin 2.1.269+.

### 2.7 Drop the #254 one-release shim at 3.0.0

#254 imports the 2.x `/tmp` ledger "for one minor release". The 2.0 stubs were also "one minor" and shipped for eleven. With `upgradeFrom: 2.11.0` the shim serves only a session that spans the upgrade; print "finish open sessions before `update`" instead and ship 3.0.0 without it.

### 2.8 Pre-plan-era document fallbacks

Milestone-less plans (`skills/feature-implement/SKILL.md:139`), plan-less features (`skills/feature-complete/SKILL.md:68`), tech-spec-checkbox fallback (`skills/feature-spec-sync/SKILL.md:61`, `rules/workflow.md:45`), legacy `orchestration: agent-chain` (`feature-implement/SKILL.md:135`), `## Files touched` backfill (`hooks/mark-code-changed.sh:518-519`), registry one-line form (`lib/memory-claim-id.sh:224-229`). #259 keeps agent-chain "on purpose"; with a 2.11 floor none of these shapes can arrive. Drop all with a one-line note in `upgrading-to-3.0.md`.

## 3. Decisions

Taken 2026-10-04:

1. **Hook delivery** (§2.1) — **A: run from the plugin.** #260 must keep the root `hooks.json` (rewritten to `${CLAUDE_PLUGIN_ROOT}/hooks/…`) and declare it in `.claude-plugin/plugin.json`; `update` unwires the eight framework commands and deletes byte-identical `.claude/hooks/*` and `.claude/lib/*` copies, showing a diff for hand-patched ones.
2. **Upgrade floor 2.11** (#259) — **kept.** The three 1.x consumers (translate ×2 at 1.0.0, image-generation-app at 1.17.0) are stepped by hand through v1.28 → v2.11 → 3.0 as the dogfood run.
3. **Rescan gates** (§2.2) — **diff-scoped in 3.0**, on top of #254.
4. **Skill folds** (§2.3) — **`feature-scenario` + `feature-seed-data` fold into `feature-spec`**; `idea-process` stops re-implementing them. Probe-executor ships as `agents/probe-executor.md`.

Still open:

5. **#239's `breaking` label** was added by hand on 2026-10-03; the body never says major. #256's "gate stops checking pre-record worktrees" is the only breaking part. Confirm.
6. **RELEASING.md breaking list** needs four surfaces it is silent on: hook I/O + exported env (`MYSPEC_*`), `verification.json` keys, `.claude/state/` layout, framework-file markers / `${aiDir}` layout; plus the host floor and the stub-lifetime rule, with `/release` listing overdue stubs. Non-breaking, but it is what keeps 3.x honest.

## 4. Non-breaking riders worth shipping in 3.0.0

- Flip `quality/release-check.json` `gate: true` — five releases recorded, zero false regressions (RELEASING.md:127). The major becomes the first gated release. Renamed/folded skills break `skill:<name>` tags and per-case hashes, so the 3.0.0 baseline is partial by construction; record it as the new baseline.
- 2.0 riders still undelivered: commit step at the end of `feature-update` and `cross-spec-validation` (lockin `feedback_commit_spec_edits_early`); plan DAG ordered by data dependency (`skills/feature-plan/SKILL.md:50-58` still file-overlap only).
- Stop-gate per-check timeout in `verification.json` (lockin P172: a green 285 s suite blocks under the fixed `CHECK_CAP_SECONDS=120`, `hooks/verify-before-stop.sh:542`). 2.0's "already fixed" table misdiagnosed this as vitest warnings.
- #185 + #161 bundle (rules at the 1000-token budget; `~/.claude-personal` hard-coded in 16 files) — same rule files, same release.
- `docs/upgrading-to-2.0.md:108-110` says implementers run no tests; `implementer-prompt.md:66-74` lets them run the task verify command. Fix the doc.
- Delete `skills/init/SKILL.md:210,228-230` (prose about base agents deleted in 2.0; #259 covers part).
- Add `examples/skills/*.md` for the 21 skills without one, or drop the AGENTS.md rule.

## 5. Migration matrix (from the consumer checkouts)

What `update` 3.0.0 meets in the wild, beyond what #259 assumes:

| Shape | Where | Handling |
|---|---|---|
| `frameworkFiles` as 1.x inventory (`version`/`lastUpdated`), no `migrations` | image-generation-app (28 entries), translate ×2 (17) | floor refusal, or the `2.0.0-schema` logic kept behind the 1.x path |
| Retired `guard-git-branch.sh` wired with bare `.claude/hooks/x.sh` commands | 3 repos | unwire + delete (the 2.0 `removed` entry #259 drops) |
| Hand-patched hooks | image-gen `mark-code-changed.sh`, `validate-frontmatter.sh`; translate `guard-git-branch.sh`; `rules/workflow.md` forked 173 lines | show a diff, never overwrite silently |
| Project hooks sharing arrays with framework hooks; split matchers; `bash "…"` interpreter form | lockin | unwire by command path, keep neighbours |
| Three `features/index.yaml` dialects (2.x `depends-on`; discover `depends_on`/`source`; 1.0.0 `id`/`spec`/`implementation-plan`) | all | status-audit and doctor must normalise or refuse explicitly |
| Memory trees without `hook:` (`anchors:` instead); unslugged `P001.md` names | image-gen; NSF | `memory-index.mjs --backfill` |
| 2.0 session residue: `sessions/README.md` and `.gitignore` rules for `active/`, a UUID-named `status: active` log inside `archive/` | lockin | doctor `sessions-unmigrated` misses all three; extend before #259 deletes it, or accept |
| Paths block in CLAUDE.md only / AGENTS.md only / both / none | one of each | find in any; never create a second |
| `.claude/` and `.myspec.json` untracked | content-processor-app | fs fallbacks for `git mv`/`git rm` |
| 36 stale `.claude/worktrees/*` with old hooks and `.myspec.json` | all | exclude from doctor/update greps (every "renamed skill" hit found was inside one) |
| Stale `settings.local.json` allow rules naming the 1.0.0 plugin cache; `~/.claude-personal/agents/{worker,reviewer}-base.md` | NSF; machine | print, don't touch |

## 6. Suggested order

Branching: every 3.0 PR targets the temporary integration branch `v3` (created from `main` after #252–#254 merged). `main` stays 2.x so patches remain releasable; after 2.12.0 is tagged, `main` is merged into `v3` once and `v2` is created at the tag as the safety net. Evals run report-only on `v3` (`scripts/evals/release-check.sh` without `--record`). The cut is a `v3 → main` merge-commit PR (not a squash: the `/release` breaking gate needs each PR's merge commit), then `/release` from `main`.

1. #252, #253, #254 are merged on `main` (2.12.0). Into `v3`: #255 → #256 → #257 (the #254 import shim is removed by #266).
2. Hook delivery (§2.1) as one PR on top of #257: `hooks.json` → `${CLAUDE_PLUGIN_ROOT}`, plugin.json declares it, manifest drops `hooks`/`lib` entries, `update` unwires and deletes copies. Rebase #259 and #260 onto it (#260 keeps `hooks.json`).
3. Schema edit (§2.4) + `removed` entries (§2.5) + host floors (§2.6) + §2.8 fallbacks as one PR.
4. Rescan gates (§2.2).
5. Skill surface (§2.3): #258, `upstream-sync` move, scenario/seed-data fold, probe-executor agent.
6. #259 (floor), then #260.
7. RELEASING.md breaking-list extension, `gate: true`, fill `upgrading-to-3.0.md`, record baseline, `/release`.
8. Walk the three 1.x consumers through 2.11 → 3.0 as the dogfood run before tagging.

## 7. Status and hand-off (2026-10-06)

Every 3.0 PR is merged into `v3`: #255, #256, #257, #258, #269, #270, #278 (lands #272, #273, #274, #275, which had merged into stack branches after their parents merged into `v3`), #279, #259, #260. Each went through the review loop: a read-only reviewer posts findings with evidence, an implementer fixes them with a reverting test, the reviewer re-verifies on-thread, and the maintainer merges. #274 took three fix rounds. The upgrade floor is 2.12.0; `docs/upgrading-to-3.0.md` is the consumer guide.

Decisions taken 2026-10-05:

- The release eval gate blocks only on Sonnet (`"gateModels": ["sonnet"]` in `quality/release-check.json`, #279). Haiku still runs and is recorded, and a Haiku-only regression is a report-only warning. A `gateModels` entry the run does not cover exits 2, so the gate cannot switch off silently.
- The maintainer accepted #274's costs for 3.0. A Bash call that writes many judged docs spends about three times as long in hooks as on 2.12 (issue #277), and each snapshot of a large judged doc is a loose git object until gc prunes it. Follow-ups: #276 (record Bash writes from a `git status` diff, not by parsing the command) and #277.

`scripts/evals/release-check.sh --version 3.0.0` on `v3` at b237e99, report-only, returned **no-change** for both models against v2.12.0. The first attempt hit 300 s timeouts on the v2.12.0 side and gave no verdict; the re-run reused HEAD's results.

Added 2026-10-06, after a backlog triage, all merged into `v3`:

- **#171 shipped in 3.0** (#306): the probe executor is the plugin agent `myspec:probe-executor` with `disallowedTools: Edit, Write, NotebookEdit, Agent` and `omitClaudeMd: true`. **The Claude Code host floor rises from 2.0.12 to 2.1.288**, the release in which a plugin agent spawned by name runs with its own `disallowedTools` in agent teams too (Agent-tool dispatch has honoured it since 2.1.78; `omitClaudeMd` is 2.1.271). Stated in README "Installation", `docs/upgrading-to-3.0.md` and `skills/update` Step 0.
- **#277 fixed** (#299): one hook call on a 200-statement Bash command went from ~28 s to under 0.5 s, so the cost accepted above no longer applies. #276 follows in 3.1 (#305).
- Non-breaking fixes that rode along: #159, #161, #165, #170, #183, #184, #282 (lib and hooks); #166, #167, #168, #174, #191 (feature-implement); #169, #173, #188 (feature-plan); `memory-system.md` trimmed back under the always-loaded budget (#283; #185 declined).
- Deferred to 3.1, not breaking: #276, #239's Stop-gate half, and the probe-setup stack #194–#197.

Remaining: dogfood `/myspec:update` on the 1.x consumers (v1.28 → v2.12 → v3, `--plugin-dir`, on throwaway clones); merge this `v3` → `main` PR; `/release` 3.0.0 from `main`, the first gated release, which records the baseline.
