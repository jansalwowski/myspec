#!/usr/bin/env bash
# Deterministic tests for the release comparison (scripts/evals/compare.mjs)
# and the baseline/trend files (scripts/evals/baseline.mjs). No model calls.
#
# Fixtures: scripts/tests/fixtures/eval-compare/<set>/<model>/aggregate-result.json
#   worked-old/new  10 paired cases, 3 runs each, plus one case only in each set
#                   and a haiku model only in old. Diffs +.3 +.2 +.2 +.1 +.1 +.1
#                   0 0 -.1 +.2: mean +0.11, sign test +7/-1 (2 ties).
#   passk-old/new   scores barely move but three cases start failing a run:
#                   pass^3 0.90 -> 0.70 while the CI straddles 0 (noise).
#   k5-c3, k5-c1    one case, 5 runs, 3 (resp. 1) passing.
#   stable-old      10 cases passing every run; broken1-new / broken2-new make
#                   1 / 2 of them fail every run.
#   drift-old/new   8 of 10 never-passing cases lose 0.1 each (CI + sign test).
#   drop-old/new    2 of 10 cases fall from 0.9 to 0.2 (per-case score drop).
#
# Usage: scripts/tests/eval-compare.test.sh

set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FX="$SRC_ROOT/scripts/tests/fixtures/eval-compare"
CMP="$SRC_ROOT/scripts/evals/compare.mjs"
BASE="$SRC_ROOT/scripts/evals/baseline.mjs"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: [$3]"$'\n'"actual:   [$2]"; fi; }
expect_has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else nok "$1" "missing [$3] in:"$'\n'"$2"; fi; }

