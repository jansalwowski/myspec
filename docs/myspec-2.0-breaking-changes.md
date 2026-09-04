# myspec 2.0 — Breaking-Change Plan

Prepared 2026-09-02. Merges two independent passes: a sweep of the maintainer's memory stores and nine consumer repos (crm-front-app, revenue-front-app, pdf-viewer-front-app, crm-app, new-sporticos-frontend, lockin, image-generation-app, sporticos-phrase-app, sporticos-users-admin-role) plus open issues (#10–#15, #18, #55) and `docs/framework-audit-2026-07-31.md`; and a repo-level audit of HEAD for compat shims, dead files, and schema debt. Every claim names its source. Consumer-repo evidence was not re-verified against those repos; repo-level claims were verified by grep or by running the helper.

Upstream state at time of writing: `main` is at 1.28.0; branch `feat/setup-doctor` carries five unreleased commits (setup-doctor tiering, `doctor` rename, drift false-positive fix, aiDir detection fallback, `renamedFrom` manifest migration). Consumers sit anywhere between 1.0.0 and 1.28.0.

## Already fixed upstream — do not redo

| Pain reported in consumer memory | Fixed in |
|---|---|
| Bootstrap Layer-2 row count printed 0 (regex expected the bare `\| P001 \|` legacy row; generated tables use the linked `\| [P001](…) \|` form) | HEAD `skills/bootstrap/SKILL.md:55-62` accepts both |
| `memory-index.md` vs `memory/index.md` identity collision (#55) | HEAD: file renamed to `anti-patterns.md`, manifest carries `renamedFrom`, `update` migrates and refuses when both exist |
| Session log created inside a linked worktree, invisible to sweeps and destroyed by `git worktree remove` | 1.25.1 (`mark-code-changed.sh` pins to the primary checkout via `--git-common-dir`) |
| `guard-git-branch.sh` blocked `cd <worktree> && git rebase` (lockin memory: "cd first as its own call") | HEAD approves any command that names a linked worktree path (`guard-git-branch.sh:96-108`) |
| `no-absolute-paths.sh` false positive on `-Users-` encoded cwd | 1.14.1 |
| Stop hook "fails" on vitest `Warning:` lines (lockin memory) | Upstream hook is exit-code based (`verify-before-stop.sh:189`); lockin's copy is 88 lines diverged. Verify there before treating as open |
| `memorize` / `memorify` duplicate memories and skip the consolidation check (audit B4) | Both now delegate to `memory-create` as a REQUIRED step; no type table is duplicated |

## The seven breaking changes

Ordered by dependency, not by pain. Change 1 is the foundation every later migration runs on.

### 1. Schema, rename, and normalization story

**Problem.** `.myspec.json` carries bookkeeping nothing reads, `aiDir` has three defaults and a runtime detection fallback, `marker-merge` cannot reach a file's own title, and two pre-rename names are still read at runtime.

**Evidence.**
- `frameworkFiles[*].version` and `lastUpdated` are written by `init` and `update` and read by nothing: the doctor reads only `pinned` (`lib/setup-doctor.mjs:518`) and key presence (`:615`); `bootstrap` reads only `frameworkVersion`; `update` reads only `pinned`.
- `aiDir` defaults disagree: `init` defaults to `ai`, `aiDirFor` in `lib/memory-files.mjs:109` and the README example say `.ai`. The doctor already errors on a missing key (`myspec-missing-key`), yet detection code survives in the resolver, `memory-claim-id.sh`, and three hooks (fixture: `lib/tests/aidir-fallback.test.sh`). In the nine consumers the value takes four spellings: `ai`, `ai/`, `.ai`, `.ai/`.
- `marker-header-drift` exists because frontmatter and H1 sit above `<!-- myspec:framework-start -->` and are project-owned; #55 direction B names the fix.
- new-sporticos-frontend renamed `memory-index.md` by hand before the framework did and pinned the old key; HEAD's "both exist → report and stop" is correct but leaves a pinned dead key forever.
- `doctor` still reads `.claude/rules/ai-setup-audit.md` as a fallback (`skills/doctor/SKILL.md:41`, `:150`).

**Design.**
- `frameworkFiles` collapses to pins only: `{ "<manifest key>": { "pinned": "<reason>" } }`. Drift is decided by content against the plugin copy, which is what the doctor already does.
- `aiDir` is required. `init` and `update` normalize it to one canonical spelling with no trailing slash (default `.ai` — majority among actively maintained consumers, and README already shows it); the detection fallback in the resolver and hooks is deleted. Static files keep copy-time `${aiDir}` substitution; skills read the value from `.myspec.json` and join paths.
- `marker-merge` gains a framework-owned header region: frontmatter plus H1 are rewritten from the plugin copy on every sync unless the entry is pinned.
- Manifest gains a `removed` block (`{ "<old key>": { "dest": ... } }`); `update` deletes those destinations and their `frameworkFiles` keys. Changes 2, 3, 5 and 7 all need it.
- `update` handles the sporticos case: new destination exists and the old key is pinned with no file behind it → drop the dead key and report "already renamed locally". Both files exist → offer to merge the old project section into the new file rather than stopping.
- `update` renames `.claude/rules/ai-setup-audit.md` → `doctor.md` once; the runtime fallback in `doctor` goes.
- `.myspec.json` gains `migrations: ["2.0.0-schema", ...]` so one-shot migrations are idempotent.

**Migration.** One-shot, run by `update` before the per-file loop. Fresh `init` writes the new shape only.

**Why major.** `.myspec.json` schema, `aiDir` canonical form, and the `marker-merge` contract change.

### 2. Move live session logs out of `${aiDir}/memory/sessions/`

**Problem.** Active session files are created by a PostToolUse hook on `Write|Edit|MultiEdit|NotebookEdit` inside the doc tree. Sixteen skills, hooks, templates and blueprints reference the path, and every layer that touches git or worktrees has needed a special case for them. The hook comment says the files are gitignored, but nothing in the framework writes that ignore rule (`init` ignores only `.claude/state/`).

**Evidence.**
- crm-front-app S013: an active session file was lost during a stash/reset sequence and reconstructed by hand. Exact command unrecorded; plain `git stash` and `reset --hard` leave untracked files alone, so the trigger was `-u`, `clean`, or a tracked copy.
- new-sporticos-frontend memory: Bash-driven edits (`sed -i`, heredocs, python scripts) never fire the hook, so no session exists; `session-complete` archives nothing and bootstrap reports no code touched.
- lockin memory: with three active sessions, `session-complete`'s "latest mtime" heuristic picked another agent's file; the fix was to match the `Context` line against the agent's own first edit.
- new-sporticos-frontend's isolation hook needed a carve-out so a worktree-mode session may still write to `memory/sessions/` in the main checkout.
- Legacy fields still in play: the hook writes a constant `cwd: <repo_root>` beside `worktree:` (`hooks/mark-code-changed.sh:214`); `session-clean` honours legacy `cwd:` and `status: archived` (`skills/session-clean/SKILL.md:17,45,46`).

**Design.**
- Live session state moves to `.claude/state/sessions/<session_id>.md` in the primary checkout (gitignored already, outside `${aiDir}`, same family as the ID registry and sporticos' `.claude/state/isolation/`). Markdown stays so `session-complete` keeps extracting from the narrative.
- Creation trigger widens: keep the PostToolUse edit matcher and add a PreToolUse `Bash` matcher that creates the file when the command matches a write pattern (`sed -i`, `>`/`>>` into a tracked path, `python3 -` with a write, `git apply`). Fallback: bootstrap creates the file for the current session unconditionally.
- Owner resolution: no `CLAUDE_SESSION_ID` exists for skills or Bash calls (only hooks receive `session_id` on stdin). The hook writes `.claude/state/sessions/current` containing its session id; skills read that pointer, never mtime. `session-clean`'s existing `CLAUDE_SESSION_ID` assumption is removed.
- Stop writing `cwd:`; drop the legacy `cwd:` and `status: archived` reads.
- Archive stays at `${aiDir}/memory/sessions/archive/` because archives are curated, committed knowledge.

**Migration.** `update` moves `sessions/active/*.md` to the new location and leaves a one-line note. `session-clean`, `session-complete`, `session-start`, `bootstrap`, `doctor`, `memory-preflight`, and the session template change path. `.gitignore` scaffolding already covers `.claude/state/`.

**Why major.** Path contract shared by 16 files and by consumer-local hooks (sporticos) changes.

### 3. Worktree isolation becomes a first-class framework surface

**Problem.** `guard-git-branch.sh` is the most worked-around framework artifact. It blocks branch mutation on the main checkout but the framework ships no sanctioned flow for what agents actually need: write code somewhere, get it onto a branch, open a PR, leave the user's checkout clean.

**Evidence.**
- lockin: four memories about the guard (`update-ref -d` bypass for bulk branch deletion, cd-first ordering, `.env` symlink trick, agent worktrees branching from main not the controller HEAD).
- image-generation-app: guard matched `git branch -M main` on an unrelated repo in the scratchpad; `eslint .` descends into `.claude/worktrees/`.
- crm-front-app: subagent PR creation leaves develop dirty; never symlink `node_modules` (the Stop hook refuses a symlinked tree unless `MYSPEC_ALLOW_LINKED_MODULES=1`, `verify-before-stop.sh:148`).
- new-sporticos-frontend built the missing surface itself: `rules/work-isolation.md`, `hooks/require-isolation-decision.sh` (PreToolUse Write|Edit, blocks the first source edit until the session records develop-vs-worktree), `hooks/guard-worktree-context.sh` (PreToolUse Bash, blocks builds/installs/pushes aimed at the wrong tree), `lib/set-isolation.sh`, `lib/promote-to-worktree.sh` (moves an uncommitted develop-mode diff onto a branch in a fresh worktree, commits, pushes, opens the PR, restores the main checkout, refuses when local develop is ahead of origin). A memory there records the failure it prevents: a PR based on local develop dragged in the user's unpushed WIP commit and broke CI.
- Issue #11 lists the same three provisioning gaps (base ref, `node_modules`, `.eslintcache`) for orchestrator-mode subagents.

**Design.**
- Adopt the sporticos surface as framework files: one rule (path-gated to source, not docs), two hooks, two lib scripts, plus the `.claude/state/` convention shared with change 2. Replace its `develop` literal with the detected default branch.
- `guard-git-branch.sh` folds into `guard-worktree-context.sh`: one hook, one state file, one block message. The branch-mutation list and the "names a worktree path → approve" rule stay.
- `promote-to-worktree.sh` becomes the default exit path of `feature-complete` and of any session that answered `develop`.
- Provisioning recipe in one place (`_shared/worktree-provisioning.md`): install deps for real unless the branch does not touch the lockfile; symlink only `.env`-class files; add symlinked dirs to `info/exclude`; copy lint cache. `feature-implement` and the new rule point at it.
- `.myspec.json` gains `isolation: { worktreeRoot: ".claude/worktrees", allowLinkedModules: bool }` so the Stop hook reads config, not an env var.

**Migration.** `guard-git-branch.sh` is a manifest `hooks` entry, so `update` removes it via the change-1 `removed` block. The wiring is the gap: `update` never edits `.claude/settings.json` by rule, and this change removes one registered command and adds a PreToolUse Write|Edit hook. See decision D2 below. Sporticos pin reasons become obsolete and `update` should say so.

**Why major.** A hook is removed and renamed; `hooks.json` gains a PreToolUse Write|Edit matcher; a new state directory and `.myspec.json` block become contracts.

### 4. Always-loaded rules become path-gated or trimmed

**Problem.** Seven rule files install to `.claude/rules/`; five are ungated and load on every turn. Ungated rules total 16 KB, plus `anti-patterns.md` (2.5 KB) and `pre-flight.md` (5.1 KB) where the project's CLAUDE.md imports them — roughly 6k tokens of standing context before the project's own instructions.

**Evidence.**
- crm-front-app pinned `workflow.md`, `auto-memory-style.md`, `ideas.md`, `anti-patterns.md` with the reason "trimmed for always-loaded context budget".
- new-sporticos-frontend pinned the same four plus `paths.md` and `memory-system.md` with the same reason, and gated `ideas.md` with `paths: .ai/ideas/**`.
- Two mature consumers reached the identical fix independently; every other consumer pays the full cost.
- Upstream already path-gates `skill-optimization.md` and `skill-self-test.md` via their own frontmatter, so the mechanism needs no new manifest field.

**Design.**
- Gate by `paths:` frontmatter in the source file: `ideas.md` → `${aiDir}/ideas/**`; `paths.md` → `${aiDir}/**`, `.claude/**`, `docs/**`. Copy-time `${aiDir}` substitution already reaches frontmatter.
- `auto-memory-style.md` stays an always-loaded rule but shrinks to a pointer-sized budget table. It cannot move into skill bodies: the harness writes auto-memory outside any myspec skill, and the rule governs those writes.
- `workflow.md` and `memory-system.md` stay always-loaded but shrink to the consumer-trimmed versions. Take the crm-front-app copies as the baseline (3.5 KB and 7.5 KB); anything procedural moves into the owning skill.

**Migration.** Pins are reported today, never silently skipped, but a pinned rule never receives the trimmed upstream. `update` must offer a three-way choice per pinned rule whose upstream is now smaller than the local copy: keep pin, take upstream, or diff.

**Why major.** File contents and gating of `.claude/rules/` change; pinned consumers need reconciliation.

### 5. Stop shipping unread framework files

**Problem.** `init` copies ten templates into `${aiDir}/.templates/` and a 209-line memory overview into `${aiDir}/`; most are read by nothing.

**Evidence.**
- `templates/README.md`, `templates/example-usage.md` (368 lines) and `templates/feature-pre-flight.md` are referenced by no skill, hook, or lib. Only `session-log.md` (session-start) and `memory-{type}.md` (memory-create) are read.
- `${aiDir}/memory-system.md` is read only by `doctor` surface D for layer budgets and the 30-day consolidation rule; `.claude/rules/memory-system.md` shares its basename and confuses routing.
- Every unread file is still a `framework-drift` candidate in the doctor and an `overwrite` entry `update` must process.

**Design.**
- Drop the three unread templates and `${aiDir}/memory-system.md`. Fold the budgets the doctor needs into `.claude/rules/memory-system.md`.
- Remaining templates keep their `.templates/` home; the session template moves with change 2 if its shape changes.

**Migration.** Change-1 `removed` block; `update` deletes the files and their keys.

**Why major.** Manifest entries and files disappear from consumer trees.

### 6. Retire orchestrator agent-chain mode

**Problem.** `feature-plan` can author plans with `orchestration: agent-chain`; `feature-implement` then dispatches `worker-base`, `spec-reviewer`, `quality-reviewer` role prompts via user-scope base agents that `init` step 5.5 and `update` step 3.5 install into `~/.claude/agents/`, `~/.cursor/agents/`, `~/.codex/agents/`. A per-project setup writes six files into three global directories with no uninstall and no per-project version — the same boundary violation changes 2, 3 and 5 exist to remove. Five open issues were filed against the mode (#10 retry oscillation, #11 worktree provisioning, #14 dispatch-only enforcement, #15 cross-harness shims, #18 probe-reviewer). **Verified 2026-09-03, after the change landed:** only three of them are mode-bound. #10 is arithmetic over the dispatcher's two per-kind retry counters, #14 gates on the run-mode choice, and #15 generates the six user-scope shims — all three vanish with the mode. #11 and #18 do not: #11 says so in its own text ("affects orchestrator and normal mode alike") and change 3 resolved it; #18's root cause — the agent that authors a verification step also decides whether to skip it — is untouched, since the controller still runs its own Step 4b checkpoint verification. #15 is the only harness-shaped one: shims maintained against contracts myspec does not control.

**Evidence.**
- The user-scope install is the load-bearing objection and needs no consumer report: `init` step 5.5 and `update` step 3.5 copy six agent files into three global directories. Nothing removes them, nothing versions them per project, and a second myspec project on the same machine silently shares them.
- lockin memory `feedback_orchestrator_chain_not_runnable_use_normal_fallback`: the chain needs Worker and both reviewers on the same per-task worktree, but `isolation: worktree` forks a fresh worktree from main on every dispatch and `worker-base` has no shell to cd — pick normal-fallback. Recorded as the standing instruction for that repo. **Scope correction:** this blocks parallel groups only. Sequential tasks dispatch into the controller's own worktree, where the chain does run; the memory should not be read as "the mode never runs".
- lockin memory `feedback_long_feature_implement_chains_slow`: multi-milestone runs are dispatch-latency-bound; one milestone per session. Per task the chain is Worker → SpecReview → QualityReview → Commit — three dispatches against normal mode's one review per phase. The finer gate *is* the latency.
- lockin memory `feedback_opus_holistic_review_catches_phase_misses`: the one part that paid off was the final full-diff holistic review, which does not need the role chain.
- No consumer memory records a successful agent-chain run — but lockin is the only consumer that tried it, so this reads as unproven, not disproven. It is supporting evidence, not the reason.
- Artifacts on HEAD: `skills/feature-implement/references/orchestrator-dispatcher.md`, `references/role-prompts/` (3 files), `skills/feature-plan/references/plan-templates-orchestrator.md`, the run-mode gate at `skills/feature-implement/SKILL.md:129`, agent sources under `skills/feature-implement/agents/{claude,cursor,codex}/`.

**Delta against normal mode.** Normal mode already dispatches a subagent per task, reviews with a diff package, triages by severity, runs a capped fix loop that escalates tier, checkpoints per milestone, and closes with the holistic review. Two properties do not survive the retirement:

| Chain-only property | Verdict |
|---|---|
| Review granularity is per task, not per phase | Not worth keeping — this is the latency complaint. A plan that wants a per-task gate puts one task in a phase. |
| Worker toolset is `Read, Edit, MultiEdit, Write` — no shell, so a Worker cannot edit a test or a lint config to make its own task pass | Worth keeping. Normal-mode implementers have Bash today. |

**Design.**
- Delete the artifacts above, the `orchestration:` plan frontmatter key, the run-mode gate, and the user-scope agent install in `init` and `update`. This reverts #17 (closed), which wired that install.
- Carry the no-shell property into normal mode: `implementer-prompt.md` forbids running test, lint, build, or install commands for the task's own verification. Verification stays with the phase reviewer, which already runs it from the plan and `.claude/verification.json`.
- Keep and promote what worked: per-task implementer subagent in one shared controller worktree (today's fallback), milestone-bound sessions as the default for plans with more than five tasks, and the mandatory end-of-run holistic reviewer on the strongest available model.
- **Issue disposition (applied 2026-09-03).** Closed #10 and #14 as won't-fix-by-design, #15 with the mode, and #11 as *completed* — change 3's `_shared/worktree-provisioning.md` and `lib/worktree-provision.sh` cover all three of its gaps, so it is done rather than re-scoped. #18 stays open: only its Phase-2 seam needed re-wording ("between the Step 4 phase review and the Step 4b milestone Checkpoint"); Phases 1 and 3 never depended on the chain. Note for whoever picks it up — the plugin now ships no subagent definitions at all, so a probe reviewer would be the first, and it must come from a plugin `agents/` directory, not a user-scope copy.
- If the mode is kept instead (decision D4), the only defensible form is shipping the agents from a plugin `agents/` directory rather than copying to user scope. That answers the boundary objection and nothing else — #10, #14 and #18 all remain (#11 is resolved either way, by change 3). Plugins support the directory; the dispatch name likely becomes `myspec:worker-base` and precedence over a user-scope copy is undocumented, so test first.

**Migration.** Existing plans with `orchestration: agent-chain` run as normal mode; `feature-implement` prints one line saying so. `update` offers to delete the six user-scope agent files.

**Why major.** A documented mode and its plan-frontmatter key are removed, and `init` and `update` stop writing to user scope.

### 7. Collapse and rename the skill surface

**Problem.** 44 skills; descriptions total about 11.7k characters (~2.9k tokens) loaded every session, with `doctor` alone at 642 characters against the repo's 500 rule. Families: 18 `feature-*` plus `features-status-audit`, 5 `memory-*` plus `memorize` and `memorify`, 3 `session-*`, 2 `idea-*`, 13 other. Names are inconsistent where a rename is already landing (`ai-setup-audit` → `doctor`).

**Evidence.**
- Audit B6 still holds: `feature-scenario` and `feature-seed-data` have no inbound route except `rules/workflow.md`; `idea-process` re-implements both inline as steps 7–8.
- `docs-sanitize` is routed to by nothing; its three jobs are already `doctor` surface C (naming, dead references) and `session-clean` (misplaced sessions).
- `features-status-audit` is the only plural skill; `memory-sanitize` (user-level store) and `memory-optimize` (project store) do not say which store they groom; `session-clean` sits beside `worktree-cleanup`.
- Consumers add their own skills on top (crm-front-app has five), so every framework description competes with project descriptions for the same budget.

**Design (revised 2026-09-04 — the collapse was built, then dropped).**
- Descriptions are rewritten, not truncated: each keeps its trigger condition, drops keywords derivable from the skill's own name, and keeps only the one "Do NOT" naming a genuinely confusable neighbour. **43 skills, 9,548 chars, none over 350.**
- `docs-sanitize` retires. `features-status-audit` → `feature-status-audit` (the only plural name; `lib/` dir renames with it). `worktree-cleanup` → `worktree-clean`.
- **The argument-routed collapse is NOT adopted.** It was implemented in full — `memory save|scan|lookup|preflight|optimize|sanitize`, `session start|complete|clean`, `idea intake|process`, plus folding `feature-mockup-review` into a `--review` mode and `feature-scenario` + `feature-seed-data` into `feature-spec` — reaching 31 skills and 6,826 chars, and then reverted.

**Why the collapse was reverted.** It removed 13 entry points from slash-command autocomplete (memory −6, session −2, idea −1, mockup-review −1, scenario + seed-data −2, docs-sanitize −1). Autocomplete completes *skill names*; an argument is free text it cannot see, and skill frontmatter has no `argument-hint` — that is a custom-slash-command feature, not a skill one. So `/myspec:memo…` stopped offering seven completions and offered one, with the six modes discoverable only by reading the router's Modes table. The maintainer uses that completion heavily. The diet alone captures −36% (14,965 → 9,548); the collapse would have added a further ~2,600 chars of saving, about 650 tokens a session. That was judged the wrong trade against daily discoverability.

Two secondary costs the collapse also carried, both avoided by the revert: `memory-lookup` and `memory-preflight` are `allowed-tools: [Read, Grep, Glob]`, read-only by construction, and a merged skill that also writes cannot be — the restriction would have degraded to prose. And the retirement stubs are live skills for one minor cycle, so the surface would have been 49 files and 7,905 chars until they were removed.

- Original target was ≤30 skills, ≤350 chars each, under 7k total. **≤350 each is met; the count and total targets are deliberately missed** — they were only reachable by collapsing entry points.

**Migration.** Plugins have no alias or redirect mechanism; an old name simply fails. Three stubs — `features-status-audit`, `worktree-cleanup`, `docs-sanitize` — each name their replacement and stop; removed one minor cycle after 2.0. `rules/workflow.md`, README, `examples/`, and the affected `Integration` sections update with the renames.

**Why major.** Skill names are removed and renamed, which RELEASING.md defines as major.

## Non-breaking changes worth riding along

- **Doc commits default to the feature branch at every skill boundary.** `feature-spec` step 6 offers "Commit to {HEAD}" first. lockin lost three edited spec files when a pull touched the working tree between `feature-update` and `feature-implement`; new-sporticos-frontend's memory says never commit docs to develop. Make "new branch" the recommended option when HEAD is the default branch; `feature-update`, `cross-spec-validation` and `feature-plan` each end with a commit step.
- **Plan DAG orders by data dependency, not only file overlap** (lockin memory: a consumer task was scheduled before its producer because the files were disjoint). One sentence in `feature-plan` step 4.
- **Dogfood the migration in a throwaway worktree.** The framework repo deliberately keeps no `.myspec.json` or `${aiDir}` tree (AGENTS.md is its project memory). Running `init` at 1.28 and then the 2.0 `update` inside a disposable worktree exercises every one-shot migration without changing that decision.
- **Keep `index.yaml` notes to one line** (sporticos memory) — a sentence in `feature-spec` and `feature-complete`.

## Decisions

All four decided 2026-09-03: the recommendation column is the decision. Change 1 is in progress on `feat/2.0-schema`.

| # | Decision | Recommendation (adopted) |
|---|---|---|
| D1 | Upgrade base: any 1.x, or 1.28 first? Any-1.x keeps the pre-1.23 index migration (`LEGACY_HEADINGS` in `lib/memory-files.mjs`, the header migration in `memory-index.mjs`, `legacy-index` in `memory-doctor.mjs`, the legacy-row regex in bootstrap, `update` step 3.6) and adds four new one-shots on top. | Require 1.28: 2.0's `update` refuses a lower `frameworkVersion` with "run the 1.28 update first". Consumers at 1.0.0 (three repos) and 1.6.0 pay one extra run; the legacy path is deleted. |
| D2 | Who edits `.claude/settings.json` hooks wiring? Today `update` reports and never edits. Change 3 removes one command and adds one. | Let 2.0's `update` own the `hooks` key: deep-merge from `templates/settings-hooks.json`, remove commands listed in the manifest `removed` block, touch nothing else in the file. Otherwise the doctor's `wiring-incomplete` becomes a permanent 2.0 warning. |
| D3 | `aiDir` canonical default: `.ai` or `ai`. | `.ai` (README, resolver default, and the maintained consumers already agree). |
| D4 | Retire agent-chain mode (change 6) or fix it (issues #10–#15, #18). | Retire — because `init` writes six agent files into three user-scope directories with no uninstall, and the chain's one unique property (a Worker with no shell) ports to normal mode in a line. "No successful run on record" is one consumer and does not carry the decision. |

## Migration from any 1.x

- `update` already walks the manifest per file. 2.0's `update` runs the one-shot migrations first, in this order: schema and `aiDir` normalization (1), rename reconciliation (1), sessions relocation (2), removed-file deletion (1, 3, 5), agent-file removal (6). Each records itself in `migrations:` so re-runs are no-ops.
- Pinned files are the main risk. Six pins across two repos all say "trimmed for always-loaded cost"; when upstream is now smaller than the pinned copy, offer to unpin (change 4).
- Hooks travel together: a consumer without `.claude/hooks/` skips all hook and lib entries today. 2.0 adds a PreToolUse Write|Edit hook, a PreToolUse Bash session trigger, and a state directory; the skip rule stays, but the doctor should flag "hooks absent" as a warning, not silence.
- Per-project hook and lib copies stay. Every lib helper is called by a hook, and hooks must run for teammates without the plugin, which Claude Code does not auto-install from `enabledPlugins`. The Codex mirror under `plugins/myspec/` stays unless Codex accepts a root-path plugin (unverified).

## Suggested order

1. Change 1 (schema, `removed` block, marker header, rename reconciliation) — every later migration depends on it. Settle D1–D3 first.
2. Change 2 (sessions) and change 3 (isolation) together — they share `.claude/state/`.
3. Change 4 (rules) and change 5 (unread files) — both shrink what `init` writes; needs the pin reconciliation from step 1.
4. Change 6 (retire orchestrator) — deletion, plus the no-shell clause added to `implementer-prompt.md`, once D4 is settled.
5. Change 7 (description diet and renames) — last, because it renames the entry points every earlier step documents.
6. Non-breaking items fold into whichever step touches the same skill.
