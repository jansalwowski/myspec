#!/usr/bin/env bash
# Deterministic tests for scripts/evals/release-check.sh: baseline reuse, the
# previous-tag rerun in a temporary worktree, cleanup, the gate and exit codes.
#
# No model calls: `claude` is a stub (MYSPEC_EVAL_CLAUDE). `plugin eval` writes
# an aggregate-result.json with one case per <plugin-dir>/evals/*/prompt.md,
# every run scoring the number in <plugin-dir>/STUB_SCORE, and logs the plugin dir
# it was pointed at. `-p` answers the model-id probe with stub-<model>-$STUB_MODEL_REV_<model> (default a).
#
# Usage: scripts/tests/eval-release-check.test.sh

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
jf() { node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = eval(process.argv[2]); console.log(typeof v === "object" ? JSON.stringify(v) : v)' "$1" "$2"; }

# ------------------------------------------------------------ stub claude

STUB="$TMP/stub-claude"
STUB_LOG="$TMP/stub.log"
cat > "$STUB" <<'JS'
#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const a = process.argv.slice(2);
const env = process.env;
const log = (s) => fs.appendFileSync(env.STUB_LOG, s + '\n');
const opt = (name) => (a.indexOf(name) >= 0 ? a[a.indexOf(name) + 1] : undefined);
if (a[0] === 'auth') { console.log('{"loggedIn": true}'); process.exit(0); }
if (a[0] === '-p') {
  log(`PROBE ${opt('--model')}`);
  console.log(JSON.stringify({ result: 'OK', modelUsage: { [`stub-${opt('--model')}-${env["STUB_MODEL_REV_" + opt("--model")] || "a"}`]: { costUSD: 0.01 } } }));
  process.exit(0);
}
if (a[0] === 'plugin' && a[1] === 'eval') {
  const dir = a[2];
  const isHead = dir === env.STUB_HEAD_ROOT;
  log(`EVAL ${isHead ? 'HEAD' : 'PREV'} ${dir} ${opt('--model')}`);
  if (!isHead && env.STUB_SLEEP_PREV) { fs.writeFileSync(env.STUB_LOG + '.prev-started', dir); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Number(env.STUB_SLEEP_PREV) * 1000); }
  if ((isHead && env.STUB_FAIL_HEAD) || (!isHead && env.STUB_FAIL_PREV)) { console.error('boom'); process.exit(2); }
  const q = Number(fs.readFileSync(path.join(dir, 'STUB_SCORE'), 'utf8'));
  const runs = Number(opt('--runs'));
  const glob = opt('--case');
  const cases = fs.readdirSync(path.join(dir, 'evals')).filter((c) => fs.existsSync(path.join(dir, 'evals', c, 'prompt.md')))
    .filter((c) => !glob || new RegExp('^' + glob.replace(/\*/g, '.*') + '$').test(c)).sort();
  const out = opt('--output-dir');
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'aggregate-result.json'), JSON.stringify({
    schemaVersion: 1, claudeVersion: env.STUB_CC_VERSION || '2.1.284', durationSeconds: 20, partial: false,
    suite: { modelOverride: opt('--model'), judgeModel: 'sonnet' },
    cases: cases.map((name) => ({ name, graders: [], aggregates: { score: q },
      arms: { with: Array.from({ length: runs }, () => ({ score: q, costUsd: 0.1, judgeCostUsd: 0, durationSeconds: 5, error: null,
        graders: [{ name: 'g', passed: q >= 1, scored: true }] })) } })),
  }));
  process.exit(0);
}
process.exit(0);
JS
chmod +x "$STUB"
export STUB_LOG MYSPEC_EVAL_CLAUDE="$STUB"
unset MYSPEC_EVALS_STRICT MYSPEC_SKIP_EVALS MYSPEC_EVALS_DRY_RUN MYSPEC_EVAL_THRESHOLD MYSPEC_EVAL_RESOLVE_MODELS
mkdir -p "$TMP/tmp"
export TMPDIR="$TMP/tmp"

