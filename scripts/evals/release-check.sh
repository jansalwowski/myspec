#!/usr/bin/env bash
# Release eval check: run HEAD's full eval suite, compare it case by case with
# the previous release, record the result. Maintainer tooling: not shipped.
# Called by the /release skill after preflight (RELEASING.md).
#
# Usage:
#   scripts/evals/release-check.sh --version X.Y.Z [--prev-tag vA.B.C]
#       [--runs N] [--models sonnet,haiku] [--case <glob>] [--out <dir>]
#       [--head-results <dir>] [--no-record]
#   scripts/evals/release-check.sh --version X.Y.Z --skip "<reason>"
#
#   --version       the version being released (names the baseline file)
#   --prev-tag      default: the latest tag reachable from HEAD
#   --runs/--models default: 3 runs, sonnet,haiku (the full release suite)
#   --case          restrict to a case glob; implies --no-record
#   --head-results  reuse an earlier run.sh results dir for HEAD, spend nothing on it
#   --no-record     leave quality/ untouched; baseline and trend line stay in --out
#   --skip          record {"skipped": "<reason>"} in quality/trend.jsonl, run nothing
#
# Steps:
#   1. run.sh --mode full on HEAD           → <out>/head/
#   2. resolve each model alias to its model id (one tiny `claude -p` call per
#      model; MYSPEC_EVAL_RESOLVE_MODELS=0 skips it)
#   3. previous release: reuse quality/baselines/<prev-tag>.json when it matches
#      (baseline.mjs check). Otherwise run the same evals/ against a temporary
#      git worktree of <prev-tag> with HEAD's evals/ copied in (same cases, old
#      plugin), only for the models that need it.
#   4. compare.mjs previous vs HEAD         → report, <out>/compare.json
#   5. write quality/baselines/v<version>.json (and the rerun previous-tag
#      baseline), append quality/trend.jsonl. Commit both before the bump.
#
# Gate: quality/release-check.json "gate": false reports only; "gate": true
# makes a regressed verdict exit 1. It also holds pass_k_margin, seed, resamples.
#
# Exit status: 0 done (report-only, or not regressed) · 1 regressed and the
# gate is on · 2 infrastructure error (bad arguments, eval run failed, unreadable
# results). The temporary worktree is removed on every exit path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUALITY_DIR="$REPO_ROOT/quality"
CONFIG="$QUALITY_DIR/release-check.json"
CLAUDE_BIN="${MYSPEC_EVAL_CLAUDE:-claude}"

die() { echo "release-check: $*" >&2; exit 2; }
usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

VERSION="" PREV_TAG="" RUNS=3 MODELS="sonnet,haiku" CASE_GLOB="" OUT="" HEAD_RESULTS="" RECORD=1 SKIP_REASON="" SKIP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --prev-tag) PREV_TAG="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --models) MODELS="${2:-}"; shift 2 ;;
    --case) CASE_GLOB="${2:-}"; RECORD=0; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --head-results) HEAD_RESULTS="${2:-}"; shift 2 ;;
    --no-record) RECORD=0; shift ;;
    --skip) SKIP=1; SKIP_REASON="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version X.Y.Z is required"
case "$RUNS" in ''|*[!0-9]*|0) die "--runs must be a positive integer" ;; esac
command -v node >/dev/null 2>&1 || die "node is not on PATH"
cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

if [ "$SKIP" = 1 ]; then
  [ -n "$SKIP_REASON" ] || die "--skip needs a reason"
  node "$SCRIPT_DIR/baseline.mjs" skip --version "$VERSION" --reason "$SKIP_REASON" --out "$QUALITY_DIR/trend.jsonl" || exit 2
  echo "release-check: skipped v$VERSION ($SKIP_REASON); recorded in quality/trend.jsonl"
  exit 0
fi

# gate pass_k_margin seed resamples
read -r GATE MARGIN SEED RESAMPLES < <(node -e '
  const fs = require("fs");
  const c = fs.existsSync(process.argv[1]) ? JSON.parse(fs.readFileSync(process.argv[1], "utf8")) : {};
  console.log([c.gate === true, c.pass_k_margin ?? 0.1, c.seed ?? 42, c.resamples ?? 10000].join(" "));
' "$CONFIG") || die "unreadable $CONFIG"
[ -n "${GATE:-}" ] || die "unreadable $CONFIG"

if [ -z "$PREV_TAG" ]; then
  PREV_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null) || PREV_TAG=""
  if [ "$PREV_TAG" = "v$VERSION" ]; then PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null) || PREV_TAG=""; fi
