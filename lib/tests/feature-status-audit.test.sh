#!/usr/bin/env bash
# Regression fixture for feature-status-audit/audit.mjs status-drift checks.
#
# Each drift flag has a positive fixture and a negative control, so a flag
# that stops firing and a flag that fires on healthy docs both fail here.
# Checkbox counting must ignore table cells and fenced code: a plan quoting
# `- [ ]` in an example is not an open task.
#
# Usage: feature-status-audit.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../feature-status-audit/audit.mjs}"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
F="$REPO/ai/features"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect_line() {     # expect_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi
}

expect_no_line() {  # expect_no_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi
}

run_audit() {       # run_audit [args...]
  OUTPUT=$(cd "$REPO" && node "$SCRIPT" "$@" 2>&1)
}

doc() {             # doc <path> <status>   — spec/tech-spec with frontmatter status
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntitle: "x"\nstatus: %s\n---\n\n# Doc\n' "$2" > "$1"
}

plan() {            # plan <path> <marks...>   — one task line per mark (" ", "x", "~")
  mkdir -p "$(dirname "$1")"
  {
    # shellcheck disable=SC2016 # literal text, not an expansion
    printf -- '---\ntitle: "Plan"\n---\n\n## Task Status\n\n| Status | Meaning |\n|---|---|\n| `[ ]` | Todo |\n| - [ ] | table cell |\n\n```markdown\n- [ ] **Step 1: fenced example**\n```\n\n### Task 1: Thing\n\n'
    for m in "$@"; do printf -- '- [%s] **Step**\n' "$m"; done
  } > "$1"
}

feature() {         # feature <name>   — spec/tech-spec approved + dependencies
  doc "$F/$1/spec.md" approved
  doc "$F/$1/tech-spec.md" approved
  echo '# deps' > "$F/$1/dependencies.md"
}

build_fixture() {
  rm -rf "$REPO"
  mkdir -p "$F"
  # The audit reads aiDir through the settings reader (schema default .ai);
  # this project keeps its docs under ai/, as a configured project says so.
  printf '{"aiDir":"ai"}\n' > "$REPO/.myspec.json"

  cat > "$F/index.yaml" <<'YAML'
features:
  - name: healthy-complete
    status: complete
  - name: done-inprog
    status: in-progress
  - name: partial-inprog
    status: in-progress
  - name: complete-open
    status: complete
  - name: complete-done-plan
    status: complete
  - name: complete-zero-archive
    status: complete
  - name: complete-superseded-archive
    status: complete
  - name: complete-draft-docs
    status: complete
  - name: offvocab-docs
    status: complete
  - name: unknown-doc-status
    status: in-progress
  - name: parent-ticked
    status: in-progress
    subfeatures: true
  - name: parent-unticked
    status: in-progress
    subfeatures: true
  - name: parent-mixed
    status: in-progress
    subfeatures: true
YAML

  feature healthy-complete
  plan "$F/healthy-complete/plans/2026-01-01-plan.md" x x x

  feature done-inprog
  plan "$F/done-inprog/implementation-plan.md" x x

  feature partial-inprog
  plan "$F/partial-inprog/implementation-plan.md" x " "

  feature complete-open
  plan "$F/complete-open/implementation-plan.md" x "~" " "

  feature complete-done-plan
  plan "$F/complete-done-plan/implementation-plan.md" x x

  feature complete-zero-archive
  plan "$F/complete-zero-archive/plans/2026-02-01-plan.md" " " " " " " " "

  feature complete-superseded-archive
  plan "$F/complete-superseded-archive/plans/2026-03-01-v2-plan.md" x x
  plan "$F/complete-superseded-archive/plans/2026-02-01-v1-plan.md" " " " " " "
  sed -i.bak 's/^title: "Plan"$/title: "Plan"\
status: superseded/' "$F/complete-superseded-archive/plans/2026-02-01-v1-plan.md"
  rm -f "$F/complete-superseded-archive/plans/2026-02-01-v1-plan.md.bak"

  doc "$F/complete-draft-docs/spec.md" draft
  doc "$F/complete-draft-docs/tech-spec.md" '"draft"'

  feature offvocab-docs
  doc "$F/offvocab-docs/spec.md" complete
  doc "$F/offvocab-docs/tech-spec.md" "'superseded'"
  feature unknown-doc-status
  doc "$F/unknown-doc-status/spec.md" shipped

  for p in parent-ticked parent-unticked parent-mixed; do
    feature "$p"
    feature "$p/a"
    feature "$p/b"
  done
  printf 'subfeatures:\n  - name: a\n    status: complete\n  - name: b\n    status: complete\n' \
    | tee "$F/parent-ticked/index.yaml" > "$F/parent-unticked/index.yaml"
  printf 'subfeatures:\n  - name: a\n    status: complete\n  - name: b\n    status: in-progress\n' \
    > "$F/parent-mixed/index.yaml"

  # parent-ticked ticks ACs (convention in use) and has open ones.
  # A checkbox under a later heading must not count as an AC.
  local acs='## Acceptance Criteria\n\n- [x] AC-1\n- [ ] AC-2\n- [ ] AC-3\n\n## Out of Scope\n\n- [ ] not an AC\n'
  printf -- '---\nstatus: approved\n---\n\n%b' "$acs" > "$F/parent-ticked/spec.md"
  printf -- '---\nstatus: approved\n---\n\n%b' "$acs" > "$F/parent-mixed/spec.md"
  # parent-unticked never ticks ACs: a convention, not drift.
  printf -- '---\nstatus: approved\n---\n\n## Acceptance Criteria\n\n- [ ] AC-1\n- [ ] AC-2\n' > "$F/parent-unticked/spec.md"
}

