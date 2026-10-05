#!/usr/bin/env bash
# Release eval check: run HEAD's full eval suite, compare it case by case with
# the previous release, stage the baseline and trend line. Maintainer
# tooling: not shipped. Called by the /release skill (RELEASING.md).
#
# Usage:
#   scripts/evals/release-check.sh --version X.Y.Z [--prev-tag vA.B.C]
#       [--runs N] [--models sonnet,haiku] [--case <glob>] [--out <dir>]
#       [--head-results <dir>] [--cc-match exact|minor]
#   scripts/evals/release-check.sh --record <out-dir>
#   scripts/evals/release-check.sh --version X.Y.Z --skip "<reason>"
#
#   --version       the version being released (names the baseline file)
#   --prev-tag      default: the latest tag reachable from HEAD
#   --runs/--models default: 3 runs, sonnet,haiku (the full release suite)
#   --case          restrict to a case glob: a partial run, never recordable,
#                   never exit 1
#   --head-results  reuse an earlier run.sh results dir for HEAD, spend nothing on it
#   --cc-match      exact (default): any Claude Code version change re-runs the
#                   previous tag; minor: only a major.minor change does
#   --record        after the maintainer's go: copy what a check staged in
#                   <out-dir>/staged/ into quality/ (baselines, trend line)
#   --skip          record {"skipped": "<reason>"} in quality/trend.jsonl, run nothing
#
# Steps of a check:
#   1. run.sh --mode full on HEAD           → <out>/head/
#   2. resolve each model alias to its model id (one tiny `claude -p` call per
#      model; MYSPEC_EVAL_RESOLVE_MODELS=0 skips it, which forces step 3 to
#      re-run the previous tag next time: an unresolved id is never reused)
#   3. previous release: reuse quality/baselines/<prev-tag>.json where it still
#      holds (baseline.mjs check). Otherwise run the same evals/ against a
#      temporary git worktree of <prev-tag> with HEAD's evals/ copied in
#      (same cases, old plugin): the whole suite for models that need it,
#      single cases whose evals/<case>/ changed for the rest.
#   4. compare.mjs previous vs HEAD         → report, <out>/compare.json
#   5. stage baselines and the trend line in <out>/staged/. Nothing touches
#      quality/ until --record.
#
# Gate: quality/release-check.json "gate": false reports only; "gate": true
# makes a regressed verdict exit 1, but only when a model "gateModels" lists
# regressed (no key: every model that ran gates). Every model still runs and
# is reported; a regression on any other model is a report-only warning. A
# --case run never exits 1.
#
# Exit status: 0 done (report-only, not regressed, or partial) · 1 regressed
# and the gate is on · 2 infrastructure error (bad arguments, eval run failed,
# unreadable results, nothing staged). The temporary worktree is removed and
# the running eval killed on every exit path, including an interrupt.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUALITY_DIR="$REPO_ROOT/quality"
CONFIG="$QUALITY_DIR/release-check.json"
CLAUDE_BIN="${MYSPEC_EVAL_CLAUDE:-claude}"

die() { echo "release-check: $*" >&2; exit 2; }
usage() { sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

VERSION="" PREV_TAG="" RUNS=3 MODELS="sonnet,haiku" CASE_GLOB="" OUT="" HEAD_RESULTS="" SKIP_REASON="" SKIP=0
RECORD_FROM="" CC_MATCH="exact"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --prev-tag) PREV_TAG="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --models) MODELS="${2:-}"; shift 2 ;;
    --case) CASE_GLOB="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --head-results) HEAD_RESULTS="${2:-}"; shift 2 ;;
    --cc-match) CC_MATCH="${2:-}"; shift 2 ;;
    --record) RECORD_FROM="${2:-}"; shift 2 ;;
    --skip) SKIP=1; SKIP_REASON="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || die "node is not on PATH"
cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

