# myspec Improvement Report

Repo @ `faa53e2` (v1.18.0). Four parallel audits: token efficiency, cross-skill consistency, precision/contradictions, supporting infrastructure. Findings deduplicated and merged; items confirmed independently by 2+ agents are marked ✓✓. No edits made.

Note: the repo has **40** skills (41 dirs in `skills/` including `_shared/`, which has no SKILL.md). README's own count and tables are off (see C.9).

---

## A. Bugs — would cause wrong behavior today

### A1. The status state machine has no owner ✓✓
The lifecycle gates hard-require statuses that no skill ever sets.

- `feature-tech-spec/SKILL.md:10` and `feature-plan/SKILL.md:27-28` require `spec.md status: approved` — but `feature-spec-review` never writes `status: approved` (its Execute step, lines 66-69, updates only `spec_version` + date). Same for `feature-tech-spec-review` (Step 8 updates `last_updated` only). The transition exists only in `examples/flows/full-feature-delivery.md:19,192`.
- `feature-complete/SKILL.md:48` says "in-progress → complete", and `scaffolding/features/index.yaml` says the manifest is "Managed by /myspec:feature-spec, /myspec:feature-complete" — but neither `feature-plan` nor `feature-implement` ever sets `in-progress`. Consequence: `feature-verify` Step 4 flags **every** feature mid-implementation; `features-status-audit` reports "docs ahead" for every normally-run feature.
- **Deadlock:** `feature-update` Step 3 resets `status: draft` ("requires re-approval"), then Step 6 offers routing straight to `feature-plan` — whose gate requires `approved`. No re-approval path is required in between.

**Fix:** Document the canonical enum + transitions + owning skill in `framework-files/rules/workflow.md` (currently just "draft → in-progress → complete" at line 70). Add explicit status-write steps: review skills set `approved` on pass (with user confirmation), `feature-implement` Step 2 sets index.yaml `in-progress`, `feature-update` Step 6 routes through re-approval.

### A2. Installer bugs (init / update) ✓✓ (found by 4/4 agents)
- `init/SKILL.md:54-85` writes `.myspec.json` with `"frameworkVersion": "1.6.0"` and every file pinned `"1.6.0"` while `framework-files/manifest.json` is at `1.18.0`. Every fresh init immediately triggers bootstrap's "12 versions stale — run /myspec:update" warning. `README.md:121,128` repeats the literals. Fix: instruct reading the version from manifest.json at runtime; `bump-version.sh` doesn't touch these literals.
- init's `frameworkFiles` inventory lists **5 of 7** rules files (missing `rules/paths.md`, `rules/skill-self-test.md` which Step 5 and the manifest install) → `update`'s per-file bookkeeping has no slots for them. The JSON block also contains a `//` comment — invalid if copied literally.
- **Template-path split:** init installs templates to `${aiDir}/.templates/` and all memory/session skills read there (`memorize:58`, `memorify:76`, `memory-create:53`, `session-start:42`) — but `update/SKILL.md` Step 2 maps `files` entries to `{aiDir}/{filename}`, i.e. `${aiDir}/templates/…`. Update creates a parallel tree and `.templates/` goes permanently stale. Fix: filename→destination mapping in update.
- init creates `memory/sessions/.gitkeep` only — never `sessions/active/` + `sessions/archive/`. The hook `mkdir -p`s `active/`; **nothing ever creates `archive/`**, so the first session-complete/bootstrap archive `mv` fails.
- init Step 4 never copies `templates/example-usage.md` into `.templates/` even though its own `.myspec.json` list (line 76) and manifest.json track it → tracked-but-missing file flagged forever by update.

### A3. Session-model schism ✓✓
Two incompatible session models ship simultaneously.

