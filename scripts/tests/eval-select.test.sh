#!/usr/bin/env bash
# Deterministic tests for the eval tooling: case selection in
# scripts/evals/run.sh --mode changed, its exit-code contract, the
# .githooks/pre-push ref parsing, and a lint of the real evals/ suite.
#
# No model calls: `claude` is a stub (MYSPEC_EVAL_CLAUDE) that records its
# arguments and writes a canned aggregate-result.json.
#
# Usage: scripts/tests/eval-select.test.sh

set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: [$3]"$'\n'"actual:   [$2]"; fi; }
expect_has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else nok "$1" "missing [$3] in:"$'\n'"$2"; fi; }
expect_lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then nok "$1" "unexpected [$3] in:"$'\n'"$2"; else ok "$1"; fi; }

# ------------------------------------------------------------ stub claude

STUB="$TMP/stub-claude"
STUB_LOG="$TMP/stub.log"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "${1:-} ${2:-}" = "auth status" ]; then
  printf '{"loggedIn": %s}\n' "${STUB_LOGGED_IN:-true}"
  exit 0
fi
if [ "${1:-} ${2:-}" = "plugin eval" ]; then
  [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
  out="" case_name="all" model="-"
  while [ $# -gt 0 ]; do
    case "$1" in
      --output-dir) out="$2"; shift ;;
      --case) case_name="$2"; shift ;;
      --model) model="$2"; shift ;;
    esac
    shift
  done
  if [ "${STUB_WRITE:-1}" = 1 ]; then
    mkdir -p "$out"
    cat > "$out/aggregate-result.json" <<JSON
{"schemaVersion":1,"costUsd":0.01,"durationSeconds":3,"partial":${STUB_PARTIAL:-false},
 "suite":{"modelOverride":"$model"},
 "cases":[{"name":"$case_name",
   "graders":[{"name":"right-skill","type":"tool_used","config":{"tool":"Skill"}},
              {"name":"wrong-skill","type":"tool_used","config":{"tool":"Skill","min":0,"max":0}}],
   "aggregates":{"score":${STUB_SCORE:-1}},
   "arms":{"with":[{"score":${STUB_SCORE:-1},"costUsd":${STUB_COST:-0.01},"judgeCostUsd":0,"durationSeconds":3,"error":${STUB_ERROR:-null},
     "graders":[{"name":"right-skill","passed":true},{"name":"wrong-skill","passed":true}]}]}}]}
JSON
  fi
  [ -n "${STUB_STDERR:-}" ] && echo "$STUB_STDERR" >&2
  exit "${STUB_EXIT:-0}"
fi
exit 0
SH
chmod +x "$STUB"
export STUB_LOG MYSPEC_EVAL_CLAUDE="$STUB"
unset MYSPEC_EVALS_STRICT MYSPEC_SKIP_EVALS MYSPEC_EVALS_DRY_RUN MYSPEC_EVAL_THRESHOLD \
  MYSPEC_EVAL_DEADLINE_SECONDS MYSPEC_EVAL_MAX_COST_USD MYSPEC_EVAL_CONCURRENCY CLAUDECODE MYSPEC_EVALS_IN_AGENT
# The reachability probe must not touch the network in tests.
export MYSPEC_EVAL_PROBE_URL="file:///dev/null"

# ------------------------------------------------------- synthetic repo

ORIGIN="$TMP/origin.git"
REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t
git config commit.gpgsign false

mkdir -p scripts/evals .githooks
cp "$SRC_ROOT/scripts/evals/run.sh" "$SRC_ROOT/scripts/evals/summary.mjs" scripts/evals/
cp "$SRC_ROOT/.githooks/pre-push" .githooks/pre-push
chmod +x scripts/evals/run.sh .githooks/pre-push

mkdir -p skills/alpha skills/beta skills/gamma skills/_shared \
  evals/_fixtures/fx-billing evals/case-alpha evals/case-beta evals/case-alpha-gamma
