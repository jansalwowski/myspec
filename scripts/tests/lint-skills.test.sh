#!/usr/bin/env bash
# Regression fixture for scripts/lint-skills.mjs.
#
# The linter runs on every commit through .githooks/pre-commit, so each rule
# has to earn its place twice: it fires on the defect it exists for, and it
# stays quiet on the look-alikes real skills contain (sibling names that are
# prefixes of other names, pointers inside code fences, placeholder links,
# manual-only stubs). Every rule below gets one violating and one clean
# fixture, and the real repo has to lint clean.
#
# Usage: lint-skills.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
SCRIPT="${1:-$REPO_ROOT/scripts/lint-skills.mjs}"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect_line()    { if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi; }
expect_no_line() { if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi; }
expect_exit()    { if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1)"; fi; }
run() { OUTPUT=$(cd "$FIX" && node "$SCRIPT" --root "$FIX" "$@" 2>&1); STATUS=$?; [ -z "${DEBUG:-}" ] || printf "%s\n" "$OUTPUT" >&2; }

# fresh: start an empty fixture repo. skill <dir>: write stdin to its SKILL.md.
N=0
fresh() { N=$((N + 1)); FIX="$TMP/fx$N"; mkdir -p "$FIX/skills"; }
skill() { mkdir -p "$FIX/skills/$1"; cat > "$FIX/skills/$1/SKILL.md"; }

GOOD='description: "Use when a demo needs linting. Keywords: demo. Do NOT use for real work."'

# A body that satisfies every body rule, reused by the frontmatter cases.
body() {
  cat <<'MD'

# Demo

## Workflow

### Step 1: Read

Read things. If nothing is there, skip to Step 2.

### Step 2: Write

Write things.
MD
}

# ── clean baseline ──────────────────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; body; } | skill demo
run
expect_exit 0 "a clean skill exits 0"
expect_line "1 file\(s\), 0 error\(s\), 0 warning\(s\)" "a clean skill reports no findings"

# ── FM-MISSING ──────────────────────────────────────────────────────────────
fresh
body | skill demo
run
expect_exit 1 "no frontmatter exits 1"
expect_line "^skills/demo/SKILL\.md:1: FM-MISSING " "no frontmatter is FM-MISSING at line 1"

fresh
{ printf -- '---\nname: demo\n%s\n' "$GOOD"; body; } | skill demo
run
expect_line "FM-MISSING .*never closed" "unclosed frontmatter is FM-MISSING"

# ── FM-UNKNOWN-KEY (ced9dba, 4f189a8) ───────────────────────────────────────
fresh
{ printf -- '---\nname: demo\n%s\nload_when: [path_matches]\nupdated: 2026-01-01\nfoo: bar\n---\n' "$GOOD"; body; } | skill demo
run
expect_exit 1 "unknown keys exit 1"
expect_line "SKILL\.md:4: FM-UNKNOWN-KEY .*load_when.*ced9dba" "load_when is rejected with its history"
expect_line "SKILL\.md:5: FM-UNKNOWN-KEY .*updated" "updated is rejected"
expect_line "SKILL\.md:6: FM-UNKNOWN-KEY .*foo.*allowlist" "an arbitrary key is rejected"

fresh
{ printf -- '---\nname: demo\n%s\nallowed-tools: [Read, Grep]\ntags: [a, b]\nargument-hint: "<x>"\nwhen_to_use: "short"\ndependencies:\n  packages:\n    - left-pad\n  paths:\n    - src/app.ts\n---\n' "$GOOD"; body; } | skill demo
run
expect_exit 0 "allowlisted keys (spec, Claude Code, convention tiers) pass"
expect_no_line "FM-" "allowlisted keys raise nothing"

# ── NAME-MISSING / NAME-FORMAT / NAME-MISMATCH ──────────────────────────────
fresh
{ printf -- '---\n%s\n---\n' "$GOOD"; body; } | skill demo
run
expect_line "NAME-MISSING" "missing name is reported"

fresh
{ printf -- '---\nname: Demo--x\n%s\n---\n' "$GOOD"; body; } | skill Demo--x
run
expect_line "SKILL\.md:2: NAME-FORMAT " "uppercase / doubled hyphen name is NAME-FORMAT"
expect_no_line "NAME-MISMATCH" "a bad name matching its directory is not also a mismatch"

