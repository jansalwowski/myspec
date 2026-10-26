#!/usr/bin/env bash
# Deterministic tests for the fold comparison (scripts/evals/fold-compare.mjs).
# No model calls: the evals dir and the results are built here.
#
# Usage: scripts/tests/eval-fold-compare.test.sh

set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FC="$SRC_ROOT/scripts/evals/fold-compare.mjs"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: [$3]"$'\n'"actual:   [$2]"; fi; }
expect_has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else nok "$1" "missing [$3] in:"$'\n'"$2"; fi; }

# mkcase <evals> <name> <tags> <prompt body> <grader>...: a grader is name=content.
mkcase() {
  local e="$1" name="$2" tags="$3" prompt="$4"; shift 4
  mkdir -p "$e/$name/graders"
  printf -- '---\ntags: [%s]\n---\n\n%s\n' "$tags" "$prompt" > "$e/$name/prompt.md"
  for g in "$@"; do printf '%s\n' "${g#*=}" > "$e/$name/graders/${g%%=*}.md"; done
}

echo "# lint of the real evals/ suite"
out=$(cd "$SRC_ROOT" && node "$FC" --lint 2>&1); rc=$?
expect_eq "real suite: every fold pair is well formed" "$rc:$out" "0:"

echo "# lint"
E="$TMP/evals"
mkcase "$E" p-sub "skill:x, fold-pair:p, fold-arm:subagent, capability" "Review it." found=A dispatched=D
mkcase "$E" p-inl "skill:x, fold-pair:p, fold-arm:inline, regression" "Review it." found=A
out=$(node "$FC" --lint --evals-dir "$E" 2>&1); rc=$?
expect_eq "a well-formed pair lints clean" "$rc:$out" "0:"

mkcase "$E" q-sub "skill:x, fold-pair:q, fold-arm:subagent, capability" "Review it." found=A
mkcase "$E" q-inl "skill:x, fold-pair:q, fold-arm:inline, capability" "Review it, please." found=B
mkcase "$E" r-sub "skill:x, fold-pair:r, fold-arm:subagent, capability" "Go." found=A
mkcase "$E" s-odd "skill:x, fold-pair:s, fold-arm:both, capability" "Go." found=A
out=$(node "$FC" --lint --evals-dir "$E" 2>&1); rc=$?
expect_eq "a broken pair fails the lint" "$rc" 1
expect_has "different prompts are named" "$out" "fold-pair:q: q-sub and q-inl have different prompts"
expect_has "no shared grader is named (same name, other content)" "$out" "fold-pair:q: q-sub and q-inl share no grader"
expect_has "a pair missing its inline arm is named" "$out" "fold-pair:r: needs one subagent and one inline case"
expect_has "an unknown arm is named" "$out" "s-odd: fold-arm must be subagent or inline, not both"
rm -rf "$E/q-sub" "$E/q-inl" "$E/r-sub" "$E/s-odd"

echo "# comparison"
# results <dir> <model> <case>:<run>,<run>... where a run is grader=0|1 joined by +,
# with an optional @cost. A run named ERR ended in an error and is left out.
results() {
  node - "$@" <<'JS'
const fs = require('fs'), path = require('path');
const [dir, model, ...specs] = process.argv.slice(2);
const cases = specs.map((s) => {
  const [name, runs] = s.split(':');
  return { name, arms: { with: runs.split(',').map((r) => {
    if (r === 'ERR') return { error: 'boom', graders: [] };
    const [gs, cost] = r.split('@');
    return { costUsd: Number(cost || 0.1), durationSeconds: 10, graders: gs.split('+').map((g) => {
      const [n, v] = g.split('='); return { name: n, passed: v === '1', scored: true };
    }) };
  }) } };
});
fs.mkdirSync(path.join(dir, model), { recursive: true });
fs.writeFileSync(path.join(dir, model, 'aggregate-result.json'), JSON.stringify({ suite: { modelOverride: model }, cases }));
JS
}
jv() { node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")); console.log(eval(process.argv[1]))' "$1"; }

results "$TMP/r1" sonnet "p-sub:found=1+dispatched=0,found=1+dispatched=1,found=0+dispatched=1" "p-inl:found=1@0.05,found=1@0.05,found=1@0.05,ERR"
out=$(node "$FC" "$TMP/r1" --evals-dir "$E" --json); rc=$?
expect_eq "exit 0 on a report" "$rc" 0
expect_eq "inline scores no worse: fold-candidate" "$(printf '%s' "$out" | jv 'd[0].verdict')" "fold-candidate"
expect_eq "the dispatch grader is not an outcome" "$(printf '%s' "$out" | jv 'd[0].subagent.outcome')" "0.667"
expect_eq "an errored run is left out" "$(printf '%s' "$out" | jv 'd[0].inline.runs')" "3"
expect_eq "3 runs per arm is not tentative" "$(printf '%s' "$out" | jv 'd[0].tentative')" "false"
expect_eq "a shared grader that moved is listed" "$(printf '%s' "$out" | jv 'd[0].flipped.join()')" "found"
expect_eq "mean cost per run" "$(printf '%s' "$out" | jv 'd[0].inline.cost_usd')" "0.05"

results "$TMP/r2" sonnet "p-sub:found=1+dispatched=1" "p-inl:found=0"
out=$(node "$FC" "$TMP/r2" --evals-dir "$E"); rc=$?
expect_has "inline scores worse: keep-subagent, tentative on one run" "$out" "sonnet  fold-pair:p  keep-subagent (tentative: under 3 runs in an arm)"

results "$TMP/r3" sonnet "p-sub:found=1+dispatched=1"
out=$(node "$FC" "$TMP/r3" --evals-dir "$E" --json)
expect_eq "one arm absent: missing-arm" "$(printf '%s' "$out" | jv 'd[0].verdict')" "missing-arm"

results "$TMP/r4a" sonnet "p-sub:found=1+dispatched=1"
results "$TMP/r4b" sonnet "p-inl:found=1"
out=$(node "$FC" "$TMP/r4a" "$TMP/r4b" --evals-dir "$E" --json)
expect_eq "arms from two results dirs are joined" "$(printf '%s' "$out" | jv 'd[0].verdict + " " + d[0].subagent.runs + " " + d[0].inline.runs')" "fold-candidate 1 1"

results "$TMP/r5" sonnet "other:found=1"
out=$(node "$FC" "$TMP/r5" --evals-dir "$E")
expect_eq "no pair case in the results" "$out" "no fold-pair case in these results"

out=$(node "$FC" --evals-dir "$E" 2>&1); rc=$?
expect_eq "no results dir: exit 2" "$rc" 2

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