echo "see [conv](../_shared/outer.md)" > skills/beta/SKILL.md
echo "alpha" > skills/alpha/SKILL.md
echo "uses _shared/a-top.md" > skills/gamma/SKILL.md
echo "see _shared/mid.md" > skills/_shared/a-top.md
echo "see _shared/zz-deep.md" > skills/_shared/mid.md
echo "deepest" > skills/_shared/zz-deep.md
echo "see [inner](inner.md) and _shared/inner.md" > skills/_shared/outer.md
echo "inner rules" > skills/_shared/inner.md
echo "orphan shared" > skills/_shared/unused.md
printf '#!/usr/bin/env bash\necho lib\n' > evals/_fixtures/lib.sh
echo data > evals/_fixtures/fx-billing/data.txt
mkcase() {  # mkcase <name> <tags> <fixture body>
  printf -- '---\ntags: [%s]\n---\n\nprompt\n' "$2" > "evals/$1/prompt.md"
  printf 'schema_version: "1.1"\nname: %s\ncontext:\n  scaffold_script: fixture.sh\n' "$1" > "evals/$1/case.yaml"
  printf '#!/usr/bin/env bash\n. ../_fixtures/lib.sh\n%s\n' "$3" > "evals/$1/fixture.sh"
}
mkcase case-alpha "skill:alpha, trigger, regression" ":"
mkcase case-beta "skill:beta, trigger, regression" "copy_tree fx-billing"
mkcase case-alpha-gamma "skill:alpha, skill:gamma, near-miss, regression" ":"
echo readme > README.md
git add -A
git commit -qm base
git clone -q --bare . "$ORIGIN"
git remote add origin "$ORIGIN"
git fetch -q origin

RUN="$REPO/scripts/evals/run.sh"
BASE=$(git rev-parse HEAD)

# selected <branch> <files...>: commit edits on a fresh branch off main and
# print the sorted case list run.sh selects (dry run).
selected() {
  local branch="$1"; shift
  git checkout -q -B "$branch" main
  local f
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "change $branch" >> "$f"; done
  git add -A
  git commit -qm "change $branch"
  MYSPEC_EVALS_DRY_RUN=1 "$RUN" --mode changed --out "$TMP/out-$branch" 2>&1 \
    | sed -n 's/^  \([a-z].*\)$/\1/p' | grep -v '^dry-run' | sort | tr '\n' ' ' | sed 's/ $//'
}

echo "# case selection (changed mode)"
expect_eq "skill change selects the cases tagged with it" \
  "$(selected s1 skills/alpha/SKILL.md)" "case-alpha case-alpha-gamma"
expect_eq "_shared change selects cases of skills that reference it" \
  "$(selected s3 skills/_shared/outer.md)" "case-beta"
expect_eq "_shared change propagates through another _shared file" \
  "$(selected s4 skills/_shared/inner.md)" "case-beta"
expect_eq "_shared change propagates through two _shared files, any order" \
  "$(selected s4b skills/_shared/zz-deep.md)" "case-alpha-gamma"
expect_eq "_shared file no skill references selects nothing" \
  "$(selected s5 skills/_shared/unused.md)" ""
expect_eq "fixture entry selects the cases that mention it" \
  "$(selected s6 evals/_fixtures/fx-billing/data.txt)" "case-beta"
expect_eq "shared fixture library selects every case that sources it" \
  "$(selected s7 evals/_fixtures/lib.sh)" "case-alpha case-alpha-gamma case-beta"
expect_eq "editing a case selects that case" \
  "$(selected s8 evals/case-alpha-gamma/prompt.md)" "case-alpha-gamma"
expect_eq "sibling skill tag selects the near-miss case" \
  "$(selected s9 skills/gamma/SKILL.md)" "case-alpha-gamma"

git checkout -q -B s10 main
echo more >> README.md; git commit -qam "docs only"
out=$("$RUN" --mode changed 2>&1); rc=$?
expect_eq "no skill changed: exit 0" "$rc" "0"
expect_has "no skill changed: says nothing to run" "$out" "nothing to run"
expect_lacks "no skill changed: never calls claude" "$(cat "$STUB_LOG" 2>/dev/null)" "plugin eval"

git checkout -q -B s11 main
echo x >> skills/alpha/SKILL.md; echo x >> skills/beta/SKILL.md; git commit -qam "two skills"
out=$(MYSPEC_EVALS_DRY_RUN=1 "$RUN" --mode changed --case 'case-alpha*' --out "$TMP/out-s11" 2>&1)
expect_has "--case glob keeps matching selections" "$out" "  case-alpha-gamma"
expect_lacks "--case glob drops the rest" "$out" "  case-beta"