# ------------------------------------------------------- synthetic repo
# v1.0.0 (score 1) · v1.1.0 (score 1, cases a+b) · HEAD (score 0.5, adds case c)

REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t
git config commit.gpgsign false
mkdir -p scripts/evals quality evals/case-a evals/case-b
cp "$SRC_ROOT"/scripts/evals/{run.sh,summary.mjs,compare.mjs,baseline.mjs,results.mjs,release-check.sh} scripts/evals/
cp "$SRC_ROOT/quality/release-check.json" quality/
echo "prompt" > evals/case-a/prompt.md
echo "prompt" > evals/case-b/prompt.md
echo 1 > STUB_SCORE
git add -A && git commit -qm v1.0.0 && git tag v1.0.0
echo "# v1.1" >> evals/case-a/prompt.md
git commit -qam v1.1.0 && git tag v1.1.0
mkdir -p evals/case-c && echo "prompt" > evals/case-c/prompt.md
echo 0.5 > STUB_SCORE
git add -A && git commit -qm head
export STUB_HEAD_ROOT="$REPO"
RC_SH="$REPO/scripts/evals/release-check.sh"

rc_run() {  # rc_run <name> [args...]: runs release-check, output in $OUTPUT, exit in $RC
  local name="$1"; shift
  : > "$STUB_LOG"
  OUTPUT=$("$RC_SH" --out "$TMP/out-$name" "$@" 2>&1)
  RC=$?
  if [ -n "${SHOW_OUTPUT:-}" ]; then printf '%s\n' "$OUTPUT" >&2; fi
}
worktrees() { git -C "$REPO" worktree list | wc -l | tr -d ' '; }
leftovers() { find "$TMPDIR" -maxdepth 1 -name 'myspec-release-check.*' | wc -l | tr -d ' '; }

echo "# no stored baseline: re-run the previous tag in a worktree"
rc_run first --version 1.2.0 --models sonnet --runs 2
expect_eq "exit 0: regressed but the gate is off" "$RC" 0
expect_has "reason for the rerun is printed" "$OUTPUT" "baseline RERUN sonnet no stored baseline (v1.1.0.json)"
expect_eq "HEAD ran once, the previous tag once" "$(grep -c '^EVAL HEAD' "$STUB_LOG") $(grep -c '^EVAL PREV' "$STUB_LOG")" "1 1"
PREV_DIR=$(sed -n 's/^EVAL PREV \([^ ]*\) .*/\1/p' "$STUB_LOG")
expect_has "previous tag ran from a temporary worktree" "$PREV_DIR" "myspec-release-check."
expect_eq "the worktree is gone afterwards" "$([ -e "$PREV_DIR" ] && echo present || echo gone) $(worktrees) $(leftovers)" "gone 1 0"
expect_eq "HEAD's evals/ were copied in: the previous run saw case-c" \
  "$(jf "$REPO/quality/baselines/v1.1.0.json" 'Object.keys(d.models.sonnet.cases)')" '["case-a","case-b","case-c"]'
expect_eq "rerun baseline recorded for the previous tag" \
  "$(jf "$REPO/quality/baselines/v1.1.0.json" '[d.source, d.tag, d.models.sonnet.model_id, d.models.sonnet.cases["case-a"].scores]')" \
  '["rerun","v1.1.0","stub-sonnet-a",[1,1]]'
expect_eq "HEAD baseline recorded" \
  "$(jf "$REPO/quality/baselines/v1.2.0.json" '[d.version, d.source, d.claude_code, d.runs, d.models.sonnet.cases["case-a"].scores]')" \
  '["1.2.0","release","2.1.284",2,[0.5,0.5]]'