- **Current model** (hook + session skills): `${aiDir}/memory/sessions/active/{session_id}.md` (`hooks/mark-code-changed.sh:90`, session-start/complete/clean, bootstrap).
- **Legacy single-file `sessions/active.md`** survives in 6 shipped files: `memory-preflight/SKILL.md:63`, `framework-files/pre-flight.md:20,44,54`, `framework-files/memory-system.md:109` (contradicting its own line 18), `framework-files/templates/example-usage.md:22,330`, `templates/README.md:38`, `templates/feature-pre-flight.md:17`. All manifest-managed — overwritten into every consumer project.
- `docs-sanitize/SKILL.md:25-28,52,68,82` targets extinct `session-log.md` files and archives to `${aiDir}/sessions/` (a location nothing else uses) with a 7-day staleness rule contradicting the 60-min policy elsewhere. **As written the whole skill is a no-op or actively harmful.**
- **Archive trichotomy:** session-complete → `archive/YYYY-MM-DD-{slug}.md` + `status: completed`; session-clean → `archive/{session_id}.md` + `status: archived` (git mv); bootstrap → `archive/YYYY-MM-DD-orphaned-{first8}.md` + `status: abandoned` (plain mv). session-clean's own gate refuses archives whose status isn't `archived`/missing — it can't process the other two skills' output. memory-create requires `status: completed`, so session-clean-archived sessions are invisible to it.
- **Threshold conflict:** bootstrap silently auto-archives anything >60 min old; session-clean treats 1–6h as "ambiguous → ASK" (and is internally contradictory about it, Step 3); session-start says "multiple-active is normal in multi-agent workflows" — bootstrap's silent mv destroys exactly those.
- Hook writes a constant placeholder `cwd: <repo_root>` (`mark-code-changed.sh:114`) — session-clean's worktree-liveness gate reads `cwd`, which carries zero information as written.

**Fix:** one convention block (file naming, terminal statuses, thresholds, archive path) in rules/memory-system.md; sweep all `active.md` references; rewrite or delete docs-sanitize's session section; make bootstrap confirm or delegate to session-clean; fix the hook's `cwd`.

### A4. Hooks
- **`validate-frontmatter.sh` is doubly broken:** (1) warnings go to stdout with exit 0 — under the PostToolUse contract the model never sees them (sibling hooks `no-absolute-paths.sh:140`, `require-reuse-audit.sh:124` do it correctly with exit 2/JSON); (2) its required fields (`title|name` + date) contradict the framework's own shipped templates — session-log.md, all three memory templates, and hook-generated session files all "fail" it. Only bug (1) hides bug (2). Fix field list first, then output channel.
- **`guard-git-branch.sh` blocks `feature-complete`:** the hook blocks `git checkout/switch/merge/branch -d` on the main checkout (lines 78-84); `feature-complete/SKILL.md:117-122,150-153` (Options 1 & 4) instructs exactly those commands. With hooks installed, feature-complete's merge/discard paths cannot execute. Neither skill mentions the hook.
- `verify-before-stop.sh:10-13` loop guard checks env vars; the harness signals re-entry via `stop_hook_active` in stdin JSON (never read). Marker-file trap saves it in practice; guard is dead code.
- Matchers `Write|Edit` miss `MultiEdit`/`NotebookEdit` (hooks.json:16) — session auto-creation and stop-verification skip those edit paths.
- Minor: `resolve_repo_root` fallback depth differs across hooks (`../..` vs `..`); `validate-frontmatter.sh:90` shells `$FILE_PATH` into inline python3 (quote-injection + python3 not guaranteed); `verify-before-stop.sh:130` IFS multi-char join never renders `---` separators.

### A5. Plugin packaging / mirror drift ✓✓
- `plugins/myspec/lib/` is missing `features-status-audit/` (verified `diff -rq`). `features-status-audit/SKILL.md:20` runs `node "${CLAUDE_PLUGIN_ROOT}/lib/features-status-audit/audit.mjs"` → **broken under the Codex local-wrapper plugin root.** Precedent fix on record: brainstorm-server was mirrored for exactly this reason (`plugins/myspec/upstream-sources.yml` divergence note).
- `.github/workflows/sync-check.yml` diffs only `skills/` ↔ mirror — `hooks/`, `hooks.json`, `lib/`, `.codex-plugin/` are unguarded (exactly where drift occurred). AGENTS.md:32's sync rule is also scoped to skills only.
- The wrapper can't run init/update/setup at all (`framework-files/`, `blueprints/`, `scaffolding/`, `templates/` don't exist under `plugins/myspec/`) — mirror them or document the limitation.
- `hooks.json` commands are cwd-relative (`./hooks/…`); documented plugin form is `${CLAUDE_PLUGIN_ROOT}/…`. Only Codex manifests consume it — verify resolution or every Codex hook silently no-ops.

### A6. `ideas/` path and scaffold gaps ✓✓
- `idea-intake/SKILL.md:18,19,72` and `idea-process/SKILL.md:9,16,22,100,101` (and `rules/ideas.md:10`) reference repo-root `ideas/` — init scaffolds `${aiDir}/ideas/`. On default aiDir the skills miss the real tree and may create a second one. Fix: `${aiDir}/ideas/` everywhere.
- idea-intake:83,108 and idea-process:103 update a "Quick Stats" section that `scaffolding/ideas/PRIORITY-LISTING.md` doesn't contain. `ideas/processed/` is never scaffolded either.
- Scaffold seed lists 4 priority sections; intake instructions offer 5 (…LOWEST).