out=$("$RUN" --mode changed --base does-not-exist 2>&1); rc=$?
expect_eq "unknown --base: exit 2" "$rc" "2"
out=$("$RUN" --mode sometimes 2>&1); rc=$?
expect_eq "bad --mode: exit 2" "$rc" "2"

echo "# explicit base and full mode"
out=$(MYSPEC_EVALS_DRY_RUN=1 "$RUN" --mode changed --base "$BASE" --out "$TMP/out-b" 2>&1)
expect_has "--base is honoured" "$out" "base=${BASE:0:12}"
out=$(MYSPEC_EVALS_DRY_RUN=1 "$RUN" --mode full --out "$TMP/out-full" 2>&1)
expect_has "full: sonnet arm" "$out" "--model sonnet"
expect_has "full: haiku arm" "$out" "--model haiku"
expect_has "full: 3 runs" "$out" "--runs 3"
expect_has "full: judge pinned to sonnet" "$out" "--judge-model sonnet"
expect_has "full: per-model output dir" "$out" "$TMP/out-full/haiku"
for flag in --trust-plugin --scaffold --no-publish --max-cost-usd --allow-tools; do
  expect_has "full: passes $flag" "$out" "$flag"
done

echo "# exit-code contract (stub claude)"
git checkout -q s1
: > "$STUB_LOG"
out=$("$RUN" --mode changed --out "$TMP/x0" 2>&1); rc=$?
expect_eq "passing run: exit 0" "$rc" "0"
expect_has "one invocation per selected case" "$(cat "$STUB_LOG")" "--case case-alpha-gamma"
expect_has "summary table printed" "$out" "CASE"
expect_has "summary shows fired indicator" "$out" "1/1"

out=$(STUB_SCORE=0.5 STUB_EXIT=1 "$RUN" --mode changed --out "$TMP/x1" 2>&1); rc=$?
expect_eq "below threshold, report-only: exit 0" "$rc" "0"
expect_has "below threshold is reported" "$out" "below threshold"
out=$(MYSPEC_EVALS_STRICT=1 STUB_SCORE=0.5 STUB_EXIT=1 "$RUN" --mode changed --out "$TMP/x2" 2>&1); rc=$?
expect_eq "below threshold, strict: exit 1" "$rc" "1"
out=$(MYSPEC_EVALS_STRICT=1 STUB_PARTIAL=true STUB_EXIT=2 "$RUN" --mode changed --out "$TMP/x3" 2>&1); rc=$?
expect_eq "cost ceiling / auth (eval exit 2): exit 2 even when strict" "$rc" "2"
out=$(STUB_WRITE=0 STUB_EXIT=1 STUB_STDERR="1 case file(s) failed to load" "$RUN" --mode changed --out "$TMP/x4" 2>&1); rc=$?
expect_eq "eval exit 1 with a load failure: exit 2" "$rc" "2"
out=$(STUB_WRITE=0 STUB_EXIT=1 "$RUN" --mode changed --out "$TMP/x4b" 2>&1); rc=$?
expect_eq "eval exit 1 without a result: exit 2" "$rc" "2"
out=$(STUB_EXIT=1 STUB_STDERR="1 case file(s) failed to load" "$RUN" --mode changed --out "$TMP/x4c" 2>&1); rc=$?
expect_eq "eval exit 1, result written but a case failed to load: exit 2" "$rc" "2"
out=$(MYSPEC_EVAL_CLAUDE="$TMP/no-such-claude" "$RUN" --mode changed --out "$TMP/x5" 2>&1); rc=$?
expect_eq "claude missing: exit 2" "$rc" "2"
out=$(STUB_LOGGED_IN=false "$RUN" --mode changed --out "$TMP/x6" 2>&1); rc=$?
expect_eq "not logged in: exit 2" "$rc" "2"
expect_has "not logged in: says how to fix" "$out" "claude auth login"

echo "# errored runs, reachability, deadline, cumulative cost, results dir"
out=$(STUB_ERROR='"exit 1: API Error: Connection refused"' STUB_SCORE=0.67 STUB_EXIT=1 "$RUN" --mode changed --out "$TMP/e1" 2>&1); rc=$?
expect_eq "run that ended in an API error: exit 2, not below threshold" "$rc" "2"
expect_lacks "API error: not reported as a low score" "$out" "0.67"
expect_has "API error: row marked as an error" "$out" "error"
out=$(MYSPEC_EVALS_STRICT=1 STUB_ERROR='"exit 1: API Error: Connection refused"' STUB_SCORE=0.67 STUB_EXIT=1 "$RUN" --mode changed --out "$TMP/e2" 2>&1); rc=$?
expect_eq "API error under strict: exit 2 (fail open), never 1" "$rc" "2"
out=$(STUB_ERROR='"exit 1: Reached maximum number of turns (6)"' "$RUN" --mode changed --out "$TMP/e3" 2>&1); rc=$?
expect_eq "max_turns cap is not an infrastructure error: exit 0" "$rc" "0"

