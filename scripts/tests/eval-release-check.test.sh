#!/usr/bin/env bash
# Deterministic tests for scripts/evals/release-check.sh: baseline reuse, the
# previous-tag rerun in a temporary worktree (whole suite or changed cases),
# staging and --record, cleanup, interrupts, the gate and exit codes.
#
# No model calls: `claude` is a stub (MYSPEC_EVAL_CLAUDE). `plugin eval` writes
# an aggregate-result.json with one case per <plugin-dir>/evals/*/prompt.md
# (filtered by --case), every run scoring the number in
# <plugin-dir>/STUB_SCORE_<model> if present, else <plugin-dir>/STUB_SCORE,
# and logs "EVAL HEAD|PREV <dir> <model> <case glob>". HEAD is the run whose
# plugin dir holds STUB_HEAD, an untracked file only the fixture's working
# tree has (run.sh evaluates a snapshot of it, #311), and "IGNORED" is logged
# when the plugin dir holds the fixture's gitignored local/ directory. `-p` answers the
# model-id probe with stub-<model>-$STUB_MODEL_REV_<model> (default a), or
# fails when STUB_PROBE_FAIL is set.
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
jf() { node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = eval(process.argv[2]); console.log(typeof v === "object" ? JSON.stringify(v) : v)' "$1" "$2"; }
sum() { if [ -f "$1" ]; then cksum < "$1" | tr -d ' \t'; else echo missing; fi; }

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
const sleep = (s) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Number(s) * 1000);
if (a[0] === 'auth') { console.log('{"loggedIn": true}'); process.exit(0); }
if (a[0] === '-p') {
  log(`PROBE ${opt('--model')}`);
  if (env.STUB_PROBE_FAIL) { console.error('probe: offline'); process.exit(1); }
  console.log(JSON.stringify({ result: 'OK', modelUsage: { [`stub-${opt('--model')}-${env['STUB_MODEL_REV_' + opt('--model')] || 'a'}`]: { costUSD: 0.01 } } }));
  process.exit(0);
}
if (a[0] === 'plugin' && a[1] === 'eval') {
  const dir = a[2];
  const isHead = fs.existsSync(path.join(dir, 'STUB_HEAD'));
  if (fs.existsSync(path.join(dir, 'local'))) log('IGNORED');
  const glob = opt('--case');
  log(`EVAL ${isHead ? 'HEAD' : 'PREV'} ${dir} ${opt('--model')} ${glob || '-'}`);
  const nap = isHead ? env.STUB_SLEEP_HEAD : env.STUB_SLEEP_PREV;
  if (nap) { fs.writeFileSync(env.STUB_LOG + '.started', `${process.pid} ${dir}`); sleep(nap); }
  if ((isHead && env.STUB_FAIL_HEAD) || (!isHead && env.STUB_FAIL_PREV)) { console.error('boom'); process.exit(2); }
  const perModel = path.join(dir, `STUB_SCORE_${opt('--model')}`);
  const q = Number(fs.readFileSync(fs.existsSync(perModel) ? perModel : path.join(dir, 'STUB_SCORE'), 'utf8'));
  // Run count: --runs, else the case's `runs:` line, else 3 (as claude does).
  // --tag (repeatable) keeps the cases whose tags line names any of them.
  const prompt = (c) => fs.readFileSync(path.join(dir, 'evals', c, 'prompt.md'), 'utf8');
  const runsOf = (c) => Number(opt('--runs') ?? (prompt(c).match(/^runs: *(\d+)/m) || [, 3])[1]);
  const tags = a.flatMap((x, i) => (a[i - 1] === '--tag' ? [x] : []));
  if (tags.length) log(`TAGS ${opt('--model')} ${tags.join(',')}`);
  const cases = fs.readdirSync(path.join(dir, 'evals')).filter((c) => fs.existsSync(path.join(dir, 'evals', c, 'prompt.md')))
    .filter((c) => !glob || new RegExp('^' + glob.replace(/\*/g, '.*').replace(/\[!/g, '[^') + '$').test(c))
    .filter((c) => !tags.length || tags.some((t) => new RegExp(`^tags:.*\\b${t}\\b`, 'm').test(prompt(c)))).sort();
  const out = opt('--output-dir');
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'aggregate-result.json'), JSON.stringify({
    schemaVersion: 1, claudeVersion: env.STUB_CC_VERSION || '2.1.284', durationSeconds: 20, partial: false,
    suite: { modelOverride: opt('--model'), judgeModel: 'sonnet' },
    cases: cases.map((name) => ({ name, graders: [], aggregates: { score: q },
      arms: { with: Array.from({ length: runsOf(name) }, () => ({ score: q, costUsd: 0.1, judgeCostUsd: 0, durationSeconds: 5, error: null,
        graders: [{ name: 'g', passed: q >= 1, scored: true }] })) } })),
  }));
  process.exit(0);
}
process.exit(0);
JS
chmod +x "$STUB"
export STUB_LOG MYSPEC_EVAL_CLAUDE="$STUB" MYSPEC_EVAL_PROBE_URL="file:///dev/null"
unset MYSPEC_EVALS_STRICT MYSPEC_SKIP_EVALS MYSPEC_EVALS_DRY_RUN MYSPEC_EVAL_THRESHOLD MYSPEC_EVAL_RESOLVE_MODELS
mkdir -p "$TMP/tmp"
export TMPDIR="$TMP/tmp"