### A7. Wrong field names / schemas ✓✓
- `feature-spec-cleanup` Step 7A creates tech-spec.md with `spec_version`, `phase`, `version`, `load_when`, `see_also` — canonical schema (`feature-tech-spec:36-43`) is `title, status, based_on_spec_version, created, last_updated`. Its Step 8 checks `spec_version` in tech-spec (wrong key: `based_on_spec_version`). It also bumps spec's `spec_version` without touching tech-spec's `based_on_spec_version` — manufacturing the exact Critical mismatch three other skills hunt.
- `feature-spec-review` Step 8 updates the "`updated` date" — the field is `last_updated` (feature-spec:26-27). Literal agents add a stray field.
- `cross-spec-validation` Step 7 bumps related specs' `spec_version` with no instruction to flag their tech-specs' `based_on_spec_version` → every executed fix creates a latent Critical in a different feature.

### A8. Plan documents have no frontmatter template
`feature-plan/references/plan-templates.md` contains no header/frontmatter template (verified), yet `feature-complete:56` reads plan `title` for archive naming and `feature-verify` Step 4 compares plan `last_updated` for staleness. Normal-mode plans lack both fields (and trip `validate-frontmatter.sh` once that hook is fixed). Fix: add canonical plan header (title, feature, status, created, last_updated).