# jf <file> <js expression over `d`>: print a value from a JSON file.
jf() { node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = eval(process.argv[2]); console.log(typeof v === "object" ? JSON.stringify(v) : v)' "$1" "$2"; }

cmp_json() {  # cmp_json <name> <old> <new> [args...]: writes $TMP/<name>.json, sets RC
  local name="$1"; shift
  node "$CMP" "$@" --json > "$TMP/$name.json" 2> "$TMP/$name.err"
  RC=$?
}

echo "# worked example (improved)"
cmp_json worked "$FX/worked-old" "$FX/worked-new"
W="$TMP/worked.json"
expect_eq "exit 0 when not regressed" "$RC" 0
expect_eq "verdict improved" "$(jf "$W" d.verdict)" improved
expect_eq "paired cases exclude one-sided cases" "$(jf "$W" d.models.sonnet.n_paired)" 10
expect_eq "mean paired delta" "$(jf "$W" d.models.sonnet.mean_delta)" 0.11
expect_eq "bootstrap 95% CI, seed 42, 10000 resamples" "$(jf "$W" d.models.sonnet.ci)" "[0.04,0.18]"
expect_eq "sign test counts and exact p = 2*(1+8)/256" "$(jf "$W" d.models.sonnet.sign)" '{"pos":7,"neg":1,"ties":2,"p":0.0703}'
expect_eq "per-case diff" "$(jf "$W" 'd.models.sonnet.cases.map(c => c.name + "=" + c.diff).join(" ")')" \
  "case-01=0.3 case-02=0.2 case-03=0.2 case-04=0.1 case-05=0.1 case-06=0.1 case-07=0 case-08=0 case-09=-0.1 case-10=0.2"
expect_eq "per-case old/new means" "$(jf "$W" '[d.models.sonnet.cases[5].old_mean, d.models.sonnet.cases[5].new_mean]')" "[0.9,1]"
expect_eq "k defaults to the run count" "$(jf "$W" d.models.sonnet.k)" 3
expect_eq "pass@3 old/new" "$(jf "$W" '[d.models.sonnet.old.pass_at_k, d.models.sonnet.new.pass_at_k]')" "[0.4,0.5]"
expect_eq "pass^3 old/new" "$(jf "$W" '[d.models.sonnet.old.pass_hat_k, d.models.sonnet.new.pass_hat_k]')" "[0.3,0.3]"
expect_eq "flaky cases, old" "$(jf "$W" d.models.sonnet.old.flaky)" '["case-06"]'
expect_eq "flaky cases, new" "$(jf "$W" d.models.sonnet.new.flaky)" '["case-09","case-10"]'
expect_eq "case only in old is reported" "$(jf "$W" d.models.sonnet.only_old)" '["gone"]'
expect_eq "case only in new is reported" "$(jf "$W" d.models.sonnet.only_new)" '["added"]'
expect_eq "model only in old is reported, not compared" "$(jf "$W" '[d.only_old_models, Object.keys(d.models)]')" '[["haiku"],["sonnet"]]'

node "$CMP" "$FX/worked-old" "$FX/worked-new" > "$TMP/worked.txt"
TXT=$(cat "$TMP/worked.txt")
expect_has "text: summary line" "$TXT" "paired cases 10 · mean delta +0.110  95% CI [+0.040, +0.180] · sign test +7/-1 (2 ties) p=0.0703"
expect_has "text: case row with run pattern" "$TXT" "case-06  0.90  1.00  +0.10  PFP       PPP"
expect_has "text: excluded cases" "$TXT" "only in old (excluded): gone"
expect_has "text: verdict" "$TXT" "Verdict: improved"

node "$CMP" "$FX/worked-old" "$FX/worked-new" --json > "$TMP/worked2.json"
expect_eq "deterministic: a second run is byte-identical" "$(cmp -s "$W" "$TMP/worked2.json" && echo same)" same

# Independent check of the seeded bootstrap: a Python port of mulberry32 and
# the percentile rule must land on the same CI.
if command -v python3 >/dev/null 2>&1; then
  PY_CI=$(python3 - "$FX/worked-old/sonnet/aggregate-result.json" "$FX/worked-new/sonnet/aggregate-result.json" <<'PY'
import json, math, sys
def means(p):
    d = json.load(open(p))
    out = {}
    for c in d["cases"]:
        s = [math.floor(r["score"] * 1e4 + 0.5) / 1e4 for r in c["arms"]["with"]]
        t = 0.0
        for x in s: t += x
        out[c["name"]] = t / len(s)
    return out
o, n = means(sys.argv[1]), means(sys.argv[2])
diffs = [n[k] - o[k] for k in sorted(o) if k in n]
M = 0xFFFFFFFF
def imul(a, b): return (a * b) & M
a = 42
def rng():
    global a
    a = (a + 0x6D2B79F5) & M
    t = imul(a ^ (a >> 15), 1 | a)
    t = ((t + imul(t ^ (t >> 7), 61 | t)) & M) ^ t
    return ((t ^ (t >> 14)) & M) / 4294967296
B, k = 10000, len(diffs)
ms = []
for _ in range(B):
    s = 0.0
    for _ in range(k): s += diffs[math.floor(rng() * k)]
    ms.append(s / k)
ms.sort()
r4 = lambda x: math.floor(x * 1e4 + 0.5) / 1e4
lo, hi = r4(ms[math.floor(0.025 * B)]), r4(ms[math.ceil(0.975 * B) - 1])
fmt = lambda x: ("%g" % x)
print("[%s,%s]" % (fmt(lo), fmt(hi)))
PY
)
  expect_eq "bootstrap CI matches an independent Python implementation" "$PY_CI" "[0.04,0.18]"
else
  echo "skip bootstrap cross-check (python3 not found)"
fi

echo "# verdict branches"
cmp_json broken2 "$FX/stable-old" "$FX/broken2-new"
expect_eq "2 stable cases now failing every run: regressed, exit 1" "$RC $(jf "$TMP/broken2.json" d.verdict)" "1 regressed"
expect_eq "the regressed cases are named" "$(jf "$TMP/broken2.json" d.models.sonnet.regressed_cases)" '["case-01","case-02"]'
expect_eq "per-case flag says what changed" "$(jf "$TMP/broken2.json" d.models.sonnet.cases[0].flag)" "was PPP, now FFF"
expect_eq "CI upper bound exactly 0 (the rest tied) is not 'below 0'" \
  "$(jf "$TMP/broken2.json" '[d.models.sonnet.ci[1], d.models.sonnet.reasons.length, d.models.sonnet.reasons[0].startsWith("2 case(s) regressed")]')" '[0,1,true]'

cmp_json broken1 "$FX/stable-old" "$FX/broken1-new"
expect_eq "1 regressed case: no-change with a warning, exit 0" \
  "$RC $(jf "$TMP/broken1.json" '[d.verdict, d.models.sonnet.warnings.length]')" '0 ["no-change",1]'

cmp_json passk "$FX/passk-old" "$FX/passk-new"
expect_eq "3 cases each losing 1 of 3 runs is noise: no-change, exit 0" \
  "$RC $(jf "$TMP/passk.json" '[d.verdict, d.models.sonnet.old.pass_hat_k, d.models.sonnet.new.pass_hat_k]')" '0 ["no-change",0.9,0.7]'
expect_eq "sign test p with 1 up, 3 down" "$(jf "$TMP/passk.json" d.models.sonnet.sign.p)" 0.625

cmp_json drift "$FX/drift-old" "$FX/drift-new"
expect_eq "broad drift: CI below 0 and sign test p <= 0.05: regressed" \
  "$RC $(jf "$TMP/drift.json" '[d.verdict, d.models.sonnet.ci[1] < 0, d.models.sonnet.sign.p, d.models.sonnet.regressed_cases]')" '1 ["regressed",true,0.0078,[]]'
expect_has "reason names the CI and the sign test" "$(jf "$TMP/drift.json" 'd.models.sonnet.reasons[0]')" "lies entirely below 0 and the sign test agrees"
cmp_json drift-strict "$FX/drift-old" "$FX/drift-new" --sign-alpha 0.005
expect_eq "CI below 0 but the sign test not significant: no-change" "$RC $(jf "$TMP/drift-strict.json" d.verdict)" "0 no-change"

cmp_json reversed "$FX/worked-new" "$FX/worked-old"
expect_eq "CI below 0 with sign p 0.07 and no regressed case: no-change" \
  "$RC $(jf "$TMP/reversed.json" '[d.verdict, d.models.sonnet.ci]')" '0 ["no-change",[-0.18,-0.04]]'

cmp_json drop "$FX/drop-old" "$FX/drop-new"
expect_eq "mean score falling by >= 0.67 in 2 cases: regressed" \
  "$RC $(jf "$TMP/drop.json" '[d.verdict, d.models.sonnet.regressed_cases, d.models.sonnet.cases[0].flag]')" '1 ["regressed",["case-01","case-02"],"mean score 0.90 -> 0.20"]'

cmp_json same "$FX/worked-new" "$FX/worked-new"
expect_eq "identical sets: no-change, CI [0,0], p=1" \
  "$RC $(jf "$TMP/same.json" '[d.verdict, d.models.sonnet.ci, d.models.sonnet.sign.p]')" '0 ["no-change",[0,0],1]'

cmp_json single "$FX/k5-c3" "$FX/k5-c1"
expect_eq "1 paired case: insufficient-data, exit 0, however it moved" \
  "$RC $(jf "$TMP/single.json" '[d.verdict, d.models.sonnet.verdict]')" '0 ["insufficient-data","insufficient-data"]'
cmp_json four "$FX/stable-old" "$FX/broken2-new" --case 'case-0[1-4]'
expect_eq "4 paired cases, 2 broken: still insufficient-data (minimum 5)" "$RC $(jf "$TMP/four.json" d.verdict)" "0 insufficient-data"

echo "# calibration (Monte Carlo, seeded; RELEASING.md records the numbers)"
CAL=$(node "$SRC_ROOT/scripts/evals/calibrate.mjs" --trials 1000 --json)
echo "     $CAL"
cal() { node -e 'const d = JSON.parse(process.argv[1]); console.log(d[process.argv[2]])' "$CAL" "$1"; }
le() { node -e 'process.exit(Number(process.argv[1]) <= Number(process.argv[2]) ? 0 : 1)' "$1" "$2"; }
for s in "sonnet A/A" "sonnet-flaky3 A/A" "haiku A/A" "haiku-low A/A"; do
  if le "$(cal "$s")" 5; then ok "A/A false alarms <= 5%: $s ($(cal "$s")%)"; else nok "A/A false alarms <= 5%: $s" "$(cal "$s")%"; fi
done
for pair in "sonnet break 2:80" "sonnet break 3:95" "haiku break 2:25" "haiku break 3:40"; do
  s="${pair%:*}" min="${pair##*:}"
  if le "$min" "$(cal "$s")"; then ok "detects $s >= $min% ($(cal "$s")%)"; else nok "detects $s >= $min%" "$(cal "$s")%"; fi
done

echo "# pass@k and pass^k estimators"
cmp_json k5c3 "$FX/k5-c3" "$FX/k5-c3" --k 3
expect_eq "n=5 c=3 k=3: pass@3 = 1, pass^3 = C(3,3)/C(5,3) = 0.1" \
  "$(jf "$TMP/k5c3.json" '[d.models.sonnet.old.pass_at_k, d.models.sonnet.old.pass_hat_k]')" "[1,0.1]"
cmp_json k5c3d "$FX/k5-c3" "$FX/k5-c3"
expect_eq "n=5 c=3, default k=5: pass@5 = 1, pass^5 = 0" \
  "$(jf "$TMP/k5c3d.json" '[d.models.sonnet.k, d.models.sonnet.old.pass_at_k, d.models.sonnet.old.pass_hat_k]')" "[5,1,0]"
cmp_json k5c1 "$FX/k5-c1" "$FX/k5-c1" --k 3
expect_eq "n=5 c=1 k=3: pass@3 = 1 - C(4,3)/C(5,3) = 0.6, pass^3 = 0" \
  "$(jf "$TMP/k5c1.json" '[d.models.sonnet.old.pass_at_k, d.models.sonnet.old.pass_hat_k]')" "[0.6,0]"
expect_eq "flaky: mixed pass/fail across 5 runs" "$(jf "$TMP/k5c1.json" d.models.sonnet.old.flaky)" '["five-runs"]'

echo "# bad input"
cmp_json bigk "$FX/worked-old" "$FX/worked-new" --k 4
expect_eq "--k above the run count: exit 2" "$RC" 2
expect_has "--k error names the run count" "$(cat "$TMP/bigk.err")" "only 3 run(s)"
cmp_json nocommon "$FX/k5-c3" "$FX/worked-new"
expect_eq "no case in common: exit 2" "$RC" 2
cmp_json missing "$TMP/nope" "$FX/worked-new"
expect_eq "missing set: exit 2" "$RC" 2
cmp_json glob "$FX/worked-old" "$FX/worked-new" --case 'case-0[!1-7]'
expect_eq "--case takes a shell glob with brackets" "$(jf "$TMP/glob.json" 'd.models.sonnet.cases.map(c => c.name)')" '["case-08","case-09"]'
cmp_json glob2 "$FX/worked-old" "$FX/worked-new" --case 'case-0?'
expect_eq "--case filters both sets before pairing" "$(jf "$TMP/glob2.json" '[d.models.sonnet.n_paired, d.models.sonnet.only_old.length]')" "[9,0]"
cmp_json glob3 "$FX/worked-old" "$FX/worked-new" --case 'zzz*'
expect_eq "--case matching nothing: exit 2" "$RC" 2

echo "# baseline files"
EV="$TMP/evals"
mkdir -p "$EV/_fixtures" "$EV/results/old"
echo "lib" > "$EV/_fixtures/lib.sh"
for c in case-01 case-02 case-03 case-04 case-05 case-06 case-07 case-08 case-09 case-10 gone added; do
  mkdir -p "$EV/$c" && echo "prompt $c" > "$EV/$c/prompt.md"
done
node "$BASE" write "$FX/worked-old" --out "$TMP/q/baselines/v1.0.0.json" --version 1.0.0 --commit abc \
  --evals-dir "$EV" --model-id sonnet=claude-sonnet-x --model-id haiku=claude-haiku-y
B1="$TMP/q/baselines/v1.0.0.json"
expect_eq "baseline records version, tag, source, Claude Code, runs" \
  "$(jf "$B1" '[d.version, d.tag, d.source, d.claude_code, d.runs, d.judge_model]')" '["1.0.0","v1.0.0","release","2.1.284",3,"sonnet"]'
expect_eq "baseline records the resolved model ids" "$(jf "$B1" '[d.models.sonnet.model_id, d.models.haiku.model_id]')" '["claude-sonnet-x","claude-haiku-y"]'
expect_eq "baseline records per-case run scores and passes" "$(jf "$B1" 'd.models.sonnet.cases["case-06"]')" \
  '{"scores":[1,0.7,1],"passed":[true,false,true],"cost_usd":0.33,"duration_s":30}'
expect_eq "baseline records model cost and duration" "$(jf "$B1" '[d.models.sonnet.cost_usd, d.models.sonnet.duration_s]')" "[3.63,60]"
expect_eq "one line per case (11 sonnet + 1 haiku)" "$(grep -c '": {"scores"' "$B1")" 12
expect_eq "baseline hashes the cases it ran and _fixtures/" \
  "$(jf "$B1" '[Object.keys(d.evals.cases).length, "added" in d.evals.cases, /^[0-9a-f]{16}$/.test(d.evals.fixtures)]')" '[11,false,true]'

node "$BASE" write "$FX/worked-old" --out "$TMP/noid.json" --version 1.0.0 --evals-dir "$EV" --model-id 'sonnet=!probe failed: offline'
expect_eq "an unresolved model id is stored with its reason, never as null" \
  "$(jf "$TMP/noid.json" '["model_id" in d.models.sonnet, d.models.sonnet.model_id_unresolved, d.models.haiku.model_id_unresolved]')" \
  '[false,"probe failed: offline","no --model-id given"]'

node "$CMP" "$B1" "$FX/worked-new" --json > "$TMP/from-baseline.json"
expect_eq "a stored baseline compares exactly like the raw results" \
  "$(jf "$TMP/from-baseline.json" 'JSON.stringify(d.models)')" "$(jf "$W" 'JSON.stringify(d.models)')"

hw() { node "$BASE" write "$1" --out "$2" --version 1.1.0 --evals-dir "$EV" "${@:3}"; }
hw "$FX/worked-new" "$TMP/head.json" --model-id sonnet=claude-sonnet-x
hw "$FX/passk-new" "$TMP/head-patch.json" --model-id sonnet=claude-sonnet-x
hw "$FX/worked-new" "$TMP/head-newid.json" --model-id sonnet=claude-sonnet-z
hw "$FX/worked-new" "$TMP/head-noid.json" --model-id 'sonnet=!probe failed: offline'
sed 's/"claude_code": "2.1.284"/"claude_code": "2.2.0"/' "$TMP/head.json" > "$TMP/head-minor.json"
chk() { node "$BASE" check "$1" "$2" --evals-dir "$EV" "${@:3}"; }

echo "# reuse or rerun"
expect_eq "matching baseline: reuse, only the case missing from it re-runs" \
  "$(chk "$B1" "$TMP/head.json" --models sonnet | cut -d' ' -f1,2 | tr '\n' '|')" "REUSE sonnet|RERUN-CASE added|"
expect_has "patch-level Claude Code change: rerun by default" "$(chk "$B1" "$TMP/head-patch.json" --models sonnet)" \
  "RERUN sonnet Claude Code 2.1.284 -> 2.1.290"
expect_eq "--cc-match minor: a patch change reuses" "$(chk "$B1" "$TMP/head-patch.json" --models sonnet --cc-match minor | head -1 | cut -d' ' -f1,2)" "REUSE sonnet"
expect_has "--cc-match minor: a minor change reruns" "$(chk "$B1" "$TMP/head-minor.json" --models sonnet --cc-match minor)" \
  "RERUN sonnet Claude Code 2.1.284 -> 2.2.0 (major.minor changed)"
expect_has "resolved model id changed: rerun" "$(chk "$B1" "$TMP/head-newid.json" --models sonnet)" \
  "RERUN sonnet resolved model claude-sonnet-x -> claude-sonnet-z"
expect_has "model id not resolved now: rerun, with the reason" "$(chk "$B1" "$TMP/head-noid.json" --models sonnet)" \
  "RERUN sonnet model id not resolved now (probe failed: offline)"
expect_has "model id not resolved in the baseline: rerun" "$(chk "$TMP/noid.json" "$TMP/head.json" --models sonnet)" \
  "RERUN sonnet baseline model id was not resolved (probe failed: offline)"
expect_has "no baseline file: rerun" "$(chk "$TMP/q/baselines/v0.9.0.json" "$TMP/head.json" --models sonnet)" \
  "RERUN sonnet no stored baseline (v0.9.0.json)"
node "$BASE" write "$FX/k5-c3" --out "$TMP/sonnet-only.json" --version 1.0.0 --evals-dir "$EV" --model-id sonnet=claude-sonnet-x
expect_has "model missing from the baseline: rerun that model only" \
  "$(chk "$TMP/sonnet-only.json" "$B1" --models sonnet,haiku)" "RERUN haiku baseline has no haiku results"

echo "prompt case-03, reworded" > "$EV/case-03/prompt.md"
expect_eq "a changed case directory re-runs that case" \
  "$(chk "$B1" "$TMP/head.json" --models sonnet | grep RERUN-CASE | tr '\n' '|')" \
  "RERUN-CASE added not in the baseline|RERUN-CASE case-03 evals/case-03/ changed since the baseline|"
expect_eq "--case limits the case reruns" "$(chk "$B1" "$TMP/head.json" --models sonnet --case 'case-0*' | grep -c RERUN-CASE)" 1
echo "lib v2" > "$EV/_fixtures/lib.sh"
expect_eq "a _fixtures/ change re-runs everything" "$(chk "$B1" "$TMP/head.json" --models sonnet,haiku | tr '\n' '|')" \
  "RERUN sonnet evals/_fixtures/ changed since the baseline|RERUN haiku evals/_fixtures/ changed since the baseline|"
echo "results are ignored" > "$EV/results/old/x.json"
echo "lib" > "$EV/_fixtures/lib.sh"
expect_eq "evals/results/ is not hashed" "$(chk "$B1" "$TMP/head.json" --models sonnet | grep -c RERUN-CASE)" 2

echo "# merge a partial rerun"
node "$BASE" write "$FX/k5-c3" --out "$TMP/merged.json" --version 1.0.0 --source rerun --evals-dir "$EV" \
  --merge-into "$B1" --replace-models sonnet
expect_eq "a replaced model loses its old cases, other models kept" \
  "$(jf "$TMP/merged.json" '[d.source, Object.keys(d.models.sonnet.cases).length, Object.keys(d.models.haiku.cases).length]')" '["rerun",1,1]'
node "$BASE" write "$FX/k5-c3" --out "$TMP/merged2.json" --version 1.0.0 --source rerun --evals-dir "$EV" --merge-into "$B1"
expect_eq "a case rerun merges into the model's stored cases" \
  "$(jf "$TMP/merged2.json" '[Object.keys(d.models.sonnet.cases).length, d.models.sonnet.cases["case-06"].scores]')" \
  '[12,[1,0.7,1]]'

echo "# trend line"
node "$CMP" "$B1" "$TMP/head.json" --json --old-label "v1.0.0 (stored baseline)" > "$TMP/c.json"
T="$TMP/q/trend.jsonl"
node "$BASE" trend --head "$TMP/head.json" --compare "$TMP/c.json" --gate false --out "$T"
expect_eq "one line appended" "$(wc -l < "$T" | tr -d ' ')" 1
L=$(head -1 "$T"); echo "$L" > "$TMP/line.json"
expect_eq "trend: version, vs, verdict, gate" "$(jf "$TMP/line.json" '[d.version, d.vs, d.verdict, d.gate, d.claude_code]')" \
  '["1.1.0","v1.0.0 (stored baseline)","improved",false,"2.1.284"]'
expect_eq "trend: per-model stats" \
  "$(jf "$TMP/line.json" '(({cases, pass_rate, k, mean_score, cost_usd, duration_s, flaky}) => ({cases, pass_rate, "pass^k": d.models.sonnet["pass^k"], k, mean_score, cost_usd, duration_s, flaky}))(d.models.sonnet)')" \
  '{"cases":11,"pass_rate":0.4545,"pass^k":0.3636,"k":3,"mean_score":0.9091,"cost_usd":3.63,"duration_s":60,"flaky":["case-09","case-10"]}'
expect_eq "trend: paired delta vs the previous release" "$(jf "$TMP/line.json" d.models.sonnet.paired_delta_vs_prev)" \
  '{"mean":0.11,"ci":[0.04,0.18],"sign_p":0.0703,"n":10,"regressed_cases":[],"verdict":"improved"}'
node "$BASE" trend --head "$TMP/head.json" --compare "$TMP/c.json" --gate false --out "$T"
expect_eq "re-recording a version replaces its line" "$(wc -l < "$T" | tr -d ' ')" 1
node "$BASE" skip --version 1.2.0 --reason "usage limit reached" --out "$T"
expect_eq "skip line records the reason" "$(tail -1 "$T" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); console.log(d.version + "|" + d.skipped + "|" + /^\d{4}-\d\d-\d\d$/.test(d.date))')" \
  "1.2.0|usage limit reached|true"

echo
echo "eval-compare: $pass passed, $fail failed"
[ "$fail" = 0 ]