expect_has "report shows the regression" "$OUTPUT" "Verdict: regressed"
expect_has "report-only message" "$OUTPUT" "REGRESSED; report-only"
expect_has "spend line covers both runs" "$OUTPUT" "estimated eval spend of this check: \$1.20 (head prev)"
expect_eq "one trend line with the verdict and gate" "$(wc -l < "$REPO/quality/trend.jsonl" | tr -d ' ') $(tail -1 "$REPO/quality/trend.jsonl" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); console.log(d.version, d.verdict, d.gate, d.vs)')" \
  "1 1.2.0 regressed false v1.1.0 (re-run)"

echo "# stored baseline matches: reuse it, run HEAD only"
rc_run reuse --version 1.2.0 --models sonnet --runs 2
expect_eq "exit 0" "$RC" 0
expect_has "reuse decision is printed" "$OUTPUT" "baseline REUSE sonnet Claude Code 2.1.284 ~ 2.1.284; model stub-sonnet-a"
expect_eq "only HEAD ran" "$(grep -c '^EVAL HEAD' "$STUB_LOG") $(grep -c '^EVAL PREV' "$STUB_LOG")" "1 0"
expect_eq "no worktree was created" "$(worktrees) $(leftovers)" "1 0"
expect_eq "the stored previous baseline is untouched" "$(git -C "$REPO" status --porcelain quality/baselines/v1.1.0.json | cut -c1-2)" "??"
expect_eq "re-recording the same version keeps one trend line" "$(wc -l < "$REPO/quality/trend.jsonl" | tr -d ' ')" 1
expect_has "labelled as the stored baseline" "$OUTPUT" "v1.1.0 (stored baseline)"

echo "# --head-results: reuse an earlier HEAD run, spend nothing"
rc_run headres --version 1.2.0 --models sonnet --runs 2 --head-results "$TMP/out-reuse/head"
expect_eq "no eval ran at all" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "0 0"

echo "# Claude Code minor version changed: re-run the previous tag"
STUB_CC_VERSION=2.2.0 rc_run ccminor --version 1.2.0 --models sonnet --runs 2
expect_eq "exit 0" "$RC" 0
expect_has "reason names the version change" "$OUTPUT" "RERUN sonnet Claude Code 2.1.284 -> 2.2.0 (major.minor changed)"
expect_eq "HEAD and the previous tag ran" "$(grep -c '^EVAL HEAD' "$STUB_LOG") $(grep -c '^EVAL PREV' "$STUB_LOG")" "1 1"
expect_eq "worktree cleaned up" "$(worktrees) $(leftovers)" "1 0"
expect_eq "refreshed previous baseline carries the new version" "$(jf "$REPO/quality/baselines/v1.1.0.json" d.claude_code)" 2.2.0

echo "# resolved model id changed: re-run only that model"
STUB_CC_VERSION=2.2.0 rc_run twomodels --version 1.2.0 --models sonnet,haiku --runs 1
STUB_CC_VERSION=2.2.0 rc_run reuse2 --version 1.2.0 --models sonnet,haiku --runs 1
expect_eq "both models stored: nothing re-run" "$(grep -c '^EVAL PREV' "$STUB_LOG")" 0
STUB_CC_VERSION=2.2.0 STUB_MODEL_REV_sonnet=b rc_run newid --version 1.2.0 --models sonnet,haiku --runs 1
expect_has "reason names the model id change" "$OUTPUT" "RERUN sonnet resolved model stub-sonnet-a -> stub-sonnet-b"
expect_eq "only the changed model is re-run" "$(grep '^EVAL PREV' "$STUB_LOG" | awk '{print $4}' | tr "\n" " ")" "sonnet "
expect_eq "worktree cleaned up" "$(worktrees) $(leftovers)" "1 0"

echo "# gate on"
sed -i.bak 's/"gate": false/"gate": true/' "$REPO/quality/release-check.json"
STUB_CC_VERSION=2.2.0 STUB_MODEL_REV_sonnet=b rc_run gate --version 1.2.0 --models sonnet,haiku --runs 1
expect_eq "regressed with the gate on: exit 1" "$RC" 1
expect_has "blocking message" "$OUTPUT" "REGRESSED and the gate is on"
echo 1 > "$REPO/STUB_SCORE"
STUB_CC_VERSION=2.2.0 STUB_MODEL_REV_sonnet=b rc_run gate-ok --version 1.2.0 --models sonnet,haiku --runs 1
expect_eq "not regressed with the gate on: exit 0" "$RC" 0
expect_has "verdict printed" "$OUTPUT" "verdict no-change"
echo 0.5 > "$REPO/STUB_SCORE"
mv "$REPO/quality/release-check.json.bak" "$REPO/quality/release-check.json"

