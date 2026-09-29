#!/usr/bin/env bash
# Regression fixture for lib/delivery-metrics/metrics.mjs.
#
# Builds a git repository with a synthetic, fully dated feature history and
# asserts every metric's exact value: lead time (spec commit -> the merge that
# landed status complete), stage dwell, plan deferral rate, conformance
# first-time pass (FAIL then PASS across committed versions, and from the
# report's own verdict history through a merge and a squash; a committed FAIL
# the history lacks, formatted cells, a partial, conflicted or
# unreadable history), rework rate (fix commits inside and outside
# the 30-day window, touching a PHP and a Python inventory path), and spec
# churn. Also: a renamed feature keeps its history, --since/--feature filter,
# --fix-pattern replaces the default, a shallow clone and a non-repository are
# refused, and an empty repository reports nulls with the reason.
#
# Dates are fixed through GIT_AUTHOR_DATE/GIT_COMMITTER_DATE; run with TZ=UTC.
#
# Usage: delivery-metrics.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../delivery-metrics/metrics.mjs}"
# The skill whose report lookup command the fixture runs (override: $2).
SKILL_MD="${2:-$HERE/../../skills/feature-implement-review/SKILL.md}"

if [ ! -f "$SKILL_MD" ]; then
  echo "FATAL: skill not found: $SKILL_MD" >&2
  exit 1
fi
if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/delivery-metrics.XXXXXX")" && pwd -P)
REPO="$ROOT/proj"
F="$REPO/ai/features"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

run() {             # run [args...]   — from $REPO
  OUTPUT=$(cd "$REPO" && node "$SCRIPT" "$@" 2>&1); STATUS=$?
}

jget() {            # jget <js expression over `d`>   — evaluates against $OUTPUT
  printf '%s' "$OUTPUT" | node -e '
    let s = ""; process.stdin.on("data", c => s += c).on("end", () => {
      let d; try { d = JSON.parse(s) } catch { process.stdout.write("<not json>"); return }
      const f = n => d.features.find(x => x.id === n)
      let v; try { v = eval(process.argv[1]) } catch (e) { v = "<error " + e.message + ">" }
      process.stdout.write(typeof v === "string" ? v : JSON.stringify(v))
    })' "$1"
}

expect_eq() {       # expect_eq <js expression> <want> <description>
  local got; got=$(jget "$1")
  if [ "$got" = "$2" ]; then ok; else fail "$3 ($1: got '$got', want '$2')"; fi
}

expect_line() {     # expect_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi
}

expect_status() {   # expect_status <code> <description>
  if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1; output: $OUTPUT)"; fi
}

at() {              # at <YYYY-MM-DD> <git args...>   — git with both dates fixed at noon UTC
  local d="$1T12:00:00Z"; shift
  (cd "$REPO" && GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git "$@" >/dev/null 2>&1) || fail "fixture: git $*"
}

commit() {          # commit <YYYY-MM-DD> <message>   — commits everything
  (cd "$REPO" && git add -A) && at "$1" commit -m "$2"
}

manifest() {        # manifest <yaml body>
  printf 'features:\n%b' "$1" > "$F/index.yaml"
}

spec() {            # spec <feature> <spec_version> [extra line]
  mkdir -p "$F/$1"
  printf -- '---\ntitle: "%s"\nstatus: approved\nspec_version: %s\n---\n\n# Spec\n\n%s\n' "$1" "$2" "${3:-}" > "$F/$1/spec.md"
}

conformance() {     # conformance <feature> <verdict>
  printf -- '---\nfeature: %s\nverdict: %s\n---\n\n# Conformance\n' "$1" "$2" > "$F/$1/conformance-report.md"
}

conformance_hist() {  # conformance_hist <feature> <complete|partial> <row verdict>...
  # The report as feature-implement-review writes it: the frontmatter verdict
  # is the newest run's, `## Verdict history` holds one row per run.
  local feat="$1" mark="$2"; shift 2
  local last n=0 v
  for v in "$@"; do last="$v"; done
  mkdir -p "$F/$feat"
  {
    printf -- '---\nfeature: %s\nverdict: %s\nverdict_history: %s\n---\n\n# Conformance\n\n' "$feat" "$last" "$mark"
    printf '## Verdict history\n\n| Reviewed | Head | Verdict | Critical | High | Medium | Low |\n|----------|------|---------|----------|------|--------|-----|\n'
    for v in "$@"; do n=$((n + 1)); printf '| 2025-05-%02d | %s%02d | %s | 0 | %s | 0 | 0 |\n' "$n" "$feat" "$n" "$v" "$n"; done
  } > "$F/$feat/conformance-report.md"
}

touch_code() {      # touch_code <path> <line>
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" >> "$REPO/$1"
}

# ═══ fixture ═════════════════════════════════════════════════════════════════