# ------------------------------------------------------------ --record
if [ -n "$RECORD_FROM" ]; then
  S="$RECORD_FROM/staged"
  [ -f "$S/trend.jsonl" ] || die "nothing staged in $RECORD_FROM (not a release-check output dir?)"
  [ -f "$S/partial" ] && die "$RECORD_FROM is a partial run ($(cat "$S/partial")); it cannot be recorded"
  mkdir -p "$QUALITY_DIR/baselines" || die "cannot create $QUALITY_DIR/baselines"
  for f in "$S"/baselines/*.json; do
    [ -f "$f" ] || continue
    cp "$f" "$QUALITY_DIR/baselines/" || die "cannot copy $f"
    echo "release-check: recorded quality/baselines/$(basename "$f")"
  done
  node "$SCRIPT_DIR/baseline.mjs" append --from "$S/trend.jsonl" --out "$QUALITY_DIR/trend.jsonl" || exit 2
  v=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").pop()).version)' "$S/trend.jsonl")
  echo "release-check: recorded a quality/trend.jsonl line"
  echo "release-check: commit it before the bump: chore(quality): record v$v eval baseline"
  exit 0
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version X.Y.Z is required"
case "$RUNS" in ''|*[!0-9]*|0) die "--runs must be a positive integer" ;; esac
case "$CC_MATCH" in exact|minor) ;; *) die "--cc-match exact|minor" ;; esac

if [ "$SKIP" = 1 ]; then
  [ -n "$SKIP_REASON" ] || die "--skip needs a reason"
  node "$SCRIPT_DIR/baseline.mjs" skip --version "$VERSION" --reason "$SKIP_REASON" --out "$QUALITY_DIR/trend.jsonl" || exit 2
  echo "release-check: skipped v$VERSION ($SKIP_REASON); recorded in quality/trend.jsonl"
  exit 0
fi

# gate seed resamples gate-models: "*" when gateModels is absent (every model
# gates), "-" for an empty list (none does).
read -r GATE SEED RESAMPLES GATE_MODELS < <(node -e '
  const fs = require("fs");
  const c = fs.existsSync(process.argv[1]) ? JSON.parse(fs.readFileSync(process.argv[1], "utf8")) : {};
  const g = c.gateModels;
  if (g !== undefined && !(Array.isArray(g) && g.every((m) => typeof m === "string" && /^[\w.-]+$/.test(m)))) {
    throw new Error("gateModels must be an array of model aliases");
  }
  console.log([c.gate === true, c.seed ?? 42, c.resamples ?? 10000, g === undefined ? "*" : g.join(",") || "-"].join(" "));
' "$CONFIG") || die "unreadable $CONFIG"
[ -n "${GATE_MODELS:-}" ] || die "unreadable $CONFIG"

if [ -z "$PREV_TAG" ]; then
  PREV_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null) || PREV_TAG=""
  if [ "$PREV_TAG" = "v$VERSION" ]; then PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null) || PREV_TAG=""; fi
elif ! git rev-parse --verify --quiet "$PREV_TAG^{commit}" >/dev/null; then
  die "tag not found: $PREV_TAG"
fi

[ -n "$OUT" ] || OUT="$REPO_ROOT/.eval-results/$(date -u +%Y%m%dT%H%M%SZ)-release-check-$$"
mkdir -p "$OUT" || die "cannot create $OUT"
OUT="$(cd "$OUT" && pwd)"
STAGE="$OUT/staged"
rm -rf "$STAGE"

WT="" WT_PARENT="" CHILD=""
cleanup() {
  if [ -n "$CHILD" ]; then
    kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
    wait "$CHILD" 2>/dev/null
    CHILD=""
  fi
  if [ -n "$WT" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1
    WT=""
  fi
  if [ -n "$WT_PARENT" ]; then rm -rf "$WT_PARENT"; WT_PARENT=""; fi
}
trap cleanup EXIT
trap 'echo "release-check: interrupted" >&2; exit 2' INT TERM HUP

# run_suite <out> <models> [plugin-dir] [case glob]: the full suite, report-only,
# 0 or 2. run.sh runs in its own process group, in the background, so an
# interrupt kills it and every eval under it at once instead of waiting.
run_suite() {
  local args=(--mode full --runs "$RUNS" --models "$2" --out "$1") glob="${4:-$CASE_GLOB}" rc
  [ -n "$glob" ] && args+=(--case "$glob")
  [ -n "${3:-}" ] && args+=(--plugin-dir "$3")
  set -m
  MYSPEC_EVALS_STRICT=0 "$SCRIPT_DIR/run.sh" "${args[@]}" &
  CHILD=$!
  set +m
  wait "$CHILD"
  rc=$?
  CHILD=""
  return "$rc"
}

# resolve_model_id <alias>: prints "<id>", or "!<why it could not be resolved>".
resolve_model_id() {
  if [ "${MYSPEC_EVAL_RESOLVE_MODELS:-1}" != 1 ]; then echo "!probe disabled (MYSPEC_EVAL_RESOLVE_MODELS=0)"; return 0; fi
  local d
  d=$(mktemp -d) || { echo "!mktemp failed"; return 0; }
  printf 'Reply with the single word OK.\n' > "$d/prompt"
  (cd "$d" && perl -e 'alarm shift; exec @ARGV' 90 "$CLAUDE_BIN" -p --model "$1" --output-format json \
    --max-turns 1 --strict-mcp-config --setting-sources "" --tools "" < prompt > out.json 2>err.txt)
  echo "exit $?" >> "$d/err.txt"
  node -e '
    const fs = require("fs");
    try {
      const s = fs.readFileSync(process.argv[1], "utf8");
      const u = JSON.parse(s.slice(s.indexOf("{"))).modelUsage ?? {};
      const best = Object.entries(u).sort((a, b) => (b[1].costUSD ?? 0) - (a[1].costUSD ?? 0))[0];
      console.log(best ? best[0] : "!probe reply had no modelUsage");
    } catch {
      const e = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").slice(-2).join(" / ");
      console.log("!probe failed: " + e.slice(0, 120));
    }
  ' "$d/out.json" "$d/err.txt"
  rm -rf "$d"
}

json_field() { node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]] ?? "") } catch { console.log("") }' "$1" "$2"; }

echo "release-check: v$VERSION vs ${PREV_TAG:-<no previous tag>} · runs=$RUNS models=$MODELS${CASE_GLOB:+ case=$CASE_GLOB} · gate=$([ "$GATE" = true ] && echo "on ($([ "$GATE_MODELS" = '*' ] && echo 'every model' || echo "$GATE_MODELS"))" || echo 'off (report-only)')"
echo "release-check: output in $OUT"

# ------------------------------------------------------------------ 1. HEAD
if [ -n "$HEAD_RESULTS" ]; then
  [ -d "$HEAD_RESULTS" ] || die "--head-results not found: $HEAD_RESULTS"
  HEAD_DIR="$HEAD_RESULTS"
  echo "release-check: reusing HEAD results from $HEAD_DIR"
else
  HEAD_DIR="$OUT/head"
  echo "release-check: running HEAD's suite"
  run_suite "$HEAD_DIR" "$MODELS" || die "HEAD eval run failed (run.sh exit $?); no verdict"
fi

# ---------------------------------------------------------- 2. model ids
MID_ARGS=()
IFS=',' read -r -a model_list <<< "$MODELS"
for m in "${model_list[@]}"; do
  [ -n "$m" ] || continue
  id=$(resolve_model_id "$m")
  MID_ARGS+=(--model-id "$m=$id")
  echo "release-check: model $m -> ${id#!}$([ "${id:0:1}" = '!' ] && echo ' (unresolved: the next release re-runs this one)')"
done

node "$SCRIPT_DIR/baseline.mjs" write "$HEAD_DIR" --out "$OUT/head-baseline.json" --version "$VERSION" \
  --commit "$(git rev-parse HEAD)" --source release --evals-dir "$REPO_ROOT/evals" "${MID_ARGS[@]}" \
  || die "cannot read HEAD results"

# stage <compare.json or empty>: baselines and trend line into $STAGE.
stage() {
  local cmp_args=()
  [ -n "${1:-}" ] && cmp_args=(--compare "$1")
  mkdir -p "$STAGE/baselines" || die "cannot create $STAGE"
  cp "$OUT/head-baseline.json" "$STAGE/baselines/v$VERSION.json" || die "cannot stage the baseline"
  if [ -n "${PREV_REFRESHED:-}" ]; then cp "$OUT/prev-baseline.json" "$STAGE/baselines/$PREV_TAG.json" || die "cannot stage $PREV_TAG"; fi
  node "$SCRIPT_DIR/baseline.mjs" trend --head "$OUT/head-baseline.json" --gate "$GATE" --out "$STAGE/trend.jsonl" \
    ${cmp_args[@]+"${cmp_args[@]}"} || die "cannot stage the trend line"
  if [ -n "$CASE_GLOB" ]; then
    echo "--case $CASE_GLOB" > "$STAGE/partial"
    echo "release-check: partial run (--case): nothing to record; staged files are in $STAGE for reading only"
  else
    echo "release-check: staged in $STAGE; quality/ is untouched until: $0 --record $OUT"
  fi
}

if [ -z "$PREV_TAG" ]; then
  echo "release-check: no previous tag; nothing to compare against"
  stage ""
  exit 0
fi

# --------------------------------------------------- 3. previous release
PREV_FILE="$QUALITY_DIR/baselines/$PREV_TAG.json"
decisions=$(node "$SCRIPT_DIR/baseline.mjs" check "$PREV_FILE" "$OUT/head-baseline.json" --models "$MODELS" \
  --evals-dir "$REPO_ROOT/evals" --cc-match "$CC_MATCH" ${CASE_GLOB:+--case "$CASE_GLOB"}) \
  || die "cannot check $PREV_FILE"
printf '%s\n' "$decisions" | sed 's/^/release-check: baseline /'
rerun_models=$(printf '%s\n' "$decisions" | awk '$1 == "RERUN" { printf "%s%s", sep, $2; sep = "," }')
reuse_models=$(printf '%s\n' "$decisions" | awk '$1 == "REUSE" { printf "%s%s", sep, $2; sep = "," }')
rerun_cases=$(printf '%s\n' "$decisions" | awk '$1 == "RERUN-CASE" { print $2 }')

PREV_SET="$PREV_FILE" PREV_SOURCE="stored baseline" PREV_REFRESHED=""
if [ -n "$rerun_models" ] || { [ -n "$rerun_cases" ] && [ -n "$reuse_models" ]; }; then
  git rev-parse --verify --quiet "$PREV_TAG^{commit}" >/dev/null || die "tag not found: $PREV_TAG"
  tmp_root="${TMPDIR:-/tmp}"
  WT_PARENT=$(mktemp -d "${tmp_root%/}/myspec-release-check.XXXXXX") || die "mktemp failed"
  WT="$WT_PARENT/${PREV_TAG//\//-}"
  echo "release-check: re-running $PREV_TAG in a temporary worktree $WT"
  git -C "$REPO_ROOT" worktree add --detach --quiet "$WT" "$PREV_TAG" >/dev/null 2>&1 \
    || { WT=""; die "git worktree add $PREV_TAG failed"; }
  rm -rf "$WT/evals" && cp -R "$REPO_ROOT/evals" "$WT/evals" && rm -rf "$WT/evals/results" \
    || die "cannot copy evals/ into the $PREV_TAG worktree"
  if [ -n "$rerun_models" ]; then
    echo "release-check: $PREV_TAG, whole suite: $rerun_models"
    run_suite "$OUT/prev/suite" "$rerun_models" "$WT" || die "$PREV_TAG eval run failed (run.sh exit $?); no verdict"
  fi
  if [ -n "$reuse_models" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      echo "release-check: $PREV_TAG, changed case $c: $reuse_models"
      run_suite "$OUT/prev/case-$c" "$reuse_models" "$WT" "$c" || die "$PREV_TAG eval run of $c failed (run.sh exit $?); no verdict"
    done <<< "$rerun_cases"
  fi
  cleanup
  merge_args=()
  [ -f "$PREV_FILE" ] && merge_args=(--merge-into "$PREV_FILE" --replace-models "$rerun_models")
  node "$SCRIPT_DIR/baseline.mjs" write "$OUT/prev" --out "$OUT/prev-baseline.json" --version "${PREV_TAG#v}" \
    --tag "$PREV_TAG" --commit "$(git rev-parse "$PREV_TAG^{commit}")" --source rerun --evals-dir "$REPO_ROOT/evals" \
    "${MID_ARGS[@]}" ${merge_args[@]+"${merge_args[@]}"} || die "cannot read $PREV_TAG results"
  PREV_SET="$OUT/prev-baseline.json" PREV_SOURCE="re-run" PREV_REFRESHED=1
  [ -z "$rerun_models" ] && PREV_SOURCE="stored baseline, changed cases re-run"
fi

# ------------------------------------------------------------ 4. compare
cmp_args=(--seed "$SEED" --resamples "$RESAMPLES" --old-label "$PREV_TAG ($PREV_SOURCE)" --new-label "v$VERSION (HEAD)")
[ -n "$CASE_GLOB" ] && cmp_args+=(--case "$CASE_GLOB")
node "$SCRIPT_DIR/compare.mjs" "$PREV_SET" "$OUT/head-baseline.json" --json "${cmp_args[@]}" > "$OUT/compare.json"
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || die "comparison failed (compare.mjs exit $rc)"
echo
node "$SCRIPT_DIR/compare.mjs" "$PREV_SET" "$OUT/head-baseline.json" "${cmp_args[@]}" | tee "$OUT/compare.txt"
echo

# --------------------------------------------------------------- 5. stage
stage "$OUT/compare.json"

verdict=$(json_field "$OUT/compare.json" verdict)
# Spend of the runs this invocation made (a reused --head-results dir cost nothing now).
spent=()
[ -z "$HEAD_RESULTS" ] && spent+=("$HEAD_DIR")
[ -n "$PREV_REFRESHED" ] && spent+=("$OUT/prev")
if [ "${#spent[@]}" -gt 0 ]; then
  cost=$(node --input-type=module -e '
    const { loadResultsDir } = await import(process.argv[1]);
    let t = 0;
    for (const d of process.argv.slice(2)) for (const m of Object.values(loadResultsDir(d).models)) t += m.cost_usd;
    console.log(t.toFixed(2));
  ' "$SCRIPT_DIR/results.mjs" "${spent[@]}")
  echo "release-check: estimated eval spend of this check: \$$cost (${spent[*]##*/})"