### A9. Routes to skills that don't exist in this plugin ✓✓
- `feature-implement/SKILL.md:4` → "use dispatching-parallel-agents" (doesn't exist; correct target is `root-cause-debugging`)
- `feature-plan/SKILL.md:8` → "use writing-plans" (doesn't exist)
- `skill-verify/SKILL.md:8,122,328-330` → "use writing-skills" / "Called by: writing-skills" (doesn't exist)
These are obra/superpowers names. Fix: point at in-repo skills or mark as external-if-installed.

---

## B. Precision & consistency — canonicalize one answer

### B1. Status/priority/completion vocabulary
- Manifest enum `planned | draft | in-progress | complete` (scaffolding/features/index.yaml:3) omits `deprecated`, which feature-verify, features-status-audit, and audit.mjs all accept.
- `feature-decompose:110,260` writes `in-progress` into **spec.md** frontmatter — spec-level enum is `draft|approved|deprecated` → every decomposed parent gets flagged by feature-verify.
- No skill ever writes `status: planned`; idea-process creates manifest entries with no status and demands a "[PLANNED]" name-tag defined nowhere else.
- Doc-requirement matrices disagree: feature-verify Step 9 says `in-progress` **requires** tech-spec; features-status-audit says **expected**.
- Completion %: feature-spec-sync:152 ">80% = complete" (from tech-spec checkboxes) vs feature-verify "<100% ≠ complete" (from plan checkboxes) vs feature-complete's "before all tasks done" frontmatter that contradicts its own deferred-tasks handling (lines 7 vs 69-70). Pick plan checkboxes as the single source.
- Priority scales: feature-spec `P{0|1|2}` vs feature-decompose `{P1|P2|P3}` vs scaffold `P0–P3`. Standardize on P0–P3.

### B2. Naming/artifact drift
- `seed/` directory (description + rules/workflow.md:60) vs `seed.json` file (what feature-seed-data and idea-process actually create). Fix description + rule.
- Two files self-describe as "Layer 1 always-loaded memory index": `${aiDir}/memory/index.md` (bootstrap:29, memory-preflight:13, promotion target in 3 skills) vs `${aiDir}/memory-index.md` (framework-files/memory-index.md:1-10). Rename/re-describe one.
- Sub-manifest keys: boolean `subfeatures:` vs generated top key `sub-features:` (feature-decompose:119,142); audit.mjs accepts three spellings. Pick one.
- "GraphQL Schema" residue: tech-spec template says "API Schema" but feature-tech-spec-review Step 2 and feature-update Step 4 still check/update "GraphQL Schema".
- `rules/memory-system.md:5` `load_when: path_matches: "${aiDir}/sessions/**"` — wrong path (sessions live under `memory/sessions/`).
- `docs-sanitize/SKILL.md:3` hardcodes "ai-docs" in its description; `rules/paths.md` forbids exactly this.
- `require-reuse-audit.sh:107-109` block message hardcodes Vue-monorepo surfaces ("packages/*, app lib/…") in a technology-agnostic framework.

### B3. Review-family behavior split
- Opposite fix-application defaults: feature-spec-review "do NOT proceed without explicit approval" vs feature-tech-spec-review "small issues: apply immediately without asking". Pick one policy (the small/big split is the better one).
- feature-spec:92 tells authors to use "may" for optional requirements; feature-spec-review:92,105 auto-flags every `\bmay\b`. Exempt RFC-style usage.
- Milestone pause: feature-plan:290 promises a pause after **each** milestone; feature-implement Step 4b skips the final one. Align the promise.

### B4. Memory-capture family ✓✓
- memorize/memorify write files directly with **no consolidation (ADD/UPDATE/NO-OP) check** — only memory-create has it, so /memorize and /memorify silently duplicate memories.
- `related` field: memory-create says "Always set"; memorize:80 says "skip on first capture".
- memory-create's description ("…or direct capture") overlaps memorize's entire territory.
- Fix (also the token fix): route memorize/memorify's write step through memory-create, as session-complete already does; narrow memory-create's description to backend use.

### B5. Structure — the framework fails its own linter
skill-verify's Structure Rules (SKILL.md:170-176) vs fleet:
- `## Workflow` in 28 skills; `## Instructions` in 7; `## Procedure` in 2; none in feature-complete.
- `## Verification Checklist` in 35; case-variant in 1; `## Checklist` in 2; **missing** in feature-complete, worktree-cleanup.
- Step headings: `### Step N:` (12 skills) vs `### N.` (17).
- Guardrail headings: Rules / Constraints / Hard guards / Notes; pitfalls: Red Flags / Common Pitfalls — skill-verify's accepted set doesn't include several.
- REQUIRED/OPTIONAL integration markers (skill-verify Anti-Pattern #9, High): compliant in 4 skills, absent in ~10 including skill-verify itself.
- Frontmatter: field order drift (3 skills), quoted vs unquoted `name` (26/14), trigger-label drift (Keywords/Triggers/Trigger phrases/Example invocations/none), `tags` on 19/40 with `feature` vs `feature-workflow` split, `allowed-tools` on only 3 of the read-only skills (skill-verify's own Anti-Pattern #11).
- Invocation-form drift in descriptions: bare name vs `/myspec:name` vs `/memorize`-style (the latter don't resolve — plugin form is `/myspec:memorize`). Canonicalize to `/myspec:name`.

### B6. Near-orphan skills & pipeline gaps
- feature-scenario and feature-seed-data: no Integration section routes to them; idea-process Steps 7-8 re-implements both inline. Either delegate or fold in.
- cross-spec-validation appears in 5 Integration sections but not in rules/workflow.md's pipeline table.
- feature-scenario description says "Requires approved spec.md"; its Prerequisites only require existence.
- idea-process ignores user-named ideas (always picks highest priority) and reads `${aiDir}/features/README.md`, which nothing creates.
- memory-preflight Step 1 verify ("≥1 relevant critical entry") is unsatisfiable on the fresh-project empty index — no empty branch.
- brainstorm loads references by repo-relative path (`skills/brainstorm/techniques.md`) instead of `${CLAUDE_PLUGIN_ROOT}`.
- feature-verify internal: Step 3 rates version mismatch High; its own report example (line 160) shows Critical.

---

## C. Token reduction (quantified)

Descriptions: 14,322 chars ≈ **2,600 tokens loaded every session**. Bodies: ~6,500 lines ≈ **55K tokens** total, paid per invocation. 6 skills already use `references/`; the four biggest review skills use none.

1. **Descriptions (~450–500 tok/session, highest leverage).** 6 exceed the repo's own >500-char rule (skill-verify:88): feature-implement-review 561, setup 554, code-review 526, feature-verify 516, brainstorm 515, session-clean 511. Cut: keyword permutations ("review code / review my code / review changes…", "feature check" + "check feature"), workflow leakage (feature-tech-spec-review enumerating all 10 dimensions — duplicating its body table; setup listing all 8 blueprints with glosses), behavioral detail (session-clean's skip-rules). Target ~350 chars each.
2. **skill-verify ↔ rules/skill-optimization.md double-load (~1,300 tok/invocation).** The rule has `load_when: skill_invoked: skill-verify` so both always co-load, and they duplicate the portability-tier table, token-targets table, formatting rules. Also move the ~50-line Detection Patterns regex block (230-279) to references/ — skill-verify's own Anti-Pattern #10.
3. **Dead "Example Usage / Expected behavior" sections (~600 tok, zero risk).** skill-verify:306-324, feature-tech-spec-review:267-283, feature-spec-review:208-222 — 1:1 restatements of the workflow above them. Delete.
4. **Shared review-output boilerplate (~1,200 tok).** Identical findings-table header + fix-proposal diff examples + severity table across 5-6 review skills → extract to `_shared/review-output.md`, keep one example row each.
5. **Memory triplication (~900 tok).** Classification tables + per-type fill instructions + Layer-1 promotion duplicated across memorize/memorify/memory-create → route through memory-create (also fixes B4).
6. **feature-scenario's orphaned reference (~600 tok, zero risk).** `references/template.md` (58 lines) exists but SKILL.md never mentions it and inlines the same template. Point at it.
7. **init/update twins (~800 tok).** aiDir-marker block verbatim ×2 (17 lines), base-subagent install/sync blocks, stale `.myspec.json` inventory (fixing A2 shrinks it too).
8. **Commit-decision blocks (~400 tok).** feature-spec Step 6 + feature-plan Step 7 duplicate each other and `_shared/git-helpers.md` — compress to AskUserQuestion options + pointer.
9. **Checklist/workflow mirroring (~650 tok).** skill-verify (24 items), feature-plan (21), feature-tech-spec-review (17), update (11) — cut step-echo items, keep outcome checks (per rules/skill-optimization.md's own rule).
10. **Inline example compression (~1,100 tok).** feature-decompose's 33-line completion template (has references/templates.md already), feature-seed-data's 3 JSON examples, bootstrap's 15-line bash loop, session-clean's 5-row worked table.

**Aggregate: ~450–500 tok/session + ~8,000–9,500 tok/invocation (~15% of body total), concentrated in the most-invoked skills. Low-risk subset alone (#3, #6, #10, parts of #7): ~3,000 tok.**

`examples/` (396K) costs **zero runtime tokens** (nothing loads it; pure human docs) — keep it, but it drifts: Reuse-audit section (mandated by feature-tech-spec + hard-blocked by require-reuse-audit.sh since v1.14.0) appears in **zero** examples including the freshly-synced flow; bootstrap example is 2 steps behind; examples/README's coverage list omits features-status-audit and upstream-sync.

---

## D. Hygiene / docs
- README: "five always-loaded rules" → seven; consumer layout shows `templates/` (should be `.templates/`) and a `specs/` dir nothing creates; Skills Reference omits features-status-audit and upstream-sync; Codex install still points at `--ref feat/codex-plugin-support`.
- Dead scaffolding: `scaffolding/conventions|decisions|plans|sessions` are .gitkeep-only and referenced by nothing (sessions/ doubly vestigial). Delete.
- `rules/workflow.md:7` see_also → `${aiDir}/conventions/documentation.md` — never created by anything.
- session-log template lacks `session_id`/`auto_created`/`cwd` fields that the hook writes and session-clean reads.
- `.idea/.gitignore` tracked while `.gitignore` ignores `.idea`.
- `lib/brainstorm-server/start-server.sh:94-98` dead "kill existing server" block (PID file is inside the just-created unique dir).
- audit.mjs: parses `topKey` but never consumes it.
- anti-patterns blueprint writes to `memory-index.md` which setup:73 forbids modifying — works only because it appends to the project section; add a clarifying note.

---

## E. Suggested execution order (PR-sized chunks)

1. **Correctness sweep** (small, mechanical): A2 installer fixes, A5 mirror + CI-guard widening, A7 field names, A9 dead routes, A6 ideas paths + scaffold, A8 plan header, hook output-channel + field-list fix (A4).
2. **Session lifecycle unification** (A3): one convention block in rules/memory-system.md; sweep active.md references; fix docs-sanitize, bootstrap threshold, hook cwd; init scaffolds active/+archive/.
3. **Status state machine** (A1 + B1): canonical enum/transitions/owners in rules/workflow.md; add status-write steps to review/implement skills; align priority scale and completion rules.
4. **Token diet** (C): descriptions first (every-session cost), then the low-risk deletions, then shared-block extraction.
5. **Style canonicalization** (B5): headings, step format, frontmatter conventions — then run skill-verify across the fleet as the acceptance check.
6. **Docs/examples catch-up** (D + examples drift): README counts/layout, Reuse-audit in examples, PR-checklist line for example sync.