# ------------------------------------------------------- synthetic repo
# v1.0.0 and v1.1.0: cases a-e, score 1 · HEAD: adds case f, score 0.5

REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t
git config commit.gpgsign false
mkdir -p scripts/evals quality evals/_fixtures
cp "$SRC_ROOT"/scripts/evals/{run.sh,summary.mjs,compare.mjs,baseline.mjs,results.mjs,release-check.sh,workspaces.mjs} scripts/evals/
# set_config <gate> [gateModels JSON]: the repo's release-check.json with gate
# set and gateModels replaced, or dropped when no second argument is given.
# modelTags is dropped too, or set from $SET_MODEL_TAGS (JSON).
set_config() {
  node -e '
    const fs = require("fs");
    const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    c.gate = process.argv[2] === "true";
    delete c.gateModels;
    delete c.modelTags;
    if (process.env.SET_MODEL_TAGS) c.modelTags = JSON.parse(process.env.SET_MODEL_TAGS);
    if (process.argv[3]) c.gateModels = JSON.parse(process.argv[3]);
    fs.writeFileSync(process.argv[4], JSON.stringify(c, null, 2) + "\n");
  ' "$SRC_ROOT/quality/release-check.json" "$1" "${2:-}" "$REPO/quality/release-check.json"
}
# The fixture starts report-only whatever the repo sets (gate on since #267); "gate on" below flips it.
set_config false
echo "lib" > evals/_fixtures/lib.sh
for c in a b c d e; do mkdir -p "evals/case-$c" && echo "prompt $c" > "evals/case-$c/prompt.md"; done
echo 1 > STUB_SCORE
git add -A && git commit -qm v1.0.0 && git tag v1.0.0
echo "# v1.1" >> evals/case-a/prompt.md
git commit -qam v1.1.0 && git tag v1.1.0
mkdir -p evals/case-f && echo "prompt f" > evals/case-f/prompt.md
echo 0.5 > STUB_SCORE
echo local/ > .gitignore
git add -A && git commit -qm head
touch STUB_HEAD
mkdir -p local && touch local/clutter
RC_SH="$REPO/scripts/evals/release-check.sh"
B11="$REPO/quality/baselines/v1.1.0.json"
B12="$REPO/quality/baselines/v1.2.0.json"
TREND="$REPO/quality/trend.jsonl"

