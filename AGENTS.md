# Agent Conventions for myspec

This file applies to agents working **on** the myspec framework itself (this repo). For agents working **with** myspec in a downstream project, see the per-project AGENTS.md / CLAUDE.md that `init` writes.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) — `<type>(<scope>): <subject>`.

**Types used in this repo:**

| Type | Use for |
|------|---------|
| `feat` | New skill, new capability, new convention |
| `fix` | Bug fix in a skill, hook, template, or framework file |
| `refactor` | Restructuring without behavior change (decoration removal, dedup, voice cleanup) |
| `refine` | Local convention for quality refinement of an existing skill (e.g., applying skill-verify guidance) |
| `docs` | README, AGENTS.md, comments — not skill bodies (those are `feat`/`fix`/`refactor`) |
| `chore` | Version bumps, dependency updates, repo maintenance |
| `ci` | Hooks, GitHub Actions, automation |

**Common scopes:** `skills`, `<skill-name>` (e.g. `skill-verify`, `feature-implement`), `plugin`, `paths`, `upstream-sync`.

**Rules:**

- Subject line under ~70 chars, imperative mood, no trailing period.
- Multi-skill changes: use `skills` scope and list skill names in the body.
- Single-skill changes: use the skill name as the scope (e.g. `fix(feature-plan): ...`).
- Body explains the *why* — the *what* should be visible from the diff.

## Mirrored trees: changes touch both

The repo keeps parallel trees under `plugins/myspec/` (the Codex local-source plugin root): `skills/`, `hooks/`, `hooks.json`, `lib/`, and `.codex-plugin/` are byte-for-byte mirrors of the top-level trees. When you edit any of them, mirror the change in the same commit — CI (`.github/workflows/sync-check.yml`) diffs all five surfaces. The `chore(plugin): reconcile skill drift` commit and the once-missing `lib/feature-status-audit/` mirror both exist because this slipped.

## Examples track skills

`examples/` is human documentation of skill behavior and drifts silently (the Reuse-audit section shipped in v1.14.0 and reached the examples only in the 2026-07 audit). When a PR changes a skill's workflow, outputs, or gates, update the matching `examples/skills/*.md` / `examples/flows/*.md` in the same PR or state in the PR body that examples were checked and unaffected.

## Stack-agnostic content

myspec runs in JS, PHP, Python, Go, Ruby and JVM repos alike. Everything in `skills/`, `blueprints/`, `framework-files/`, `templates/`, `lib/`, `hooks/` and `examples/` is read downstream as the rule, so none of it may state one ecosystem's tooling as the rule. PRs #108 and #109 both shipped one ecosystem's tooling (Prisma, pnpm, bullmq, fixed ports) until review caught it; `feature-verify`'s File Inventory regex (`(apps|packages)/…\.(ts|tsx|vue|js|…)`) silently skipped every PHP, Python and Go path, and `backbone-audit` only knew Prisma, Drizzle and `db/schema.sql` as database markers.

- **Detection patterns are multi-language or derived from project config.** A regex, fence-tag list, marker list or extension list either covers the common stacks as data (`DATABASE_MARKERS` in `lib/backbone-audit/audit.mjs`, `KNOWN_EXTS` in `lib/feature-spec-sync/dead-paths.mjs`) or reads the project's own stack (`backbone.yml`, `${aiDir}/conventions/`). A pattern tied to `apps/`/`packages/` or to JS extensions is a bug.
- **Examples name the variable, not the command or address.** A command or address copied from an example reads as the rule. Name the variable and what it must point at (`$SCRATCH_API_URL`, "`DATABASE_URL` → the scratch database"), never `localhost:<port>` — moving to a less common port is not a fix, and the common defaults are the ones a developer's own dev server holds. Where a command is needed, give a placeholder or pair it with a non-JS one (`npm run lint` / `ruff check .`). `scripts/check-no-localhost-ports.sh` enforces the address part in CI across skills, blueprints, framework files, templates, and examples. It is not a shipped hook, because downstream projects legitimately write their own localhost URLs.
- **Before a PR**, run `git grep -niE 'prisma|pnpm|bullmq|node_modules|eslint|localhost:[0-9]' -- skills blueprints framework-files templates lib hooks examples` and read every hit you added: a multi-stack list, a test fixture, a JS-only template (`templates/mockup-preview/vue/`), or a worked example narrating one project's session is fine; a single-stack rule is not. The grep is not in CI because those legitimate hits outnumber the bugs.

