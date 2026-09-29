#!/usr/bin/env bash
# Regression fixture for lib/delivery-metrics/metrics.mjs.
#
# Builds a git repository with a synthetic, fully dated feature history and
# asserts every metric's exact value: lead time (spec commit -> the merge that
# landed status complete), stage dwell, plan deferral rate, conformance
# first-time pass (FAIL then PASS), rework rate (fix commits inside and outside
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

  # never-committed: only in the working tree
  manifest '  - name: invoice-export\n    status: complete\n  - name: billing-sync\n    status: complete\n  - name: never-committed\n    status: draft\n'
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
expect_eq 'f("invoice-export").deferralRate.value' '0.5' "deferral = (1 task + 1 coverage row) / (2 checked + 2 deferred)"
expect_eq '[f("invoice-export").deferralRate.checked, f("invoice-export").deferralRate.deferredTasks, f("invoice-export").deferralRate.deferredCoverageRows, f("invoice-export").deferralRate.tasks].join(",")' '2,1,1,4' "fenced and table checkboxes ignored; half-done task neither checked nor deferred"
expect_eq 'f("invoice-export").firstTimePass.value' 'false' "PASS after an earlier FAIL is not a first-time pass"
expect_eq 'f("invoice-export").firstTimePass.verdicts.join(",")' 'gaps,conformant' "verdict history read oldest first"
expect_eq 'f("invoice-export").reworkRate.paths.join(",")' 'app/Invoice/Exporter.php,services/export/worker.py' "inventory paths: PHP and Python, placeholder and other tables skipped"
expect_eq '[f("invoice-export").reworkRate.fix, f("invoice-export").reworkRate.total].join("/")' '2/3' "rework counts fix commits in the window only"
expect_eq 'f("invoice-export").reworkRate.value' '0.6667' "rework rate value"
expect_eq 'f("invoice-export").specChurn.value' '1' "only the spec_version bump after completion counts"

expect_eq 'f("billing-sync").formerIds.join(",")' 'sync-billing' "a renamed feature carries its former id"
expect_eq 'f("billing-sync").leadTime.value' '9' "lead time of a renamed feature starts at the original spec commit"
expect_eq 'f("billing-sync").stageDwell.value.map(s => s.status + ":" + s.days).join(",")' 'draft:5,in-progress:4' "a rename is not a status transition"
expect_eq 'f("billing-sync").reworkRate.reason' 'no tech-spec.md' "rework is null with a reason when there is no inventory"
expect_eq 'f("billing-sync").deferralRate.reason' 'no implementation-plan.md or plans/*.md' "deferral is null with a reason without plans"
expect_eq 'f("billing-sync").firstTimePass.reason' 'no conformance-report.md in history' "first-time pass is null without a report"
expect_eq 'f("billing-sync").specChurn.value' '0' "no bump, no churn"

expect_eq 'f("never-committed").leadTime.reason' 'spec.md was never committed' "an uncommitted feature has no lead time"
expect_eq 'f("never-committed").stageDwell.reason' 'the feature never appears in a committed version of its manifest' "an uncommitted feature has no dwell"

# ═══ aggregate + definitions ═════════════════════════════════════════════════

expect_eq '[d.aggregate.leadTime.median, d.aggregate.leadTime.p85, d.aggregate.leadTime.n].join(",")' '9.5,10,2' "lead time median and P85"
expect_eq 'd.aggregate.stageDwell.draft.median + "," + d.aggregate.stageDwell["in-progress"].median' '4,5.5' "median dwell per status"
expect_eq 'd.aggregate.deferralRate.value' '0.5' "pooled deferral rate"
expect_eq '[d.aggregate.firstTimePass.passed, d.aggregate.firstTimePass.n].join("/")' '0/1' "first-time pass counts only features with a decisive verdict"
expect_eq '[d.aggregate.reworkRate.fix, d.aggregate.reworkRate.total].join("/")' '2/3' "pooled rework"
expect_eq '[d.aggregate.specChurn.bumps, d.aggregate.specChurn.featuresWithBumps, d.aggregate.specChurn.n].join(",")' '1,1,2' "spec churn aggregate"
expect_eq 'Object.keys(d.definitions).sort().join(",")' 'deferralRate,firstTimePass,landed,leadTime,reworkRate,specChurn,stageDwell' "json carries a definitions block"
expect_eq 'd.assumptions.fixPatternSource.startsWith("default")' 'true' "json names the fix-pattern assumption"

# ═══ text report ═════════════════════════════════════════════════════════════

run
expect_status 0 "text run exits 0"
expect_line '^invoice-export +complete +10 +2/4 50% +no +2/3 67% +1$' "text table row carries every metric"
expect_line '^  invoice-export: draft 3 -> in-progress 7 -> complete \(since 2025-01-11\)$' "stage dwell line"
expect_line '^  never-committed lead time: spec.md was never committed$' "null reasons are printed"
expect_line '^  reworkRate: fix commits / all non-merge commits' "definitions are printed"
expect_line '^fix pattern: ' "fix-pattern assumption is printed"

# ═══ filters and fix pattern ═════════════════════════════════════════════════

run --json --since=2025-02-01
expect_eq 'd.features.map(x => x.id).join(",")' 'billing-sync' "--since keeps features completed on or after the date and drops undated ones"

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