build_fixture() {
  rm -rf "$REPO"
  mkdir -p "$F"
  (cd "$REPO" && git init -q -b main .)
  printf '{"aiDir":"ai","frameworkVersion":"0.0.0"}\n' > "$REPO/.myspec.json"
  echo '# proj' > "$REPO/README.md"

  # invoice-export: spec v1 written 01-01, draft
  spec invoice-export 1
  manifest '  - name: invoice-export\n    status: draft\n'
  commit 2025-01-01 "docs(invoice-export): spec"

  # spec v2 before completion: not churn
  spec invoice-export 2
  commit 2025-01-03 "docs(invoice-export): tighten ACs"

  # in-progress 01-04 with tech-spec (PHP + Python inventory) and a plan
  cat > "$F/invoice-export/tech-spec.md" <<'MD'
---
status: approved
based_on_spec_version: 2
---

# Tech Spec

### File Inventory
| File | Action | Purpose |
|------|--------|---------|
| `app/Invoice/Exporter.php` | Create | exporter |
| `services/export/worker.py` | Create | worker |
| `web/[id].php` | Create | a literal path, not a glob |
| `path/to/{placeholder}.x` | Create | placeholder, skipped |

### Decisions

| `not/an/inventory.path` | x | x |
MD
  manifest '  - name: invoice-export\n    status: in-progress\n'
  commit 2025-01-04 "docs(invoice-export): tech-spec"

  touch_code app/Invoice/Exporter.php '<?php // v1'
  touch_code services/export/worker.py '# v1'
  conformance invoice-export gaps
  commit 2025-01-05 "feat(invoice-export): first cut"

  # branch: conformance PASS, a pre-completion fix, status complete; merged 01-11
  at 2025-01-06 checkout -b feat/invoice
  touch_code services/export/worker.py '# pre-completion fix'
  commit 2025-01-06 "fix: pre-completion (before the window)"
  conformance invoice-export conformant
  commit 2025-01-08 "docs(invoice-export): conformance"
  mkdir -p "$F/invoice-export/plans"
  cat > "$F/invoice-export/plans/2025-01-09-invoice-export.md" <<'MD'
---
title: "Invoice export"
archived: 2025-01-09
---

## Spec Coverage

| Requirement | Source | Tasks |
|---|---|---|
| spec.md AC-1 | "exports" | T1 |
| spec.md AC-9 | "emails" | DEFERRED — out of scope |
| spec.md AC-10 | "pdf" | Deferred — lowercase cell |

## Task Status

| `[ ]` | Todo |
| - [ ] | table cell, not a task |

```markdown
### Task 9: fenced example
- [ ] **Step 1: not counted**
```

### Task 1: Exporter

- [x] **Step 1**
- [x] **Step 2**

### Task 2: Worker

- [x] **Step 1**

### Task 3: Email notification — DEFERRED (tracked as an idea)

- [ ] **Step 1**

### Task 4: Half done

- [x] **Step 1**
- [ ] **Step 2**

### Task T5: T-prefixed heading

- [x] **Step 1**

### Task 6: Notifications (deferred)

- [ ] **Step 1**

### Task 7: Background jobs

- [x] **Step 1: add deferred job loading** (work, not a deferral)

### Task 8: Audit trail

**Status:** deferred — moved to an idea
- [ ] **Step 1**

## Execution Log

- Deferred minor (Phase 1): not a task deferral
MD
  manifest '  - name: invoice-export\n    status: complete\n'
  commit 2025-01-09 "docs(invoice-export): complete"
  at 2025-01-11 checkout main
  at 2025-01-11 merge --no-ff feat/invoice -m "Merge branch feat/invoice"

  # rework window: 2025-01-11 12:00 .. 2025-02-10 12:00
  touch_code app/Invoice/Exporter.php '// rounding'
  commit 2025-01-15 "fix(invoice-export): round totals"
  touch_code services/export/worker.py '# retry'
  commit 2025-01-20 "Fix worker retry on timeout"
  touch_code web/i.php '<?php // matched only if [id] were a glob'
  commit 2025-01-22 "fix: web/i.php is not web/[id].php"
  touch_code app/Invoice/Exporter.php '// csv column'
  commit 2025-01-25 "feat(invoice-export): add csv column"
  echo 'unrelated' >> "$REPO/README.md"
  commit 2025-01-28 "fix: readme typo (not an inventory path)"

  # billing-sync, born as sync-billing and renamed while draft
  spec sync-billing 1
  manifest '  - name: invoice-export\n    status: complete\n  - name: sync-billing\n    status: draft\n'
  commit 2025-02-01 "docs(sync-billing): spec"
  at 2025-02-03 mv "ai/features/sync-billing" "ai/features/billing-sync"
  manifest '  - name: invoice-export\n    status: complete\n  - name: billing-sync\n    status: draft\n'
  commit 2025-02-03 "docs: rename sync-billing to billing-sync"
  # a manifest version that drops the entry is no observation, not a transition
  manifest '  - name: invoice-export\n    status: complete\n'
  commit 2025-02-04 "docs: manifest rewrite loses billing-sync"
  manifest '  - name: invoice-export\n    status: complete\n  - name: billing-sync\n    status: in-progress\n'
  commit 2025-02-06 "docs(billing-sync): start"
  manifest '  - name: invoice-export\n    status: complete\n  - name: billing-sync\n    status: complete\n'
  commit 2025-02-10 "docs(billing-sync): complete"

  touch_code services/export/worker.py '# late'
  commit 2025-02-20 "fix: late fix outside the window"

  # churn: v3 after completion counts; an edit without a bump does not
  spec invoice-export 3
  commit 2025-03-01 "docs(invoice-export): spec v3 (feature-update)"
  spec invoice-export 3 "clarified wording"
  commit 2025-03-05 "docs(invoice-export): wording"

  local B='  - name: invoice-export\n    status: complete\n  - name: billing-sync\n    status: complete\n'

  # old-name -> new-name: renamed in the manifest after completion, spec.md
  # rewritten in the move so --follow loses it; the one-for-one swap links them
  spec old-name 1
  manifest "$B"'  - name: old-name\n    status: draft\n'
  commit 2025-04-01 "docs(old-name): spec"
  manifest "$B"'  - name: old-name\n    status: draft\n  - name: squashed\n    status: planned\n'
  commit 2025-04-02 "docs: plan squashed"
  manifest "$B"'  - name: old-name\n    status: in-progress\n  - name: squashed\n    status: planned\n'
  commit 2025-04-03 "docs(old-name): start"
  manifest "$B"'  - name: old-name\n    status: complete\n  - name: squashed\n    status: planned\n'
  commit 2025-04-05 "docs(old-name): complete"

  # squashed: the whole flow on a branch, landed by git merge --squash —
  # spec.md and status complete arrive in one commit; one committed FAIL report
  at 2025-04-06 checkout -b feat/squashed
  spec squashed 1
  conformance squashed gaps
  commit 2025-04-06 "docs(squashed): spec"
  manifest "$B"'  - name: old-name\n    status: complete\n  - name: squashed\n    status: complete\n'
  commit 2025-04-07 "feat(squashed): done"
  at 2025-04-07 checkout main
  at 2025-04-07 merge --squash feat/squashed
  commit 2025-04-07 "feat(squashed): squash-merge"

  mkdir -p "$F/new-name"
  (cd "$REPO" && git rm -q -r ai/features/old-name) || fail "fixture: git rm old-name"
  {
    printf -- '---\nspec_version: 1\nowner: payments\n---\n\n'
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'Entirely rewritten requirement line %s for the renamed feature.\n' "$i"; done
  } > "$F/new-name/spec.md"
  manifest "$B"'  - name: new-name\n    status: complete\n  - name: squashed\n    status: complete\n'
  commit 2025-04-08 "docs: rename old-name to new-name"

  # retro-doc: documented after the fact — first seen already complete; its
  # only committed conformance report is a PASS
  spec retro-doc 1
  conformance retro-doc conformant
  commit 2025-04-09 "docs(retro-doc): spec"
  local R="$B"'  - name: new-name\n    status: complete\n  - name: squashed\n    status: complete\n  - name: retro-doc\n    status: complete\n'
  manifest "$R"
  commit 2025-04-10 "docs(retro-doc): register"

  # legacy-x -> modern-x: the rename commit also adds other-y, so only
  # renamedFrom can link them
  spec legacy-x 1
  manifest "$R"'  - name: legacy-x\n    status: draft\n'
  commit 2025-04-11 "docs(legacy-x): spec"
  (cd "$REPO" && git rm -q -r ai/features/legacy-x) || fail "fixture: git rm legacy-x"
  mkdir -p "$F/modern-x"
  {
    printf -- '---\nspec_version: 1\nteam: platform\n---\n\n'
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'Modern requirement %s, nothing like the legacy text.\n' "$i"; done
  } > "$F/modern-x/spec.md"
  manifest "$R"'  - name: modern-x\n    status: draft\n    renamedFrom: legacy-x\n  - name: other-y\n    status: draft\n'
  commit 2025-04-13 "docs: rename legacy-x to modern-x, add other-y"
  # renamedFrom is dropped again later: the committed history must carry it
  local M="$R"'  - name: modern-x\n    status: complete\n  - name: other-y\n    status: draft\n'
  manifest "$M"
  commit 2025-04-16 "docs(modern-x): complete"

  # café-export: a non-ASCII feature id, spec_version bumped after completion
  spec café-export 1
  manifest "$M"'  - name: café-export\n    status: draft\n'
  commit 2025-04-20 "docs(café-export): spec"
  manifest "$M"'  - name: café-export\n    status: complete\n'
  commit 2025-04-21 "docs(café-export): complete"
  spec café-export 2
  commit 2025-04-25 "docs(café-export): spec v2"

  # Verdict history in the report. Each report is committed once: without
  # the history a single committed version could not rule out a failure.
  conformance_hist hist-fail-pass complete not-verifiable gaps conformant
  commit 2025-05-01 "docs(hist-fail-pass): conformance"
  conformance_hist hist-pass complete conformant
  # a history example inside a fence is not the report's history
  printf '\n```markdown\n## Verdict history\n\n| Reviewed | Head | Verdict |\n|---|---|---|\n| 2025-01-01 | x | gaps |\n```\n' > "$ROOT/conf-fence.md"
  { head -n 7 "$F/hist-pass/conformance-report.md"; cat "$ROOT/conf-fence.md"; tail -n +8 "$F/hist-pass/conformance-report.md"; } > "$ROOT/conf-report.md"
  mv "$ROOT/conf-report.md" "$F/hist-pass/conformance-report.md"
  commit 2025-05-02 "docs(hist-pass): conformance"

  # the same FAIL-then-PASS branch history landed by a merge and by a squash
  local how
  for how in merged squash; do
    at 2025-05-03 checkout -b "feat/hist-$how"
    conformance_hist "hist-$how" complete gaps
    commit 2025-05-03 "docs(hist-$how): conformance gaps"
    conformance_hist "hist-$how" complete gaps conformant
    commit 2025-05-04 "docs(hist-$how): conformance conformant"
    at 2025-05-05 checkout main
    if [ "$how" = merged ]; then
      at 2025-05-05 merge --no-ff "feat/hist-$how" -m "Merge branch feat/hist-$how"
    else
      at 2025-05-05 merge --squash "feat/hist-$how"
      commit 2025-05-05 "docs(hist-$how): squash-merge"
    fi
  done

  # a history started on an older report: a PASS in its first row proves nothing
  conformance_hist hist-partial partial conformant
  commit 2025-05-06 "docs(hist-partial): conformance"

  # unreadable histories: a verdict the skill never writes, a short row
  conformance_hist hist-bad-verdict complete PASS
  conformance_hist hist-bad-row complete gaps conformant
  sed -i.bak 's/^| 2025-05-02 | hist-bad-row02 | conformant | 0 | 2 |.*$/| 2025-05-02 | conformant |/' "$F/hist-bad-row/conformance-report.md"
  rm -f "$F/hist-bad-row/conformance-report.md.bak"
  commit 2025-05-07 "docs: unreadable conformance histories"

  # the report was stashed before the next run, so the skill started a
  # "complete" history without the committed FAIL
  mkdir -p "$F/hist-stashed"; conformance hist-stashed gaps
  commit 2025-05-08 "docs(hist-stashed): conformance gaps"
  conformance_hist hist-stashed complete conformant
  commit 2025-05-09 "docs(hist-stashed): conformance conformant"

  # a committed failure after a committed PASS, then a history without either
  mkdir -p "$F/hist-unrecorded"; conformance hist-unrecorded conformant
  commit 2025-05-08 "docs(hist-unrecorded): conformance conformant"
  conformance hist-unrecorded divergent
  commit 2025-05-09 "docs(hist-unrecorded): conformance divergent"
  conformance_hist hist-unrecorded complete conformant
  commit 2025-05-10 "docs(hist-unrecorded): conformance history"

  # a pre-section report is committed, `git rm`ed and committed, then the
  # report is regenerated. The skill's own lookup command (read from its
  # SKILL.md) must find the pre-deletion version, which has no history
  # section, so the new history is partial.
  mkdir -p "$F/hist-deleted"; conformance hist-deleted conformant
  commit 2025-05-11 "docs(hist-deleted): conformance conformant"
  local before; before=$(cd "$REPO" && git rev-parse HEAD)
  at 2025-05-12 rm -q ai/features/hist-deleted/conformance-report.md
  commit 2025-05-12 "docs(hist-deleted): drop the report"
  local lookup found shown
  lookup=$(grep -o 'git log -1 [^`]*-- <report path>' "$SKILL_MD" | head -n 1)
  lookup=${lookup//<report path>/ai\/features\/hist-deleted\/conformance-report.md}
  LOOKUP_CMD="$lookup"
  found=$(cd "$REPO" && eval "$lookup" 2>/dev/null); LOOKUP_STATUS=$?
  LOOKUP_FOUND_PRE_DELETION=$([ "$found" = "$before" ] && echo yes || echo "no ($found)")
  shown=$(cd "$REPO" && git show "$found:ai/features/hist-deleted/conformance-report.md" 2>/dev/null); SHOW_STATUS=$?
  LOOKUP_HAS_SECTION=$(grep -q 'Verdict history' <<<"$shown" && echo yes || echo no)
  # regenerated as "complete" anyway: the metric must still see the past
  conformance_hist hist-deleted complete conformant
  commit 2025-05-13 "docs(hist-deleted): conformance regenerated"

  # a later regression the history records is not a first-time failure
  conformance_hist hist-regress complete conformant
  commit 2025-05-08 "docs(hist-regress): conformance"
  conformance_hist hist-regress complete conformant gaps
  commit 2025-05-09 "docs(hist-regress): conformance regressed"
  conformance_hist hist-regress complete conformant gaps conformant
  commit 2025-05-10 "docs(hist-regress): conformance fixed"

  # formatting a model may add: a deeper heading, bold header, emphasis, symbols
  mkdir -p "$F/hist-formatted" "$F/hist-bad-gap" "$F/hist-conflict"
  cat > "$F/hist-formatted/conformance-report.md" <<'MD'
---
feature: hist-formatted
verdict: conformant
verdict_history: complete
---

### Verdict history

| Reviewed | Head | **Verdict** | Critical | High | Medium | Low |
|---|---|---|---|---|---|---|
| 2025-05-01 | aaa1111 | **gaps** | 1 | 0 | 0 | 0 |
| 2025-05-02 | aaa2222 | ❌ divergent | 0 | 1 | 0 | 0 |
| 2025-05-03 | aaa3333 | `✓ conformant` | 0 | 0 | 0 | 0 |
MD
  # the reviewer matrix's "✗ gap" is not a verdict word
  cat > "$F/hist-bad-gap/conformance-report.md" <<'MD'
---
feature: hist-bad-gap
verdict: gaps
verdict_history: complete
---

## Verdict history

| Reviewed | Head | Verdict | Critical | High | Medium | Low |
|---|---|---|---|---|---|---|
| 2025-05-01 | bbb1111 | ✗ gap | 1 | 0 | 0 | 0 |
MD
  cat > "$F/hist-conflict/conformance-report.md" <<'MD'
---
feature: hist-conflict
verdict: conformant
verdict_history: complete
---

## Verdict history

| Reviewed | Head | Verdict | Critical | High | Medium | Low |
|---|---|---|---|---|---|---|
| 2025-05-01 | ccc1111 | gaps | 1 | 0 | 0 | 0 |
<<<<<<< HEAD
| 2025-05-02 | ccc2222 | conformant | 0 | 0 | 0 | 0 |
=======
| 2025-05-03 | ccc3333 | conformant | 0 | 0 | 0 | 0 |
>>>>>>> feat/other
MD
  commit 2025-05-10 "docs: formatted and conflicted conformance histories"

  # never-committed and two long ids: only in the working tree
  manifest "$M"'  - name: café-export\n    status: complete\n  - name: never-committed\n    status: draft\n  - name: a-very-long-feature-identifier-number-one\n    status: draft\n  - name: a-very-long-feature-identifier-number-two\n    status: draft\n'"$(printf '  - name: %s\\n    status: in-progress\\n' hist-fail-pass hist-pass hist-merged hist-squash hist-partial hist-bad-verdict hist-bad-row hist-stashed hist-unrecorded hist-deleted hist-regress hist-formatted hist-bad-gap hist-conflict)"
  spec never-committed 1
}

build_fixture

# ═══ per-feature values ══════════════════════════════════════════════════════

run --json
expect_status 0 "json run exits 0"

expect_eq 'f("invoice-export").leadTime.value' '10' "lead time runs from the spec commit to the merge that landed complete"
expect_eq 'f("invoice-export").leadTime.end' '2025-01-11T12:00:00Z' "lead time ends at the merge commit, not the branch commit"
expect_eq 'f("invoice-export").stageDwell.value.map(s => s.status + ":" + s.days).join(",")' 'draft:3,in-progress:7' "stage dwell per status on the first-parent history"
expect_eq 'f("invoice-export").stageDwell.current.status' 'complete' "current status has no dwell"
expect_eq 'f("invoice-export").deferralRate.value' '0.5556' "deferral = (3 tasks + 2 coverage rows) / (4 checked + 5 deferred)"
expect_eq '[f("invoice-export").deferralRate.checked, f("invoice-export").deferralRate.deferredTasks, f("invoice-export").deferralRate.deferredCoverageRows, f("invoice-export").deferralRate.tasks].join(",")' '4,3,2,8' "Task T5 heading, lowercase and status-marker deferrals count; fenced/table boxes and 'deferred job loading' do not"
expect_eq 'f("invoice-export").deferralRate.open' '1' "a half-done task is reported as open, outside the rate"
expect_eq 'f("invoice-export").firstTimePass.value' 'false' "PASS after an earlier FAIL is not a first-time pass"
expect_eq 'f("invoice-export").firstTimePass.verdicts.join(",")' 'gaps,conformant' "verdict history read oldest first"
expect_eq 'f("invoice-export").reworkRate.paths.join(",")' 'app/Invoice/Exporter.php,services/export/worker.py,web/[id].php' "inventory paths: PHP and Python, placeholder and other tables skipped"
expect_eq '[f("invoice-export").reworkRate.fix, f("invoice-export").reworkRate.total].join("/")' '2/3' "rework counts fix commits in the window only; web/[id].php is literal, so web/i.php is not counted"
expect_eq 'f("invoice-export").reworkRate.value' '0.6667' "rework rate value"
expect_eq 'f("invoice-export").specChurn.value' '1' "only the spec_version bump after completion counts"

expect_eq 'f("billing-sync").formerIds.join(",")' 'sync-billing' "a renamed feature carries its former id"
expect_eq 'f("billing-sync").leadTime.value' '9' "lead time of a renamed feature starts at the original spec commit"
expect_eq 'f("billing-sync").stageDwell.value.map(s => s.status + ":" + s.days).join(",")' 'draft:5,in-progress:4' "a rename is not a status transition"
expect_eq 'f("billing-sync").reworkRate.reason' 'no tech-spec.md' "rework is null with a reason when there is no inventory"
expect_eq 'f("billing-sync").deferralRate.reason' 'no implementation-plan.md or plans/*.md' "deferral is null with a reason without plans"
expect_eq 'f("billing-sync").firstTimePass.reason' 'no conformance-report.md in history' "first-time pass is null without a report"
expect_eq 'f("billing-sync").specChurn.value' '0' "no bump, no churn"

expect_eq 'f("new-name").formerIds.join(",")' 'old-name' "a one-for-one manifest swap links a rename --follow missed"
expect_eq 'f("new-name").leadTime.value + "|" + f("new-name").leadTime.end' '4|2025-04-05T12:00:00Z' "a manifest-renamed feature's lead time ends at its real completion, not the rename"
expect_eq 'f("new-name").stageDwell.value.map(s => s.status + ":" + s.days).join(",")' 'draft:2,in-progress:2' "a manifest rename keeps the pre-rename stages"

expect_eq 'f("modern-x").formerIds.join(",")' 'legacy-x' "renamedFrom links a rename the swap rule cannot see"
expect_eq 'f("modern-x").leadTime.value' '5' "renamedFrom: lead time starts at the legacy spec commit"

expect_eq 'f("retro-doc").leadTime.value === null && f("retro-doc").leadTime.reason.startsWith("first seen already complete")' 'true' "a feature first seen already complete has no lead time"
expect_eq 'f("retro-doc").firstSeenComplete' 'true' "json flags first-seen-complete"
expect_eq 'f("retro-doc").formerIds.length + "," + f("retro-doc").specFirstWritten' '0,2025-04-09T12:00:00Z' "a spec.md git sees as a copy of another feature's does not inherit its history"
expect_eq 'f("retro-doc").firstTimePass.value === null && f("retro-doc").firstTimePass.reason.startsWith("only one committed version")' 'true' "a single committed PASS is not counted as a first-time pass"

expect_eq 'f("squashed").leadTime.value === null && f("squashed").leadTime.reason.startsWith("spec.md landed in the same commit")' 'true' "a squash merge carrying spec and completion has no lead time, not 0"
expect_eq 'f("squashed").firstTimePass.value' 'false' "a single committed FAIL is still a failure"
expect_eq '[f("invoice-export").firstTimePass.basis, f("retro-doc").firstTimePass.basis, f("squashed").firstTimePass.basis].join(",")' 'committed-versions,committed-versions,committed-versions' "a report without a verdict history falls back to its committed versions"

expect_eq 'f("hist-fail-pass").firstTimePass.value + "|" + f("hist-fail-pass").firstTimePass.basis + "|" + f("hist-fail-pass").firstTimePass.committedVersions' 'false|verdict-history|1' "a history with FAIL then PASS is not a first-time pass, from one committed version"
expect_eq 'f("hist-fail-pass").firstTimePass.verdicts.join(",")' 'not-verifiable,gaps,conformant' "history rows read oldest first; not-verifiable is skipped"
expect_eq 'f("hist-pass").firstTimePass.value + "|" + f("hist-pass").firstTimePass.basis' 'true|verdict-history' "a history with one PASS row is a first-time pass"
expect_eq 'f("hist-pass").firstTimePass.verdicts.join(",")' 'conformant' "a fenced history example is not the report's history"
expect_eq 'f("hist-squash").firstTimePass.value + "|" + f("hist-squash").firstTimePass.committedVersions' 'false|1' "a squash merge keeps one version, and its history still shows the FAIL"
expect_eq 'f("hist-merged").firstTimePass.value + "|" + f("hist-merged").firstTimePass.committedVersions' 'false|2' "merge and squash of the same history agree"
expect_eq 'f("hist-partial").firstTimePass.value === null && f("hist-partial").firstTimePass.basis + "|" + f("hist-partial").firstTimePass.historyVerdicts.join(",")' 'committed-versions|conformant' "a partial history's PASS falls back to the committed versions"
expect_eq 'f("hist-bad-verdict").firstTimePass.value === null && f("hist-bad-verdict").firstTimePass.reason' 'the committed verdict history is unreadable: row 1 verdict "PASS" is not one of conformant, divergent, gaps, not-verifiable' "a verdict the skill never writes is not guessed"
expect_eq 'f("hist-bad-row").firstTimePass.value === null && f("hist-bad-row").firstTimePass.reason' 'the committed verdict history is unreadable: row 2 has 2 cells, the header 7' "a short row makes the history unreadable, not skipped"
expect_eq 'f("hist-stashed").firstTimePass.value + "|" + f("hist-stashed").firstTimePass.committedVerdicts.join(",")' 'false|gaps,conformant' "a committed FAIL wins over a complete history that lacks it"
expect_eq 'f("hist-unrecorded").firstTimePass.value' 'false' "a committed FAIL the history has no row for wins"
if [ "$LOOKUP_STATUS" -eq 0 ] && [ "$LOOKUP_FOUND_PRE_DELETION" = yes ]; then ok; else fail "the skill's report lookup finds the version before a committed deletion (exit $LOOKUP_STATUS, $LOOKUP_FOUND_PRE_DELETION; command: $LOOKUP_CMD)"; fi
if [ "$SHOW_STATUS" -eq 0 ] && [ "$LOOKUP_HAS_SECTION" = no ]; then ok; else fail "git show reads the pre-deletion report, which predates the section (exit $SHOW_STATUS, section: $LOOKUP_HAS_SECTION)"; fi
expect_eq 'f("hist-deleted").firstTimePass.partial + "|" + f("hist-deleted").firstTimePass.basis + "|" + f("hist-deleted").firstTimePass.committedVersions' 'true|committed-versions|2' "a history regenerated after a git rm is partial, whatever its flag says"
expect_eq 'f("hist-regress").firstTimePass.value + "|" + f("hist-regress").firstTimePass.verdicts.join(",")' 'true|conformant,gaps,conformant' "a committed FAIL the history records after a PASS is a regression, not a first-time failure"
expect_eq 'f("hist-formatted").firstTimePass.value + "|" + f("hist-formatted").firstTimePass.verdicts.join(",")' 'false|gaps,divergent,conformant' "a deeper heading, a bold header, emphasis, symbols and backticks are read through"
expect_eq 'f("hist-bad-gap").firstTimePass.value === null && f("hist-bad-gap").firstTimePass.reason' 'the committed verdict history is unreadable: row 1 verdict "✗ gap" is not one of conformant, divergent, gaps, not-verifiable' "stripping formatting does not widen the verdict words"
expect_eq 'f("hist-conflict").firstTimePass.value === null && f("hist-conflict").firstTimePass.reason' 'the committed verdict history is unreadable: the section has unresolved merge conflict markers' "a committed merge conflict is named"

expect_eq 'f("café-export").specChurn.value' '1' "a non-ASCII feature id reads its spec history"
expect_eq 'f("café-export").leadTime.value' '1' "a non-ASCII feature id gets a lead time"

expect_eq 'f("never-committed").leadTime.reason' 'spec.md was never committed' "an uncommitted feature has no lead time"
expect_eq 'f("never-committed").stageDwell.reason' 'the feature never appears in a committed version of its manifest' "an uncommitted feature has no dwell"

# ═══ aggregate + definitions ═════════════════════════════════════════════════

expect_eq '[d.aggregate.leadTime.median, d.aggregate.leadTime.p85, d.aggregate.leadTime.n].join(",")' '5,10,5' "lead time median and P85 exclude first-seen-complete and same-commit features"
expect_eq 'd.aggregate.leadTime.firstSeenComplete' '1' "aggregate counts the first-seen-complete exclusions"
expect_eq 'd.aggregate.stageDwell.draft.median + "," + d.aggregate.stageDwell["in-progress"].median + "," + d.aggregate.stageDwell.planned.median' '3,4,5' "median dwell per status"
expect_eq 'd.aggregate.deferralRate.value + "," + d.aggregate.deferralRate.openOnComplete' '0.5556,1' "pooled deferral rate and open tasks on complete features"
expect_eq '[d.aggregate.firstTimePass.passed, d.aggregate.firstTimePass.n].join("/")' '3/11' "first-time pass counts only non-null features"
expect_eq '[d.aggregate.firstTimePass.fromHistory, d.aggregate.firstTimePass.fromCommittedVersions].join(",")' '8,3' "aggregate counts values per basis"
expect_eq 'd.aggregate.firstTimePass.basis' '3 of 11 from committed report versions only, a lower bound on failures for those' "only the committed-version values are labelled a lower bound"
expect_eq '[d.aggregate.reworkRate.fix, d.aggregate.reworkRate.total].join("/")' '2/3' "pooled rework"
expect_eq '[d.aggregate.specChurn.bumps, d.aggregate.specChurn.featuresWithBumps, d.aggregate.specChurn.n].join(",")' '2,2,7' "spec churn aggregate"
expect_eq 'Object.keys(d.definitions).sort().join(",")' 'deferralRate,firstTimePass,landed,leadTime,reworkRate,specChurn,stageDwell' "json carries a definitions block"
expect_eq 'd.assumptions.fixPatternSource.startsWith("default")' 'true' "json names the fix-pattern assumption"

# ═══ text report ═════════════════════════════════════════════════════════════

run
expect_status 0 "text run exits 0"
expect_line '^invoice-export +complete +10 +5/9 56% +1 +no +2/3 67% +1$' "text table row carries every metric, open tasks included"
expect_line '^a-very-long-feature-identifier-number-one +draft ' "long ids are not truncated (one)"
expect_line '^a-very-long-feature-identifier-number-two +draft ' "long ids are not truncated (two)"
expect_line '^  first-time pass: +27% \(3/11\) — 3 of 11 from committed report versions only, a lower bound on failures for those$' "text names the lower-bound share of first-time pass"
expect_line '^hist-pass +in-progress .* yes ' "text table shows a first-time pass from the history"
expect_line '^  lead time: .*1 first seen already complete, excluded' "text names the lead-time exclusions"
expect_line '^  invoice-export: draft 3 -> in-progress 7 -> complete \(since 2025-01-11\)$' "stage dwell line"
expect_line '^  never-committed lead time: spec.md was never committed$' "null reasons are printed"
expect_line '^  reworkRate: fix commits / all non-merge commits' "definitions are printed"
expect_line '^fix pattern: ' "fix-pattern assumption is printed"

# ═══ filters and fix pattern ═════════════════════════════════════════════════

run --json --since=2025-04-18
expect_eq 'd.features.map(x => x.id).join(",")' 'café-export' "--since keeps features completed on or after the date and drops undated ones"

run --json --feature=invoice-export
expect_eq 'd.features.map(x => x.id).join(",")' 'invoice-export' "--feature selects one feature"

run --json --feature=invoice-export '--fix-pattern=^feat'
expect_eq '[f("invoice-export").reworkRate.fix, f("invoice-export").reworkRate.total].join("/")' '1/3' "--fix-pattern replaces the default"
expect_eq 'd.assumptions.fixPatternSource' '--fix-pattern' "the override is named in the output"

run --feature=nope
expect_status 3 "an unknown feature is an error"

# ═══ refusals and empty history ══════════════════════════════════════════════

FULL="$REPO"
SHALLOW="$ROOT/shallow"
git clone -q --depth=1 "file://$FULL" "$SHALLOW" 2>/dev/null || fail "fixture: shallow clone"
REPO="$SHALLOW"
run --json
expect_status 3 "a shallow clone is refused"
expect_line 'shallow clone' "the refusal names the shallow clone"
expect_line 'unshallow' "the refusal says how to fix it"

REPO="$ROOT/nogit"
mkdir -p "$REPO/ai/features"
printf 'features:\n  - name: a\n    status: draft\n' > "$REPO/ai/features/index.yaml"
printf '{"aiDir":"ai"}\n' > "$REPO/.myspec.json"
run --json
expect_status 3 "outside a git repository the script refuses"
expect_line 'not a git repository' "the refusal says why"

REPO="$ROOT/empty"
mkdir -p "$REPO/ai/features/a"
(cd "$REPO" && git init -q -b main .)
printf '{"aiDir":"ai"}\n' > "$REPO/.myspec.json"
printf 'features:\n  - name: a\n    status: draft\n' > "$REPO/ai/features/index.yaml"
printf -- '---\nspec_version: 1\n---\n' > "$REPO/ai/features/a/spec.md"
run --json
expect_status 0 "an empty repository is not an error"
expect_eq 'f("a").leadTime.value === null && f("a").leadTime.reason' 'the repository has no commits yet' "empty repository: history metrics are null with the reason"
expect_eq 'd.aggregate.leadTime.value === null' 'true' "empty repository: aggregate is null"
run
expect_line 'history: +the repository has no commits yet' "text report states the empty history"

REPO="$ROOT/empty"
rm -f "$REPO/ai/features/index.yaml"
run
expect_status 3 "a missing manifest is an error"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