## Skill quality

When writing or editing skills, follow the principles enforced by the `skill-verify` skill (`skills/skill-verify/SKILL.md`). The two highest-impact rules:

- **Descriptions are triggers, not summaries.** Start with "Use when…", avoid sequential workflow verbs ("analyzes X, generates Y, validates Z") — the agent will skip loading the body.
- **Format SKILL.md for the model, not humans.** No decorative blockquotes, horizontal rules inside body, ASCII diagrams, or all-caps imperative walls without rationale. Tables and numbered procedures are good; decoration is paid for in tokens on every load.
- **Never declare plugin-internal paths in a shipped skill's `dependencies:` block.** `skill-self-test` validates `dependencies: paths:` against the *consumer* repo's working tree; a path like `skills/feature-mockup-review/references` exists here but in no consumer project, so the self-test would false-fail as Critical everywhere the plugin is installed. (Caught during the v1.20.0 mockup-skill audits, 2026-08-03.)
- **A dispatched subagent cannot reach the user.** Never tell one to ask the user something. Have it mark the blocked work and return a structured line naming what would unblock it (the probe executor's `NEED:` lines); the controller asks and re-dispatches with the answer in a named prompt field. Otherwise the gate stays blocked with no way for the answer to arrive. (PR #109 review, 2026-09-27.)
- **Gate on a command's exit status, not only its output.** `git diff --stat <sha> HEAD` with a sha that no longer exists (after a rebase or squash) exits 128 with empty stdout, which a skill checking "output is empty" reads as "nothing changed". Write "exits 0 with empty output". (PR #109 review, 2026-09-27.)

## Quality gates

Each check sits in the cheapest layer that can catch its failure. The reasoning and the fix-commit history behind each layer are in `docs/quality-monitoring-research-2026-09-29.md`.

| Layer | What | Where it runs |
|-------|------|---------------|
| Static lint | `node scripts/lint-skills.mjs`: frontmatter, "Use when" + "Do NOT" description rules, dead links and anchors, step pointers, size budget | pre-commit (staged content), CI |
| JS lint | `scripts/lint-js.sh`: pinned `eslint:recommended` on `lib/` and its mirror, because `update` copies `lib/` into projects whose own lint then runs on it | pre-commit (staged lib JS, skipped when eslint can't run), CI |
| Shell lint | `scripts/lint-sh.sh`: ShellCheck at default severity on `hooks/` and `lib/` (tests included) and their mirrors. Suppress with an inline `# shellcheck disable=SCxxxx # reason`; the `tests/.shellcheckrc` files cover only the assertion idioms | pre-commit (staged scripts, skipped when shellcheck is absent), CI (pinned version) |
| Deterministic tests | `lib/tests`, `hooks/tests`, `scripts/tests` | CI; run locally with `TZ=UTC` |
| Behavioural evals | `evals/` via `scripts/evals/run.sh` (`claude plugin eval`) | pre-push (changed skills only, 1 run, Sonnet, report-only), `/release` (full suite) |
| Release comparison | `scripts/evals/release-check.sh`: paired delta, bootstrap CI and pass^k against the previous release's baseline in `quality/baselines/` | `/release`; a regression on a model `quality/release-check.json` lists in `"gateModels"` (Sonnet) blocks the release when `"gate": true`; other models are report-only |

Evals run only on the maintainer's Claude Code login. There is no API budget, so there is no CI eval job. Enable the git hooks once per clone with `scripts/install-git-hooks.sh`. Agents pushing from inside Claude Code skip the pre-push evals by default: run `scripts/evals/run.sh --mode changed` yourself with a long enough Bash timeout.

- **A new skill or a changed trigger gets an eval case.** Add a `skill:<name>` tag so pre-push selects it. Include at least one deterministic grader, and show that each grader can fail before trusting it (`evals/README.md`).
- **A fixed regression gets a test in the cheapest layer.** Use a lint rule for a structural mistake, a bash test for hook or lib logic, and an eval only when the fix lives in skill prose. A new test must fail with the fix reverted.
- **A flaky case moves to the `capability` tier; don't loosen its threshold.** A score that moves by one case between runs is noise at 15 cases. Read the transcript before editing a skill to chase it.

## Paths in skills, blueprints, and templates

Everything in `skills/`, `blueprints/`, `framework-files/`, and `templates/` is read by downstream models inside other people's repos. Hardcoded absolute paths (`/Users/<you>/...`) and resolved aiDir values (`ai/features/...`) leak local layout.

- Use `${aiDir}/...` for any framework-managed doc — `init` substitutes per-project.
- Use repo-relative paths (`src/foo.ts`) for codebase file references in examples and tables.
- Use `<repo_root>` / `<encoded_cwd>` placeholders when an example genuinely needs to show an absolute path.
- The `no-absolute-paths.sh` PreToolUse hook denies a Write or Edit whose proposed content violates this, reading only what the call adds (never the file on disk), and the Stop gate checks the lines a Bash write added (`lib/stop-gate/content.sh`). It checks doc files anywhere and every file under `.claude/`, `docs/` and the aiDir, so a `.sh` or `.mjs` in `lib/` or `hooks/` is not covered; check those by hand. The rule it enforces is also shipped to downstream projects as `framework-files/rules/paths.md`.

## Config contracts between blueprints and skills

Some blueprints and skills share a config file whose **section headings are the API**. The mockup surface is the concrete case (v1.20.0): `blueprints/mockup.md` generates `${aiDir}/conventions/mockup-design.md`, and both `feature-mockup` and `feature-mockup-review` read its sections *by name* at silent recon (*Always*, *Style baseline*, *Imports*, *Data model source*, *Component library*, *Detection patterns*, *Repeated user feedback*). Renaming a heading in any one of the three files silently breaks the other two — there is no runtime error, the skill just stops finding the rules. When touching one side of such a contract, grep the other two for the heading name in the same PR. The same pattern applies to `doctor` (`.claude/rules/doctor.md` `## Project anchors` / `## Read-only` / `## Extra checks`).

A framework file's **name** is the same kind of contract, and it is the one that bites hardest. `${aiDir}/anti-patterns.md` is the manifest key, the `anti-patterns` blueprint's write target (`blueprints/anti-patterns.md`), the `setup` skill's destination table, and a row in two routing blueprints — and because `update` treats a missing destination as "create from source", changing the key without a migration lands an empty duplicate that every blueprint then writes to. That is what issue #55 was. Renames now travel as data: put `renamedFrom: "<old key>"` on the manifest entry and `update` migrates the file and the `.myspec.json` key. Removals travel the same way: move the entry to the manifest `removed` block with its `dest`, and `update` deletes it. Never rename or drop a manifest key without one of these. Since 2.0 a `marker-merge` file's header (line 1 through the end marker) is framework-owned, so a retitle needs no migration. `.claude/state/` is the third contract: gitignored per-checkout state (`sessions/<id>.md` live logs, `sessions/<id>.jsonl` session-state files, `sessions/<id>.blobs/` file snapshots the stop gate keeps when the object store is read-only, `memory-ids.json`, `metrics/`) that hooks write and skills read by convention — `update` never touches it except for `retired-3.0/`, where the `3.0.0-plugin-hooks` migration moves a 2.x install's `.claude/hooks/` and `.claude/lib/` copies instead of deleting them, and the isolation hook pins it to the main checkout. Since 3.0 the hooks and lib run from the plugin (`hooks.json`, declared in `.claude-plugin/plugin.json`; every lib path is `${CLAUDE_PLUGIN_ROOT}/lib/…`), so no shipped content may name `.claude/hooks/<x>` or `.claude/lib/<x>` for a file the plugin ships (`lib/tests/manifest-regression.test.sh`). A skill body may write `${CLAUDE_PLUGIN_ROOT}`, which Claude Code substitutes when it loads the skill; a rule file or an aiDir document may not (nothing substitutes it there, and the Bash tool does not export it), so those name the plugin's `lib/<x>` and let the skill or the hook's block message carry the resolved path. A repository with no main checkout (a bare clone with worktrees, `--separate-git-dir`) keeps the `.jsonl` files in its git common dir, `myspec-state/sessions/`; `session_dir` in `lib/session-event.sh` names the directory either way. The `.jsonl` file holds a session's writes, verified runs, isolation decision and feature-implement state, and `lib/session-event.sh` is its only writer and reader: a hook or skill that needs one of them goes through it, never the file.

## Breaking changes

RELEASING.md "Breaking changes" defines what counts. When a change you are making or proposing meets it, open or label its issue `breaking` in the next major's milestone, and mark the PR breaking: tick the PR template's *Breaking* box or use `type!:` in its title, and the `pr-labels` workflow adds the label (it also inherits `breaking` from a closed issue). `/release` refuses a minor while a labelled PR is unreleased, so a missing label is how a break ships in a minor. A change with its own migration (`renamedFrom`, a `removed` entry) is not breaking.

## Issues

File one problem per issue, and start the title with the component it concerns, named as it is in the repo (`feature-plan: …`, `verify-before-stop: …`). `.github/ISSUE_TEMPLATE/report.md` gives the body sections. The `issue-triage` workflow reads that prefix to add `area:*` labels plus `status:needs-triage`. It runs `scripts/triage/area-labels.mjs` and makes no model call. The repo-local `/triage` skill (`.claude/skills/triage/`) then reproduces each issue on `origin/main`, dedupes it, splits bundled issues, sets type and priority, and groups ready issues into work batches by the files they touch. When an issue closes, the same workflow checks its parent tracker. If every sub-issue is closed, it puts the parent back to `status:needs-triage` (`scripts/triage/tracker-check.sh`) and never closes it itself. PRs say `Fixes #N` for each issue they close. The `pr-labels` workflow labels every PR without a model call (`scripts/triage/pr-labels.mjs`): `type:*` from the Conventional Commit type, `area:*` from the changed files (mirror files under `plugins/myspec/` add nothing), and the highest `P*` of the issues it closes. It only adds labels, so fix a wrong one by hand. It also warns, without failing, when a skill change has no `examples/` change and the template's Examples box is unticked, or when a `SKILL.md` description changes with no `evals/` change (`scripts/triage/pr-companions.mjs`). `.github/labels.json` defines the labels; apply changes to it with `scripts/triage/sync-labels.sh`.

## Stacked PRs

A PR based on another PR's branch merges into that branch, not main. After merging the parent, GitHub retargets the child only if the parent branch was deleted. Otherwise retarget it yourself with `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -f base=main` (`gh pr edit --base` fails with this repo's token), and confirm `mergeStateStatus` is `CLEAN` before merging. Merge the parent first: merging the child alone into main also lands the parent's commits unreviewed. (#108/#109, 2026-09-27.)

## Releasing

Use the repo-local `/release` skill (`.claude/skills/release/` — maintainer tooling, not shipped with the plugin); `RELEASING.md` is the authoritative reference. Two learned-the-hard-way facts (v1.19.0, 2026-08-03):

- **Pushing a tag auto-publishes the GitHub release** — the workflow runs `gh release create --generate-notes` with no `--draft`, so it is live within a minute, titled with the bare tag. Write the notes *before* tagging, then enrich with `gh release edit vX.Y.Z` (`create` fails HTTP 422 "tag_name already exists"), keeping the generated PR links at the bottom. Corrected 2026-09-04 during the v2.0.0 release; it was recorded as "auto-drafts" from v1.19.0 and nobody had checked `isDraft`.
- **No apostrophes inside `$(cat <<EOF …)` heredocs in hook scripts.** Bash's command-substitution scanner treats the unmatched quote as an open string and the script fails to parse with a misleading error. Run `bash -n` on every hook after any message-text edit.