rc_run() {  # rc_run <name> [args...]: runs release-check, output in $OUTPUT, exit in $RC
  local name="$1"; shift
  : > "$STUB_LOG"
  OUTPUT=$("$RC_SH" --out "$TMP/out-$name" "$@" 2>&1)
  RC=$?
  if [ -n "${SHOW_OUTPUT:-}" ]; then printf '%s\n' "$OUTPUT" >&2; fi
}
record() { "$RC_SH" --record "$TMP/out-$1" > "$TMP/record-$1.log" 2>&1; }
worktrees() { git -C "$REPO" worktree list | wc -l | tr -d ' '; }
leftovers() { find "$TMPDIR" -maxdepth 1 -name 'myspec-release-check.*' | wc -l | tr -d ' '; }
quality_state() { echo "$(sum "$B11") $(sum "$B12") $(sum "$TREND")"; }
prevs() { grep '^EVAL PREV' "$STUB_LOG" | awk '{print $4 ":" $5}' | tr '\n' ' '; }

echo "# no stored baseline: re-run the previous tag in a worktree"
rc_run first --version 1.2.0 --models sonnet --runs 2
expect_eq "exit 0: regressed but the gate is off" "$RC" 0
expect_has "reason for the rerun is printed" "$OUTPUT" "baseline RERUN sonnet no stored baseline (v1.1.0.json)"
expect_eq "HEAD ran once, the previous tag's whole suite once" "$(grep -c '^EVAL HEAD' "$STUB_LOG") $(prevs)" "1 sonnet:- "
# #311: HEAD runs on a snapshot of the working tree, never the tree itself,
# without its gitignored files, and the snapshot is gone afterwards.
HEAD_DIR=$(grep '^EVAL HEAD' "$STUB_LOG" | head -1 | cut -d' ' -f3)
expect_eq "HEAD evaluates a snapshot, not the working tree" "$([ "$HEAD_DIR" != "$REPO" ] && [ -n "$HEAD_DIR" ] && echo snapshot)" "snapshot"
expect_eq "the snapshot leaves gitignored files out" "$(grep -c '^IGNORED' "$STUB_LOG")" "0"
expect_eq "the snapshot is removed after the run" "$([ -e "$HEAD_DIR" ] && echo left || echo gone)" "gone"
PREV_DIR=$(sed -n 's/^EVAL PREV \([^ ]*\) .*/\1/p' "$STUB_LOG")
expect_has "previous tag ran from a temporary worktree" "$PREV_DIR" "myspec-release-check."
expect_eq "the worktree is gone afterwards" "$([ -e "$PREV_DIR" ] && echo present || echo gone) $(worktrees) $(leftovers)" "gone 1 0"
expect_has "report shows the regression" "$OUTPUT" "Verdict: regressed"
expect_has "report-only message" "$OUTPUT" "REGRESSED; report-only"
expect_has "spend line covers both runs" "$OUTPUT" "estimated eval spend of this check: \$2.40 (head prev)"
expect_eq "nothing written to quality/ before the go decision" "$(quality_state)" "missing missing missing"
S="$TMP/out-first/staged"
expect_eq "HEAD's evals/ were copied in: the previous run saw case-f" \
  "$(jf "$S/baselines/v1.1.0.json" 'Object.keys(d.models.sonnet.cases)')" '["case-a","case-b","case-c","case-d","case-e","case-f"]'
expect_eq "rerun baseline staged for the previous tag" \
  "$(jf "$S/baselines/v1.1.0.json" '[d.source, d.tag, d.models.sonnet.model_id, d.models.sonnet.cases["case-a"].scores, Object.keys(d.evals.cases).length]')" \
  '["rerun","v1.1.0","stub-sonnet-a",[1,1],6]'

record first
expect_eq "--record: exit 0" "$?" 0
expect_eq "--record copies both baselines and the trend line" "$(quality_state | grep -c missing)" 0
expect_eq "HEAD baseline recorded" \
  "$(jf "$B12" '[d.version, d.source, d.claude_code, d.runs, d.models.sonnet.cases["case-a"].scores]')" \
  '["1.2.0","release","2.1.284",2,[0.5,0.5]]'
expect_eq "one trend line with the verdict and gate" "$(wc -l < "$TREND" | tr -d ' ') $(tail -1 "$TREND" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); console.log(d.version, d.verdict, d.gate, d.vs)')" \
  "1 1.2.0 regressed false v1.1.0 (re-run)"