: > "$STUB_LOG"
start=$(date +%s)
out=$(MYSPEC_EVAL_PROBE_URL="http://127.0.0.1:9/" "$RUN" --mode changed --out "$TMP/p1" 2>&1); rc=$?
expect_eq "API unreachable: exit 2" "$rc" "2"
expect_has "API unreachable: says so" "$out" "cannot reach"
expect_lacks "API unreachable: no eval run started" "$(cat "$STUB_LOG")" "plugin eval"
[ $(( $(date +%s) - start )) -lt 15 ] && ok "API unreachable: fails in seconds" || nok "API unreachable: fails in seconds"

git checkout -q s7   # lib.sh change: selects all three cases
: > "$STUB_LOG"
start=$(date +%s)
out=$(MYSPEC_EVAL_CONCURRENCY=1 MYSPEC_EVAL_DEADLINE_SECONDS=2 STUB_SLEEP=4 "$RUN" --mode changed --out "$TMP/d1" 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
expect_eq "deadline: exit 2" "$rc" "2"
expect_has "deadline: says it stopped" "$out" "deadline of 2s reached"
expect_eq "deadline: no further case launched" "$(grep -c 'plugin eval' "$STUB_LOG")" "1"
[ "$elapsed" -lt 8 ] && ok "deadline: in-flight run stopped (${elapsed}s)" || nok "deadline: in-flight run stopped (${elapsed}s)"

: > "$STUB_LOG"
out=$(MYSPEC_EVAL_CONCURRENCY=1 MYSPEC_EVAL_MAX_COST_USD=0.015 STUB_COST=0.01 "$RUN" --mode changed --out "$TMP/c1" 2>&1); rc=$?
expect_eq "cumulative cost ceiling: exit 2" "$rc" "2"
expect_has "cumulative cost ceiling: says so" "$out" "cost ceiling \$0.015 reached"
expect_eq "cumulative cost ceiling: stops after the budget is spent" "$(grep -c 'plugin eval' "$STUB_LOG")" "2"
expect_has "cumulative cost ceiling: next invocation gets the remainder" "$(grep 'plugin eval' "$STUB_LOG" | sed -n 2p)" "--max-cost-usd 0.0050"
: > "$STUB_LOG"
LC_ALL=pl_PL.UTF-8 "$RUN" --mode changed --out "$TMP/c2" >/dev/null 2>&1
expect_has "cost passed with a dot even in a comma-decimal locale" "$(cat "$STUB_LOG")" "--max-cost-usd 2.0000"

rm -rf "$REPO/.eval-results"
MYSPEC_EVALS_DRY_RUN=1 "$RUN" --mode changed >/dev/null 2>&1 &
MYSPEC_EVALS_DRY_RUN=1 "$RUN" --mode changed >/dev/null 2>&1 &
wait
ndirs=$(ls -d "$REPO"/.eval-results/*-changed* 2>/dev/null | wc -l | tr -d ' ')
expect_eq "two runs started together get separate results dirs" "$ndirs" "2"
rm -rf "$REPO/.eval-results"

echo "# pre-push ref parsing"
HOOK="$REPO/.githooks/pre-push"
ZERO=0000000000000000000000000000000000000000
git checkout -q s1
tip=$(git rev-parse HEAD)
: > "$STUB_LOG"
out=$(echo "refs/heads/s1 $tip refs/heads/s1 $ZERO" | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "new branch: exit 0" "$rc" "0"
expect_has "new branch: range starts at merge base with origin/main" "$out" "base=${BASE:0:12}"
expect_has "new branch: runs the changed skill's cases" "$(cat "$STUB_LOG")" "--case case-alpha"
expect_has "new branch: 1 run" "$(cat "$STUB_LOG")" "--runs 1"
expect_has "new branch: sonnet" "$(cat "$STUB_LOG")" "--model sonnet"

git push -q origin s1
echo more >> README.md; git commit -qam "docs after push"
tip2=$(git rev-parse HEAD)
: > "$STUB_LOG"
out=$(echo "refs/heads/s1 $tip2 refs/heads/s1 $tip" | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "existing branch, docs-only push: exit 0" "$rc" "0"
expect_has "existing branch: range starts at the remote sha" "$out" "no eval cases cover"
expect_lacks "existing branch, docs-only: no eval run" "$(cat "$STUB_LOG")" "plugin eval"

: > "$STUB_LOG"
out=$(echo "(delete) $ZERO refs/heads/old $tip" | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "deleted ref: exit 0" "$rc" "0"
expect_eq "deleted ref: nothing runs" "$(cat "$STUB_LOG")" ""
expect_lacks "deleted ref: skipped as a deletion, silently" "$out" "not checked out"

out=$(echo "refs/tags/v9.9.9 $tip2 refs/tags/v9.9.9 $ZERO" | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "tag push: skipped" "$(cat "$STUB_LOG")" ""

out=$(echo "refs/heads/s2 $(git rev-parse s2) refs/heads/s2 $ZERO" | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "ref that is not HEAD: exit 0" "$rc" "0"
expect_has "ref that is not HEAD: explains the skip" "$out" "not checked out"

out=$(printf '' | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "empty stdin: exit 0" "$rc" "0"

git checkout -q -B s12 main
echo y >> skills/alpha/SKILL.md; git commit -qam "alpha again"
tip3=$(git rev-parse HEAD)
line="refs/heads/s12 $tip3 refs/heads/s12 $ZERO"
out=$(echo "$line" | MYSPEC_SKIP_EVALS=1 "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "MYSPEC_SKIP_EVALS=1: exit 0" "$rc" "0"
expect_has "MYSPEC_SKIP_EVALS=1: says skipped" "$out" "skipped"
out=$(echo "$line" | MYSPEC_EVAL_CLAUDE="$TMP/no-such-claude" "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "claude missing: hook fails open" "$rc" "0"
expect_has "claude missing: hook warns" "$out" "pushing anyway"
start=$(date +%s)
out=$(echo "$line" | STUB_LOGGED_IN=false "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "not logged in: hook fails open" "$rc" "0"
[ $(( $(date +%s) - start )) -lt 20 ] && ok "not logged in: hook returns promptly" || nok "not logged in: hook returns promptly"
out=$(echo "$line" | STUB_SCORE=0.5 STUB_EXIT=1 "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "below threshold, report-only: push allowed" "$rc" "0"
out=$(echo "$line" | MYSPEC_EVALS_STRICT=1 STUB_SCORE=0.5 STUB_EXIT=1 "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "below threshold, strict: push blocked" "$rc" "1"

echo "# pre-push: hint first, agent skip, deadline, offline"
out=$(echo "$line" | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
first=$(printf '%s\n' "$out" | head -1)
expect_has "hint comes first: case count" "$first" "2 eval case(s)"
expect_has "hint comes first: time estimate" "$first" "about 60s"
expect_has "hint comes first: how to skip" "$first" "MYSPEC_SKIP_EVALS=1"
: > "$STUB_LOG"
out=$(echo "$line" | CLAUDECODE=1 "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "inside Claude Code: exit 0" "$rc" "0"
expect_has "inside Claude Code: tells the agent to run the evals itself" "$out" "scripts/evals/run.sh --mode changed"
expect_lacks "inside Claude Code: no eval run" "$(cat "$STUB_LOG")" "plugin eval"
: > "$STUB_LOG"
out=$(echo "$line" | CLAUDECODE=1 MYSPEC_EVALS_IN_AGENT=1 "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_has "MYSPEC_EVALS_IN_AGENT=1: runs anyway" "$(cat "$STUB_LOG")" "plugin eval"
start=$(date +%s)
out=$(echo "$line" | MYSPEC_EVALS_STRICT=1 MYSPEC_EVAL_DEADLINE_SECONDS=2 STUB_SLEEP=6 "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "deadline in the hook: push goes ahead even when strict" "$rc" "0"
[ $(( $(date +%s) - start )) -lt 10 ] && ok "deadline in the hook: returns promptly" || nok "deadline in the hook: returns promptly"
out=$(echo "$line" | MYSPEC_EVALS_STRICT=1 MYSPEC_EVAL_PROBE_URL="http://127.0.0.1:9/" "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_eq "offline push with strict: fails open" "$rc" "0"

echo "# pre-push: force push after a rebase"
git checkout -q -B fp main
echo "gamma work" >> skills/gamma/SKILL.md; git commit -qam "gamma change on the branch"
git push -q origin fp
old_tip=$(git rev-parse HEAD)
git checkout -q main
echo "beta work" >> skills/beta/SKILL.md; git commit -qam "beta change on main"
git push -q origin main
git checkout -q fp
git rebase -q main
new_tip=$(git rev-parse HEAD)
: > "$STUB_LOG"
out=$(echo "refs/heads/fp $new_tip refs/heads/fp $old_tip" | "$HOOK" origin "$ORIGIN" 2>&1); rc=$?
expect_has "force push after rebase: evaluates the branch's own change" "$(cat "$STUB_LOG")" "--case case-alpha-gamma"
expect_lacks "force push after rebase: does not evaluate main's change" "$(cat "$STUB_LOG")" "--case case-beta"

echo "# real git push through the hook (temp repo's own config only)"
git checkout -q s12
git config core.hooksPath .githooks
: > "$STUB_LOG"
out=$(git push -q origin s12 2>&1 < /dev/null); rc=$?
expect_eq "git push with the hook installed: succeeds" "$rc" "0"
expect_has "git push: the hook ran the changed skill's cases" "$(cat "$STUB_LOG")" "--case case-alpha"
: > "$STUB_LOG"
out=$(MYSPEC_EVALS_STRICT=1 STUB_SCORE=0.5 STUB_EXIT=1 git push -q origin s12:s12-strict 2>&1 < /dev/null); rc=$?
expect_eq "git push, strict and below threshold: push rejected" "$rc" "1"
if git ls-remote --exit-code origin refs/heads/s12-strict >/dev/null 2>&1; then nok "strict: branch must not reach the remote"; else ok "strict: branch did not reach the remote"; fi
git config --unset core.hooksPath

echo "# lint of the real evals/ suite"
cat > "$TMP/lint.cjs" <<'JS'
const fs = require('fs'), path = require('path');
const E = 'evals';
const problems = [];
for (const name of fs.readdirSync(E)) {
  const dir = path.join(E, name);
  if (!fs.statSync(dir).isDirectory() || !fs.existsSync(path.join(dir, 'prompt.md'))) continue;
  const prompt = fs.readFileSync(path.join(dir, 'prompt.md'), 'utf8');
  const tagLine = (prompt.match(/^tags:\s*\[(.*)\]\s*$/m) || [, ''])[1];
  const tags = tagLine.split(',').map((t) => t.trim()).filter(Boolean);
  const skillTags = new Set(tags.filter((t) => t.startsWith('skill:')).map((t) => t.slice(6)));
  if (!tags.includes('regression') && !tags.includes('capability')) problems.push(`${name}: no tier tag (regression|capability)`);
  if (skillTags.size === 0) problems.push(`${name}: no skill:<name> tag`);
  const gdir = path.join(dir, 'graders');
  const graders = fs.existsSync(gdir) ? fs.readdirSync(gdir).map((g) => fs.readFileSync(path.join(gdir, g), 'utf8')) : [];
  if (!graders.some((g) => /^type:\s*(regex|tool_used|tool_order|file_exists)\s*$/m.test(g))) problems.push(`${name}: no deterministic grader`);
  for (const g of graders) {
    const m = g.match(/^input_match:.*"skill".*?\)?\??([a-z0-9-]+)"'\s*$/m);
    if (m && !skillTags.has(m[1])) problems.push(`${name}: grader names skill ${m[1]} but tags lack skill:${m[1]}`);
  }
  for (const s of skillTags) if (!fs.existsSync(path.join('skills', s, 'SKILL.md'))) problems.push(`${name}: skill:${s} is not a skill`);
  if (!/^\s*scaffold_script:/m.test(fs.readFileSync(path.join(dir, 'case.yaml'), 'utf8'))) problems.push(`${name}: case.yaml has no scaffold_script`);
}
console.log(problems.join('\n'));
JS
lint=$(cd "$SRC_ROOT" && node "$TMP/lint.cjs")
expect_eq "every case: tier tag, skill tags matching its graders, a deterministic grader" "$lint" ""

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