fresh
{ printf -- '---\nname: claude-helper\n%s\n---\n' "$GOOD"; body; } | skill claude-helper
run
expect_line "NAME-FORMAT .*reserved" "reserved word in name is NAME-FORMAT"

fresh
{ printf -- '---\nname: other\n%s\n---\n' "$GOOD"; body; } | skill demo
run
expect_exit 1 "name/directory mismatch exits 1"
expect_line "SKILL\.md:2: NAME-MISMATCH .*other.*demo" "name/directory mismatch is reported"

fresh
{ printf -- '---\nname: "demo"\n%s\n---\n' "$GOOD"; body; } | skill demo
run
expect_exit 0 "a quoted name equal to the directory passes"

# ── INVOCATION-NONE ─────────────────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\ndescription: "Retired."\ndisable-model-invocation: true\nuser-invocable: false\n---\n'; body; } | skill demo
run
expect_line "SKILL\.md:5: INVOCATION-NONE " "invocable-by-nobody is reported"

fresh
{ printf -- '---\nname: demo\ndescription: "Retired in 2.0 — renamed."\ndisable-model-invocation: true\nallowed-tools: [Read]\n---\n'; body; } | skill demo
run
expect_exit 0 "a manual-only stub passes without Use-when or Do-NOT"

# ── DESC-MISSING / DESC-LENGTH ──────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\ndescription: ""\n---\n'; body; } | skill demo
run
expect_line "DESC-MISSING" "empty description is reported"

LONG="Use when $(printf 'x%.0s' $(seq 1 1020)). Do NOT use for y."
fresh
{ printf -- '---\nname: demo\ndescription: "%s"\n---\n' "$LONG"; body; } | skill demo
run
expect_exit 1 "an over-cap description exits 1"
expect_line "DESC-LENGTH .*1024" "an over-cap description is reported"

AT="Use when $(printf 'x%.0s' $(seq 1 996)). Do NOT use for y."
fresh
{ printf -- '---\nname: demo\ndescription: "%s"\n---\n' "$AT"; body; } | skill demo
run
expect_no_line "DESC-LENGTH" "a description of exactly 1024 chars passes (len ${#AT})"

WTU="$(printf 'w%.0s' $(seq 1 700))"
fresh
{ printf -- '---\nname: demo\ndescription: "%s"\nwhen_to_use: "%s"\n---\n' "$AT" "$WTU"; body; } | skill demo
run
expect_line "DESC-LENGTH .*when_to_use.*1536" "description + when_to_use over the listing cap is reported"

# ── DESC-USE-WHEN (d60997b) ─────────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\ndescription: "Use to lint demos. Do NOT use for real work."\n---\n'; body; } | skill demo
run
expect_exit 1 "a model-invocable description not opening Use-when exits 1"
expect_line "SKILL\.md:3: DESC-USE-WHEN " "Use-to opening is DESC-USE-WHEN"

fresh
{ printf -- '---\nname: demo\ndescription: >\n  Use when a demo needs linting.\n  Do NOT use for real work.\n---\n'; body; } | skill demo
run
expect_exit 0 "a folded block-scalar description that opens Use-when passes"

fresh
{ printf -- '---\nname: demo\ndescription: "Use when a demo needs linting,\n  over two lines. Do NOT use for real work."\n---\n'; body; } | skill demo
run
expect_exit 0 "a multi-line double-quoted description parses and passes"

# ── DESC-WORKFLOW (886a3ab) — warning only ──────────────────────────────────
fresh
{ printf -- '---\nname: demo\ndescription: "Use when a demo is ready. Analyzes the code, then generates a report. Do NOT use for real work."\n---\n'; body; } | skill demo
run
expect_line "DESC-WORKFLOW warning:" "a workflow-summary description warns"
expect_exit 0 "DESC-WORKFLOW is a warning and does not fail the run"

# ── DESC-DO-NOT (d60997b) ───────────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\ndescription: "Use when a demo needs linting."\n---\n'; body; } | skill demo
run
expect_exit 1 "a model-invocable description with no Do-NOT clause exits 1"
expect_line "DESC-DO-NOT .*no \"Do NOT" "missing Do-NOT clause is reported"