elif ! git rev-parse --verify --quiet "$PREV_TAG^{commit}" >/dev/null; then
  die "tag not found: $PREV_TAG"
fi

[ -n "$OUT" ] || OUT="$REPO_ROOT/.eval-results/$(date -u +%Y%m%dT%H%M%SZ)-release-check"
mkdir -p "$OUT" || die "cannot create $OUT"
OUT="$(cd "$OUT" && pwd)"

WT="" WT_PARENT=""
cleanup() {
  if [ -n "$WT" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1
    WT=""
  fi
  if [ -n "$WT_PARENT" ]; then rm -rf "$WT_PARENT"; WT_PARENT=""; fi
}
trap cleanup EXIT
trap 'exit 2' INT TERM HUP

# run_suite <out> <models> [plugin-dir]: the full suite, report-only, 0 or 2.
run_suite() {
  local args=(--mode full --runs "$RUNS" --models "$2" --out "$1")
  [ -n "$CASE_GLOB" ] && args+=(--case "$CASE_GLOB")
  [ -n "${3:-}" ] && args+=(--plugin-dir "$3")
  MYSPEC_EVALS_STRICT=0 "$SCRIPT_DIR/run.sh" "${args[@]}"
}

# resolve_model_id <alias>: the model id Claude Code resolves the alias to, or nothing.
resolve_model_id() {
  [ "${MYSPEC_EVAL_RESOLVE_MODELS:-1}" = 1 ] || return 0
  local d
  d=$(mktemp -d) || return 0
  printf 'Reply with the single word OK.\n' > "$d/prompt"
  (cd "$d" && perl -e 'alarm shift; exec @ARGV' 90 "$CLAUDE_BIN" -p --model "$1" --output-format json \
    --max-turns 1 --strict-mcp-config --setting-sources "" --tools "" < prompt > out.json 2>/dev/null)
  node -e '
    try {
      const s = require("fs").readFileSync(process.argv[1], "utf8");
      const u = JSON.parse(s.slice(s.indexOf("{"))).modelUsage ?? {};
      const best = Object.entries(u).sort((a, b) => (b[1].costUSD ?? 0) - (a[1].costUSD ?? 0))[0];
      if (best) console.log(best[0]);
    } catch {}
  ' "$d/out.json"
  rm -rf "$d"
}

json_field() { node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]] ?? "") } catch { console.log("") }' "$1" "$2"; }

echo "release-check: v$VERSION vs ${PREV_TAG:-<no previous tag>} · runs=$RUNS models=$MODELS${CASE_GLOB:+ case=$CASE_GLOB} · gate=$([ "$GATE" = true ] && echo on || echo 'off (report-only)')"
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
  [ -n "$id" ] && MID_ARGS+=(--model-id "$m=$id")
  echo "release-check: model $m -> ${id:-<unresolved>}"
done

node "$SCRIPT_DIR/baseline.mjs" write "$HEAD_DIR" --out "$OUT/head-baseline.json" --version "$VERSION" \
  --commit "$(git rev-parse HEAD)" --source release ${MID_ARGS[@]+"${MID_ARGS[@]}"} || die "cannot read HEAD results"

record() {  # record <compare.json or empty>
  local cmp_args=()
  [ -n "${1:-}" ] && cmp_args=(--compare "$1")
  if [ "$RECORD" = 1 ]; then
    mkdir -p "$QUALITY_DIR/baselines" || die "cannot create $QUALITY_DIR/baselines"
    cp "$OUT/head-baseline.json" "$QUALITY_DIR/baselines/v$VERSION.json" || die "cannot write baseline"
    [ -n "${PREV_REFRESHED:-}" ] && { cp "$OUT/prev-baseline.json" "$PREV_FILE" || die "cannot write $PREV_FILE"; }
    node "$SCRIPT_DIR/baseline.mjs" trend --head "$OUT/head-baseline.json" --gate "$GATE" --out "$QUALITY_DIR/trend.jsonl" \
      ${cmp_args[@]+"${cmp_args[@]}"} || die "cannot append trend line"
    echo "release-check: recorded quality/baselines/v$VERSION.json${PREV_REFRESHED:+ and quality/baselines/$PREV_TAG.json} and a quality/trend.jsonl line"
    echo "release-check: commit them before the bump: chore(quality): record v$VERSION eval baseline"
  else
    node "$SCRIPT_DIR/baseline.mjs" trend --head "$OUT/head-baseline.json" --gate "$GATE" --out "$OUT/trend.jsonl" \
      ${cmp_args[@]+"${cmp_args[@]}"} || die "cannot write trend line"
    echo "release-check: not recorded (partial run); baseline and trend line are in $OUT"
  fi
}