echo "# failures: exit 2, worktree removed"
rm -f "$REPO/quality/baselines/v1.1.0.json" "$REPO/quality/baselines/v1.2.0.json"
STUB_FAIL_PREV=1 rc_run failprev --version 1.2.0 --models sonnet --runs 1
expect_eq "previous-tag eval failure: exit 2" "$RC" 2
expect_has "failure is named" "$OUTPUT" "v1.1.0 eval run failed"
expect_eq "worktree removed on the failure path" "$(worktrees) $(leftovers)" "1 0"
expect_eq "nothing recorded" "$(ls "$REPO/quality/baselines" | tr '\n' ' ')" ""

STUB_FAIL_HEAD=1 rc_run failhead --version 1.2.0 --models sonnet --runs 1
expect_eq "HEAD eval failure: exit 2, previous tag never runs" "$RC $(grep -c '^EVAL PREV' "$STUB_LOG")" "2 0"

: > "$STUB_LOG"
STUB_SLEEP_PREV=2 "$RC_SH" --out "$TMP/out-term" --version 1.2.0 --models sonnet --runs 1 > "$TMP/term.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do [ -f "$STUB_LOG.prev-started" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
kill -TERM "$pid" 2>/dev/null
wait "$pid"
RC=$?
expect_eq "interrupted mid-run: exit 2, worktree removed" "$RC $(worktrees) $(leftovers)" "2 1 0"
rm -f "$STUB_LOG.prev-started"

echo "# partial runs and the skip path"
rm -rf "$REPO/quality/baselines" "$REPO/quality/trend.jsonl"
rc_run partial --version 1.2.0 --models sonnet --runs 1 --case 'case-[ab]'
expect_eq "--case run: exit 0, quality/ untouched" "$RC $([ -e "$REPO/quality/baselines" ] || [ -e "$REPO/quality/trend.jsonl" ] && echo touched || echo clean)" "0 clean"
expect_has "--case run says it did not record" "$OUTPUT" "not recorded (partial run)"
expect_eq "--case run keeps its trend line in --out" "$(wc -l < "$TMP/out-partial/trend.jsonl" | tr -d ' ')" 1
expect_eq "--case restricts the compared cases" "$(jf "$TMP/out-partial/compare.json" 'd.models.sonnet.cases.map(c => c.name)')" '["case-a","case-b"]'

rc_run skip --version 1.2.0 --skip "usage limit hit"
expect_eq "skip: exit 0, no eval" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "0 0"
expect_eq "skip line recorded" "$(tail -1 "$REPO/quality/trend.jsonl" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); console.log(d.version + "|" + d.skipped)')" "1.2.0|usage limit hit"

echo "# bad arguments"
rc_run noversion --models sonnet
expect_eq "missing --version: exit 2" "$RC" 2
rc_run badtag --version 1.2.0 --prev-tag v9.9.9
expect_eq "unknown --prev-tag: exit 2" "$RC" 2
rc_run noskipreason --version 1.2.0 --skip ""
expect_eq "--skip without a reason: exit 2" "$RC" 2

echo "# probe opt-out"
MYSPEC_EVAL_RESOLVE_MODELS=0 rc_run noprobe --version 1.2.0 --models sonnet --runs 1 --no-record
expect_eq "MYSPEC_EVAL_RESOLVE_MODELS=0 skips the model-id probe" "$RC $(grep -c '^PROBE' "$STUB_LOG")" "0 0"

echo
echo "eval-release-check: $pass passed, $fail failed"
[ "$fail" = 0 ]