fresh
{ printf -- '---\nname: code-review\ndescription: "Use when code needs review. Do NOT use for spec.md (feature-spec-review) or SKILL.md (skill-verify)."\n---\n'; body; } | skill code-review
run
expect_exit 1 "a sibling dropped from the Do-NOT clause exits 1"
expect_line "DESC-DO-NOT .*feature-tech-spec-review" "the dropped sibling is named"
expect_no_line "DESC-DO-NOT .*skill-verify" "kept siblings are not reported"

fresh
{ printf -- '---\nname: feature-spec\ndescription: "Use when starting a feature. Do NOT use for tech design (feature-tech-spec-review)."\n---\n'; body; } | skill feature-spec
run
expect_line "DESC-DO-NOT .*feature-tech-spec" "a longer name containing the sibling does not count as naming it"

fresh
{ printf -- '---\nname: code-review\ndescription: "Use when code (not feature-tech-spec-review) needs review. Do NOT use for spec.md (feature-spec-review) or SKILL.md (skill-verify)."\n---\n'; body; } | skill code-review
run
expect_line "DESC-DO-NOT .*feature-tech-spec-review" "a sibling named before the Do-NOT clause does not count"

fresh
{ printf -- '---\nname: code-review\ndescription: "Use when code needs review. Do NOT use for spec.md (feature-spec-review), tech-spec.md (feature-tech-spec-review), or SKILL.md (skill-verify)."\n---\n'; body; } | skill code-review
run
expect_exit 0 "a Do-NOT clause naming every sibling passes"

# ── DEP-PLUGIN-PATH (AGENTS.md, v1.20.0) ────────────────────────────────────
fresh
mkdir -p "$FIX/skills/demo/references" "$FIX/src"
touch "$FIX/src/app.ts"
{ printf -- '---\nname: demo\n%s\ndependencies:\n  paths:\n    - src/app.ts\n    - skills/demo/references\n    - skills/not-here/x.md\n---\n' "$GOOD"; body; } | skill demo
run
expect_exit 1 "a plugin-internal dependency path exits 1"
expect_line "SKILL\.md:7: DEP-PLUGIN-PATH .*skills/demo/references" "the plugin-internal path is reported on its own line"
expect_no_line "DEP-PLUGIN-PATH .*src/app\.ts" "a consumer path is not reported"
expect_no_line "DEP-PLUGIN-PATH .*not-here" "a path that does not exist in the plugin is not reported"

fresh
{ printf -- '---\nname: demo\n%s\ndependencies:\n  paths: [src/app.ts]\n---\n' "$GOOD"; body; } | skill demo
run
expect_exit 0 "an inline-list consumer dependency passes"

# ── STEP-REF (a3562ed) ──────────────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; cat <<'MD'

# Demo

All gates pass → proceed to Workflow Step 0.

## Workflow

### Step 1: Read

If empty, skip to step 9. For the fields, see Step 7.

### Step 2: Write
MD
} | skill demo
run
expect_exit 1 "dangling step pointers exit 1"
expect_line "SKILL\.md:8: STEP-REF .*proceed to Workflow Step 0" "a gate exit past a removed Step 0 is reported (a3562ed)"
expect_line "SKILL\.md:14: STEP-REF .*skip to step 9" "skip-to a missing step is reported"
expect_line "SKILL\.md:14: STEP-REF .*see Step 7" "see a missing step is reported"

fresh
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; cat <<'MD'

# Demo

All gates pass → proceed to Workflow Step 0.

## Workflow

### Step 0: Choose mode

Go to Step 4b when done, or continue to Step 4.5; see Step 3.

1. **Numbered** item one
2. **Numbered** item two
3. **Numbered** item three

#### 5. Heading-numbered step

If done, skip to step 5. The task's Step 9 answers come from the plan.
Also see memory-create Step 8 and the `skip to step 42` example.

```
When the template says "go to Step 99", that is the output's own step.
```

### Step 4b: Checkpoint
### Step 4.5: Coverage
MD
} | skill demo
run
expect_exit 0 "pointers resolving to headings, sub-steps, numbered items, or unchecked contexts pass"
expect_no_line "STEP-REF" "no STEP-REF on bare mentions, other skills' steps, inline code, or fenced code"

# ── LINK-DEAD / LINK-ANCHOR ─────────────────────────────────────────────────
fresh
mkdir -p "$FIX/skills/_shared" "$FIX/skills/demo/references"
printf '# Shared\n\n## Real Section\n' > "$FIX/skills/_shared/helper.md"
printf '# Ref\n' > "$FIX/skills/demo/references/ref.md"
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; cat <<'MD'