expect_has "--record names the commit to make" "$(cat "$TMP/record-first.log")" "chore(quality): record v1.2.0 eval baseline"

echo "# stored baseline matches: reuse it, run HEAD only"
before=$(sum "$B11")
rc_run reuse --version 1.2.0 --models sonnet --runs 2
expect_eq "exit 0" "$RC" 0
expect_has "reuse decision is printed" "$OUTPUT" "baseline REUSE sonnet Claude Code 2.1.284; model stub-sonnet-a"
expect_eq "only HEAD ran" "$(grep -c '^EVAL HEAD' "$STUB_LOG") $(grep -c '^EVAL PREV' "$STUB_LOG")" "1 0"
expect_eq "no worktree was created" "$(worktrees) $(leftovers)" "1 0"
expect_eq "nothing staged for the previous tag" "$([ -e "$TMP/out-reuse/staged/baselines/v1.1.0.json" ] && echo staged || echo none)" none
record reuse
expect_eq "the stored previous baseline is byte-identical after a reuse and --record" "$(sum "$B11")" "$before"
expect_eq "re-recording the same version keeps one trend line" "$(wc -l < "$TREND" | tr -d ' ')" 1
expect_has "labelled as the stored baseline" "$OUTPUT" "v1.1.0 (stored baseline)"

echo "# --head-results: reuse an earlier HEAD run, spend nothing"
rc_run headres --version 1.2.0 --models sonnet --runs 2 --head-results "$TMP/out-reuse/head"
expect_eq "no eval ran at all" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "0 0"

echo "# a case changed since the baseline: re-run that case only"
echo "prompt b, reworded" > "$REPO/evals/case-b/prompt.md"
rc_run casechg --version 1.2.0 --models sonnet --runs 2
expect_has "reason names the case" "$OUTPUT" "RERUN-CASE case-b evals/case-b/ changed since the baseline"
expect_eq "only case-b of the previous tag re-ran" "$(prevs)" "sonnet:case-b "
expect_eq "staged previous baseline merges the rerun case into the stored ones" \
  "$(jf "$TMP/out-casechg/staged/baselines/v1.1.0.json" '[Object.keys(d.models.sonnet.cases).length, d.evals.cases["case-b"] !== undefined]')" '[6,true]'
record casechg
rc_run casechg2 --version 1.2.0 --models sonnet --runs 2
expect_eq "after recording, the changed case is reused" "$(grep -c '^EVAL PREV' "$STUB_LOG")" 0
echo "lib v2" > "$REPO/evals/_fixtures/lib.sh"
rc_run fixchg --version 1.2.0 --models sonnet --runs 2
expect_has "a _fixtures/ change compares the previous tag's fixture workspaces first" "$OUTPUT" "baseline WORKSPACES evals/_fixtures/ changed since the baseline"
expect_eq "no workspace changed: nothing of the previous tag re-ran, its worktree is gone" "$(prevs)|$(worktrees) $(leftovers)" "|1 0"
expect_has "and the stored baseline is reused" "$OUTPUT" "v1.1.0 (stored baseline)"
record fixchg

echo "# Claude Code version changed: re-run the previous tag"
STUB_CC_VERSION=2.1.290 rc_run ccminor --version 1.2.0 --models sonnet --runs 2
expect_eq "a patch release reuses the baseline by default" "$(grep -c '^EVAL PREV' "$STUB_LOG")" 0
STUB_CC_VERSION=2.2.0 rc_run ccminorbump --version 1.2.0 --models sonnet --runs 2
expect_has "a minor version change re-runs by default" "$OUTPUT" "RERUN sonnet Claude Code 2.1.284 -> 2.2.0"
STUB_CC_VERSION=2.1.290 rc_run ccpatch --version 1.2.0 --models sonnet --runs 2 --cc-match exact
expect_has "--cc-match exact re-runs on any version change" "$OUTPUT" "RERUN sonnet Claude Code 2.1.284 -> 2.1.290"
expect_eq "HEAD and the previous tag ran" "$(grep -c '^EVAL HEAD' "$STUB_LOG") $(grep -c '^EVAL PREV' "$STUB_LOG")" "1 1"
expect_eq "worktree cleaned up" "$(worktrees) $(leftovers)" "1 0"