# ═══ plan checkbox ratio vs manifest ═════════════════════════════════════════

build_fixture
run_audit

expect_line 'done-inprog .*implementation-plan.md is 2/2 \[x\] but status=in-progress' \
  "in-progress with a fully ticked plan is flagged; table and fenced checkboxes ignored"
expect_no_line 'partial-inprog .*implementation-plan.md is' \
  "in-progress with open plan tasks is not flagged"
expect_line 'complete-open .*status=complete but implementation-plan.md is 1/3 \[x\]' \
  "complete with an unarchived plan holding [ ] and [~] tasks is flagged"
expect_line 'complete-done-plan .*LOW .*should be archived' \
  "complete with a fully ticked unarchived plan keeps the low archive notice"
expect_no_line 'complete-done-plan .*MEDI' \
  "a fully ticked unarchived plan is not reported as open tasks"
expect_line 'complete-zero-archive .*archived plans/2026-02-01-plan.md is 0/4 \[x\]' \
  "complete with an archived plan at 0/N is flagged"
expect_no_line 'complete-superseded-archive ' \
  "an archived plan marked status: superseded is not flagged at 0/N"
expect_no_line 'healthy-complete ' \
  "complete with approved docs and a ticked archived plan reports nothing"

# ═══ doc frontmatter status vs manifest ══════════════════════════════════════

expect_line 'complete-draft-docs .*spec.md frontmatter status: draft but manifest status=complete' \
  "spec.md status: draft under a complete manifest entry is flagged"
expect_line 'complete-draft-docs .*tech-spec.md frontmatter status: draft' \
  "quoted tech-spec.md status is read too"

# ═══ doc status outside the vocabulary (#261) ═══════════════════════════════

expect_line 'offvocab-docs .*MEDI spec.md frontmatter status: complete is not a doc status \(draft \| approved \| deprecated\) — set approved' \
  "spec.md status: complete is flagged with its migration target"
expect_line 'offvocab-docs .*MEDI tech-spec.md frontmatter status: superseded is not a doc status .*— set deprecated' \
  "a quoted tech-spec.md status: superseded is flagged with its migration target"
expect_line 'unknown-doc-status .*MEDI spec.md frontmatter status: shipped is not a doc status \(draft \| approved \| deprecated\)$' \
  "an unknown doc status is flagged without a target"
expect_no_line '(healthy-complete|complete-draft-docs|parent-ticked) .*is not a doc status' \
  "draft and approved doc statuses are not flagged"
if (cd "$REPO" && node "$SCRIPT" >/dev/null 2>&1); then ok; else fail "off-vocabulary findings alone do not set a non-zero exit"; fi

# ═══ sub-features complete vs parent spec ACs ════════════════════════════════

expect_line 'parent-ticked .*all 2 sub-features complete but spec.md acceptance criteria are 1/3 \[x\] \(2 unticked\)' \
  "all sub-features complete while the parent spec has unticked ACs is flagged; later sections ignored"
expect_no_line 'parent-unticked .*acceptance criteria' \
  "a spec that never ticks ACs is not flagged"
expect_no_line 'parent-mixed .*acceptance criteria' \
  "a parent with an incomplete sub-feature is not flagged"

# ═══ json carries the ratios ═════════════════════════════════════════════════

run_audit --json
expect_line '"planProgress": \{' "json exposes planProgress"
expect_line '"specStatus": "draft"' "json exposes specStatus"
expect_no_line '"gitHint"' "no git hint outside a git repository"

# ═══ git log hint for merge-without-complete ═════════════════════════════════

(cd "$REPO" && git init -q && git add -A \
  && git -c user.name=t -c user.email=t@t commit -qm "feat(done-inprog): ship it") || fail "fixture git init"
run_audit
expect_line 'git log: [0-9a-f]+ feat\(done-inprog\): ship it' \
  "a commit naming the feature is offered as a merge hint"

# ═══ report ══════════════════════════════════════════════════════════════════

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