fi

if [ "$verdict" = regressed ]; then
  if [ -n "$CASE_GLOB" ]; then
    echo "release-check: REGRESSED on a partial run (--case); never a gate"
    exit 0
  fi
  if [ "$GATE" = true ]; then
    # compare.mjs's verdict is the worst model's; split the regressed models
    # into the ones gateModels lists (block) and the rest (warn only).
    read -r gated reported < <(node -e '
      const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const g = process.argv[2];
      const gates = (m) => g === "*" || g.split(",").includes(m);
      const reg = Object.entries(d.models).filter(([, r]) => r.verdict === "regressed").map(([m]) => m);
      console.log([reg.filter(gates).join(",") || "-", reg.filter((m) => !gates(m)).join(",") || "-"].join(" "));
    ' "$OUT/compare.json" "$GATE_MODELS") || die "cannot read $OUT/compare.json"
    if [ "$reported" != - ]; then
      echo "release-check: WARNING: REGRESSED on $reported; report-only (not in gateModels, quality/release-check.json)" >&2
    fi
    if [ "$gated" != - ]; then
      echo "release-check: REGRESSED on $gated and the gate is on (quality/release-check.json); blocking" >&2
      exit 1
    fi
    echo "release-check: no gating model regressed; not blocking"
    exit 0
  fi
  echo "release-check: REGRESSED; report-only (gate off in quality/release-check.json), the maintainer decides"
  exit 0
fi
echo "release-check: verdict $verdict"
exit 0