echo "# resolved model id changed or unresolved"
rc_run twomodels --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "haiku missing from the baseline: only haiku re-runs" "$(prevs)" "haiku:- "
record twomodels
STUB_MODEL_REV_sonnet=b rc_run newid --version 1.2.0 --models sonnet,haiku --runs 2
expect_has "reason names the model id change" "$OUTPUT" "RERUN sonnet resolved model stub-sonnet-a -> stub-sonnet-b"
expect_eq "only the changed model is re-run" "$(prevs)" "sonnet:- "
STUB_PROBE_FAIL=1 rc_run noprobe --version 1.2.0 --models sonnet --runs 2
expect_has "a failed probe means rerun, with the reason" "$OUTPUT" "RERUN sonnet model id not resolved now (probe failed"
expect_eq "the staged HEAD baseline records why, never a null id" \
  "$(jf "$TMP/out-noprobe/staged/baselines/v1.2.0.json" '["model_id" in d.models.sonnet, d.models.sonnet.model_id_unresolved.startsWith("probe failed")]')" '[false,true]'
MYSPEC_EVAL_RESOLVE_MODELS=0 rc_run probeoff --version 1.2.0 --models sonnet --runs 2
expect_eq "MYSPEC_EVAL_RESOLVE_MODELS=0: no probe, and the previous tag re-runs" \
  "$(grep -c '^PROBE' "$STUB_LOG") $(grep -c '^EVAL PREV' "$STUB_LOG")" "0 1"

echo "# gate on"
record twomodels
set_config true
before=$(quality_state)
rc_run gate --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "regressed with the gate on: exit 1" "$RC" 1
expect_has "blocking message" "$OUTPUT" "REGRESSED on sonnet,haiku and the gate is on"
expect_eq "quality/ untouched on a blocked release" "$(quality_state)" "$before"

echo "# gateModels: only the listed models block"
echo 1 > "$REPO/STUB_SCORE_sonnet"
rc_run gate-nokey-haiku --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "no gateModels key, Haiku-only regression: every model gates, exit 1" \
  "$RC $(jf "$TMP/out-gate-nokey-haiku/compare.json" '[d.models.sonnet.verdict, d.models.haiku.verdict]')" '1 ["no-change","regressed"]'
expect_has "no key: blocks on haiku" "$OUTPUT" "REGRESSED on haiku and the gate is on"
set_config true '["sonnet"]'
rc_run gate-sonnet-haiku --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "gateModels [sonnet], Haiku-only regression: exit 0" "$RC" 0
expect_has "the header names the gating models" "$OUTPUT" "gate=on (sonnet)"
expect_has "the Haiku regression is a report-only warning" "$OUTPUT" "WARNING: REGRESSED on haiku; report-only (not in gateModels"
expect_has "and the release is not blocked" "$OUTPUT" "no gating model regressed; not blocking"
expect_eq "both models still ran and are staged" \
  "$(jf "$TMP/out-gate-sonnet-haiku/staged/baselines/v1.2.0.json" 'Object.keys(d.models).sort()')" '["haiku","sonnet"]'