if [ -z "$PREV_TAG" ]; then
  echo "release-check: no previous tag; nothing to compare against"
  record ""
  exit 0
fi

# --------------------------------------------------- 3. previous release
PREV_FILE="$QUALITY_DIR/baselines/$PREV_TAG.json"
decisions=$(node "$SCRIPT_DIR/baseline.mjs" check "$PREV_FILE" "$OUT/head-baseline.json" --models "$MODELS") \
  || die "cannot check $PREV_FILE"
printf '%s\n' "$decisions" | sed 's/^/release-check: baseline /'
rerun=$(printf '%s\n' "$decisions" | awk '$1 == "RERUN" { printf "%s%s", sep, $2; sep = "," }')

PREV_SET="$PREV_FILE" PREV_SOURCE="stored baseline" PREV_REFRESHED=""
if [ -n "$rerun" ]; then
  git rev-parse --verify --quiet "$PREV_TAG^{commit}" >/dev/null || die "tag not found: $PREV_TAG"
  tmp_root="${TMPDIR:-/tmp}"
  WT_PARENT=$(mktemp -d "${tmp_root%/}/myspec-release-check.XXXXXX") || die "mktemp failed"
  WT="$WT_PARENT/${PREV_TAG//\//-}"
  echo "release-check: re-running $PREV_TAG ($rerun) in a temporary worktree $WT"
  git -C "$REPO_ROOT" worktree add --detach --quiet "$WT" "$PREV_TAG" >/dev/null 2>&1 \
    || { WT=""; die "git worktree add $PREV_TAG failed"; }
  rm -rf "$WT/evals" && cp -R "$REPO_ROOT/evals" "$WT/evals" && rm -rf "$WT/evals/results" \
    || die "cannot copy evals/ into the $PREV_TAG worktree"
  run_suite "$OUT/prev" "$rerun" "$WT" || die "$PREV_TAG eval run failed (run.sh exit $?); no verdict"
  cleanup
  merge_args=()
  [ -f "$PREV_FILE" ] && merge_args=(--merge-into "$PREV_FILE")
  node "$SCRIPT_DIR/baseline.mjs" write "$OUT/prev" --out "$OUT/prev-baseline.json" --version "${PREV_TAG#v}" \
    --tag "$PREV_TAG" --commit "$(git rev-parse "$PREV_TAG^{commit}")" --source rerun \
    ${MID_ARGS[@]+"${MID_ARGS[@]}"} ${merge_args[@]+"${merge_args[@]}"} || die "cannot read $PREV_TAG results"
  PREV_SET="$OUT/prev-baseline.json" PREV_SOURCE="re-run" PREV_REFRESHED=1
fi

# ------------------------------------------------------------ 4. compare
cmp_args=(--seed "$SEED" --resamples "$RESAMPLES" --pass-k-margin "$MARGIN"
  --old-label "$PREV_TAG ($PREV_SOURCE)" --new-label "v$VERSION (HEAD)")
[ -n "$CASE_GLOB" ] && cmp_args+=(--case "$CASE_GLOB")
node "$SCRIPT_DIR/compare.mjs" "$PREV_SET" "$OUT/head-baseline.json" --json "${cmp_args[@]}" > "$OUT/compare.json"
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || die "comparison failed (compare.mjs exit $rc)"
echo
node "$SCRIPT_DIR/compare.mjs" "$PREV_SET" "$OUT/head-baseline.json" "${cmp_args[@]}" | tee "$OUT/compare.txt"
echo

# ------------------------------------------------------------- 5. record
record "$OUT/compare.json"

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
  if [ "$GATE" = true ]; then
    echo "release-check: REGRESSED and the gate is on (quality/release-check.json); blocking" >&2
    exit 1
  fi
  echo "release-check: REGRESSED; report-only (gate off in quality/release-check.json), the maintainer decides"
  exit 0
fi
echo "release-check: verdict $verdict"
exit 0