# Demo

## Hard Rules

Read [helper](../_shared/helper.md), [ref](references/ref.md), [section](../_shared/helper.md#real-section) and [rules](#hard-rules).
Placeholders are template output: [x](./{sub}/spec.md), [y](plans/<name>.md), [z]($DIR/a.md), [w](…).
External: [docs](https://example.com/a/b/c.md), [mail](mailto:a@b.c).

```markdown
[inside fence](gone-in-fence.md)
```
Inline code `[not a link](gone-inline.md)` is not a link.
MD
} | skill demo
run
expect_exit 0 "resolving, placeholder, external and fenced links pass"
expect_no_line "LINK-" "no LINK finding on valid or skipped links"

fresh
mkdir -p "$FIX/skills/_shared"
printf '# Shared\n' > "$FIX/skills/_shared/helper.md"
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; cat <<'MD'

# Demo

## Rules

See [gone](../_shared/autopilot.md) and [ref](references/missing.md).
See [guards](#hard-guards) and [section](../_shared/helper.md#no-such-section).
MD
} | skill demo
run
expect_exit 1 "dead links exit 1"
expect_line "SKILL\.md:10: LINK-DEAD .*\.\./_shared/autopilot\.md" "a dead ../_shared link is reported"
expect_line "SKILL\.md:10: LINK-DEAD .*references/missing\.md" "a dead references/ link is reported"
expect_line "SKILL\.md:11: LINK-ANCHOR .*#hard-guards" "an anchor to a renamed heading is reported"
expect_line "SKILL\.md:11: LINK-ANCHOR .*no-such-section" "a cross-file anchor with no heading is reported"

# ── SIZE-BUDGET — warning only ──────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; body; for _ in $(seq 1 520); do echo "Line of text."; done; } | skill demo
run
expect_line "SIZE-BUDGET warning: .*lines" "a body over 500 lines warns"
expect_exit 0 "SIZE-BUDGET does not fail the run"

fresh
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; body; printf '%s\n' "$(printf 'abcdefghij%.0s' $(seq 1 2100))"; } | skill demo
run
expect_line "SIZE-BUDGET warning: body is ~5[0-9]{3} tokens" "a body over 5000 estimated tokens warns"

# ── CLI: --files, --json, exit 2 ────────────────────────────────────────────
fresh
{ printf -- '---\nname: demo\n%s\n---\n' "$GOOD"; body; } | skill demo
{ printf -- '---\nname: bad\ndescription: "Use to x."\n---\n'; body; } | skill bad
mkdir -p "$FIX/with space/skills/spaced"
{ printf -- '---\nname: spaced\n%s\n---\n' "$GOOD"; body; } > "$FIX/with space/skills/spaced/SKILL.md"
run --files skills/demo/SKILL.md "with space/skills/spaced/SKILL.md"
expect_exit 0 "--files lints only the named files"
expect_line "2 file\(s\)" "--files counts only the named files"
run --files skills/bad/SKILL.md
expect_exit 1 "--files on a bad skill exits 1"
expect_line "^skills/bad/SKILL\.md:3: DESC-USE-WHEN" "--files reports cwd-relative paths"
run
expect_exit 1 "no --files lints every skill"
run --json
expect_line '"rule": "DESC-USE-WHEN"' "--json emits findings"
expect_line '"errors": 2' "--json carries the error count"
run --files
expect_exit 2 "--files with no paths exits 2"
run --files skills/nope/SKILL.md
expect_exit 2 "--files with a missing path exits 2"
expect_line "no such file" "a missing --files path is named"
run --bogus
expect_exit 2 "an unknown flag exits 2"

# ── the real repo lints clean, and so does its plugin mirror ────────────────
OUTPUT=$(cd "$REPO_ROOT" && node "$SCRIPT" 2>&1); STATUS=$?
expect_exit 0 "the real repo has no error findings"
if [ -d "$REPO_ROOT/plugins/myspec/skills" ]; then
  OUTPUT=$(cd "$REPO_ROOT" && node "$SCRIPT" --files plugins/myspec/skills/*/SKILL.md 2>&1); STATUS=$?
  expect_exit 0 "the plugin mirror has no error findings"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