rm "$REPO/STUB_SCORE_sonnet"
echo 1 > "$REPO/STUB_SCORE_haiku"
rc_run gate-sonnet-sonnet --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "gateModels [sonnet], Sonnet regression: exit 1" "$RC" 1
expect_has "blocks on sonnet" "$OUTPUT" "REGRESSED on sonnet and the gate is on"
rm "$REPO/STUB_SCORE_haiku"
rc_run gate-sonnet-both --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "gateModels [sonnet], both regressed: exit 1 and Haiku still warned" "$RC" 1
expect_has "Haiku warned alongside the block" "$OUTPUT" "WARNING: REGRESSED on haiku"
set_config true '"sonnet"'
rc_run gate-badkey --version 1.2.0 --models sonnet --runs 2
expect_eq "gateModels not an array: exit 2 before any eval" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "2 0"
echo "# gateModels that would gate nothing: exit 2 before any eval"
set_config true '["sonnet"]'
rc_run gate-notrun --version 1.2.0 --models haiku --runs 2
expect_eq "gateModels [sonnet] with --models haiku: exit 2, no eval" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "2 0"
expect_has "names the model that would not run" "$OUTPUT" "gateModels lists sonnet, which --models (haiku) does not run"
set_config true '["Sonnet"]'
rc_run gate-case --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "gateModels [Sonnet] (case typo): exit 2, no eval" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "2 0"
expect_has "names the typo" "$OUTPUT" "gateModels lists Sonnet, which --models (sonnet,haiku) does not run"
set_config true '[]'
rc_run gate-empty --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "gateModels []: exit 2, no eval" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "2 0"
expect_has "says the list is empty" "$OUTPUT" "gateModels is empty"
set_config false
rc_run haiku-only --version 1.2.0 --models haiku --runs 2
set_config true '["sonnet"]'
rc_run gate-notcompared --version 1.2.0 --models sonnet,haiku --runs 2 --head-results "$TMP/out-haiku-only/head"
expect_eq "gateModels [sonnet] but the results hold no sonnet: exit 2 after the comparison" \
  "$RC $(jf "$TMP/out-gate-notcompared/compare.json" 'Object.keys(d.models)')" '2 ["haiku"]'
expect_has "names the model missing from the comparison" "$OUTPUT" "gateModels lists sonnet, which the comparison (haiku) does not hold"
set_config true
rc_run gate-partial --version 1.2.0 --models sonnet,haiku --runs 2 --case 'case-[a-e]'
expect_eq "a --case run never exits 1, even regressed with the gate on" "$RC" 0
expect_has "and says so" "$OUTPUT" "REGRESSED on a partial run (--case); never a gate"
record gate-partial
expect_eq "--record refuses a partial run: exit 2" "$? $(quality_state)" "2 $before"
rc_run gate-small --version 1.2.0 --models sonnet --runs 2 --case 'case-[ab]'
expect_eq "2 paired cases: insufficient-data, exit 0" "$RC $(jf "$TMP/out-gate-small/compare.json" d.verdict)" "0 insufficient-data"
echo 1 > "$REPO/STUB_SCORE"
rc_run gate-ok --version 1.2.0 --models sonnet,haiku --runs 2
expect_eq "not regressed with the gate on: exit 0" "$RC" 0
expect_has "verdict printed" "$OUTPUT" "verdict no-change"
echo 0.5 > "$REPO/STUB_SCORE"
set_config false

echo "# failures: exit 2, worktree removed"
rm -rf "$REPO/quality/baselines" "$TREND"
STUB_FAIL_PREV=1 rc_run failprev --version 1.2.0 --models sonnet --runs 1
expect_eq "previous-tag eval failure: exit 2" "$RC" 2
expect_has "failure is named" "$OUTPUT" "v1.1.0 eval run failed"
expect_eq "worktree removed on the failure path" "$(worktrees) $(leftovers)" "1 0"
expect_eq "nothing staged or recorded" "$([ -e "$TMP/out-failprev/staged" ] && echo staged || echo none) $(quality_state)" "none missing missing missing"

STUB_FAIL_HEAD=1 rc_run failhead --version 1.2.0 --models sonnet --runs 1
expect_eq "HEAD eval failure: exit 2, previous tag never runs" "$RC $(grep -c '^EVAL PREV' "$STUB_LOG")" "2 0"

# interrupt <name> <env assignment>: TERM release-check while the stub sleeps 30 s.
interrupt() {
  : > "$STUB_LOG"; rm -f "$STUB_LOG.started"
  env "$2" "$RC_SH" --out "$TMP/out-$1" --version 1.2.0 --models sonnet --runs 1 > "$TMP/$1.log" 2>&1 &
  local pid=$! t0 t1 stub_pid
  for _ in $(seq 1 150); do [ -f "$STUB_LOG.started" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
  stub_pid=$(cut -d' ' -f1 "$STUB_LOG.started" 2>/dev/null)
  t0=$(date +%s)
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"
  RC=$?
  t1=$(date +%s)
  ELAPSED=$((t1 - t0))
  STUB_ALIVE=$(kill -0 "${stub_pid:-999999}" 2>/dev/null && echo alive || echo dead)
}
interrupt term-head STUB_SLEEP_HEAD=30
expect_eq "TERM during HEAD's run: exit 2 within 2 s, the eval killed" "$RC $([ "$ELAPSED" -le 2 ] && echo fast || echo "slow:${ELAPSED}s") $STUB_ALIVE" "2 fast dead"
interrupt term-prev STUB_SLEEP_PREV=30
expect_eq "TERM during the previous tag's run: exit 2 within 2 s, eval killed, worktree removed" \
  "$RC $([ "$ELAPSED" -le 2 ] && echo fast || echo "slow:${ELAPSED}s") $STUB_ALIVE $(worktrees) $(leftovers)" "2 fast dead 1 0"

echo "# release suite: per-case runs, modelTags, workspaces, project instructions (#310)"
rm -rf "$REPO/quality/baselines" "$TREND"
cd "$REPO" || exit 1
printf -- '---\ntags: [trigger, regression]\n---\nprompt a\n' > evals/case-a/prompt.md
printf -- '---\ntags: [near-miss, regression]\n---\nprompt b\n' > evals/case-b/prompt.md
printf -- '---\ntags: [planted-flaw, capability]\nruns: 1\n---\nprompt c\n' > evals/case-c/prompt.md
printf -- '---\ntags: [artifact-contract, regression]\n---\nprompt d\n' > evals/case-d/prompt.md
printf -- '---\ntags: [trigger, capability]\nruns: 1\n---\nprompt e\n' > evals/case-e/prompt.md
printf -- '---\ntags: [trigger, regression]\n---\nprompt f\n' > evals/case-f/prompt.md
# Fixtures: case-c and case-d build a workspace through lib.sh; case-e carries
# a generated project-instructions block.
printf 'ws() { echo base > ws.txt; }\n' > evals/_fixtures/lib.sh
for c in c d; do
  printf 'context:\n  scaffold_script: fixture.sh\n' > "evals/case-$c/case.yaml"
  # shellcheck disable=SC2016 # the fixture script expands it, not this one
  printf '. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"\nws %s\n' "$c" > "evals/case-$c/fixture.sh"
done
block() { printf 'name: case-e\n\n# BEGIN project-instructions: generated by evals/_fixtures/project-instructions.sh, do not edit\nexecution:\n  append_system_prompt: |-\n    %s\n# END project-instructions\n' "$1" > evals/case-e/case.yaml; }
block "rules v1"
git add -A && git commit -qm "release suite fixtures"
SET_MODEL_TAGS='{"haiku": ["trigger", "near-miss"]}' set_config true '["sonnet"]'
rc_run suite1 --version 1.2.0 --models sonnet,haiku
H="$TMP/out-suite1/staged/baselines/v1.2.0.json"
expect_eq "no --runs: no --runs flag reaches run.sh or claude" "$(grep -c -- '--runs' "$STUB_LOG")" 0
expect_eq "each case runs its own count: capability cases once, the rest 3 times" \
  "$(jf "$H" 'Object.entries(d.models.sonnet.cases).map(([c, v]) => c.slice(5) + v.scores.length).join(" ")')" "a3 b3 c1 d3 e1 f3"
expect_has "haiku gets the modelTags filter as --tag flags" "$(cat "$STUB_LOG")" "TAGS haiku trigger,near-miss"
expect_eq "sonnet runs unfiltered" "$(grep -c '^TAGS sonnet' "$STUB_LOG")" 0
expect_eq "haiku ran only the trigger and near-miss cases, on both sides" \
  "$(jf "$H" 'Object.keys(d.models.haiku.cases).join(" ")') | $(jf "$TMP/out-suite1/staged/baselines/v1.1.0.json" 'Object.keys(d.models.haiku.cases).join(" ")')" \
  "case-a case-b case-e case-f | case-a case-b case-e case-f"
expect_eq "the previous tag ran the same run counts per case" \
  "$(jf "$TMP/out-suite1/staged/baselines/v1.1.0.json" 'Object.entries(d.models.sonnet.cases).map(([c, v]) => c.slice(5) + v.scores.length).join(" ")')" "a3 b3 c1 d3 e1 f3"
expect_eq "baselines record tiers and every case's workspace hash" \
  "$(jf "$H" '[d.evals.tiers["case-c"], d.evals.tiers["case-d"], /^[0-9a-f]{16}$/.test(d.evals.workspaces["case-c"]), d.evals.workspaces["case-a"]]')" \
  '["capability","regression",true,"none"]'
expect_eq "capability cases are report-only in the comparison" \
  "$(jf "$TMP/out-suite1/compare.json" '[d.models.sonnet.n_paired, d.models.sonnet.report_only.cases.map((c) => c.name).join(" ")]')" '[4,"case-c case-e"]'
record suite1

echo "lib comment" >> evals/_fixtures/lib.sh
block "rules v2, regenerated"
git commit -qam "fixtures: comment only; regenerated project instructions"
rc_run suite2 --version 1.2.0 --models sonnet,haiku
expect_has "_fixtures/ changed: the workspaces are compared" "$OUTPUT" "baseline WORKSPACES"
expect_eq "no workspace changed and only case-e's generated block did: nothing of the previous tag re-ran" "$(prevs)" ""
expect_eq "every reused case kept its stored results" "$(jf "$TMP/out-suite2/compare.json" 'd.old.label')" "v1.1.0 (stored baseline)"
record suite2

# shellcheck disable=SC2016 # lib.sh expands it, not this script
printf 'ws() { echo base > ws.txt; if [ "$1" = c ]; then echo extra > c.txt; fi; }\n' > evals/_fixtures/lib.sh
git commit -qam "fixtures: case-c's workspace grows a file"
rc_run suite3 --version 1.2.0 --models sonnet,haiku
expect_has "the changed workspace is named" "$OUTPUT" "RERUN-CASE case-c its fixture workspace changed since the baseline"
expect_eq "only case-c re-ran, on sonnet only (haiku's modelTags exclude it)" "$(prevs)" "sonnet:case-c "
expect_eq "the staged previous baseline carries the new workspace hashes" \
  "$(jf "$TMP/out-suite3/staged/baselines/v1.1.0.json" 'd.evals.workspaces["case-c"] === JSON.parse(require("fs").readFileSync(process.argv[1].replace(/staged.*/, "prev-workspaces.json"), "utf8"))["case-c"]')" true
set_config false
SET_MODEL_TAGS='{"haiku": "trigger"}' set_config true
rc_run badtags --version 1.2.0 --models sonnet,haiku
expect_eq "modelTags not a map of tag lists: exit 2 before any eval" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "2 0"
set_config false

echo "# skip and bad arguments"
rc_run skip --version 1.2.0 --skip "usage limit hit"
expect_eq "skip: exit 0, no eval" "$RC $(grep -c '^EVAL' "$STUB_LOG")" "0 0"
expect_eq "skip line recorded" "$(tail -1 "$TREND" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); console.log(d.version + "|" + d.skipped)')" "1.2.0|usage limit hit"
rc_run noversion --models sonnet
expect_eq "missing --version: exit 2" "$RC" 2
rc_run badtag --version 1.2.0 --prev-tag v9.9.9
expect_eq "unknown --prev-tag: exit 2" "$RC" 2
rc_run noskipreason --version 1.2.0 --skip ""
expect_eq "--skip without a reason: exit 2" "$RC" 2
"$RC_SH" --record "$TMP/nowhere" > /dev/null 2>&1
expect_eq "--record with nothing staged: exit 2" "$?" 2

echo
echo "eval-release-check: $pass passed, $fail failed"
[ "$fail" = 0 ]
