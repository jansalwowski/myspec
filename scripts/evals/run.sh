#!/usr/bin/env bash
# Run the behavioural eval suite (evals/) with `claude plugin eval` on the
# maintainer's own Claude Code login. Maintainer tooling: not shipped.
#
# Usage:
#   scripts/evals/run.sh --mode changed|full [--base <git-ref>] [--out <dir>]
#                        [--runs N] [--models sonnet,haiku] [--case <glob>]
#
#   --mode changed  cases whose skill:<name> tags name a skill changed between
#                   --base and HEAD (selection rules: evals/README.md).
#                   Defaults: --runs 1 --models sonnet.
#   --mode full     every case. Defaults: --runs 3 --models sonnet,haiku.
#   --base          default: git merge-base origin/main HEAD (then main).
#   --out           default: .eval-results/<UTC timestamp>-<mode>/
#                   Results land in <out>/<model>/ (full) or
#                   <out>/<model>/<case>/ (changed: one invocation per case).
#   --case          shell glob on case names, applied after selection.
#   --plugin-dir    plugin under test, default: this repo. Its evals/ must hold
#                   the same cases (release-check.sh copies them in).
#
# Environment:
#   MYSPEC_EVALS_STRICT=1          exit 1 when a case scores below threshold (default: report only)
#   MYSPEC_EVAL_THRESHOLD          case score threshold, default 0.8
#   MYSPEC_EVAL_MAX_COST_USD       cumulative cost ceiling for this whole call, default 2 (changed) / 20 (full);
#                                  no invocation starts once it is spent, each gets the remainder as --max-cost-usd
#   MYSPEC_EVAL_DEADLINE_SECONDS   stop launching and kill in-flight invocations after this many seconds (default: none)
#   MYSPEC_EVAL_CONCURRENCY        parallel runs, default 4
#   MYSPEC_EVAL_ABLATION           none (default) | with-without
#   MYSPEC_EVALS_DRY_RUN=1         print the selection and the commands, run nothing
#   MYSPEC_EVAL_CLAUDE             claude binary, default: claude (tests point it at a stub)
#   MYSPEC_EVAL_PROBE_URL          reachability probe, default $ANTHROPIC_BASE_URL or https://api.anthropic.com
#
# Exit status: 0 ran (report only) · 1 below threshold, only when strict ·
#              2 infrastructure error (claude missing, not logged in, API
#                unreachable, bad ref, cost ceiling or deadline hit, a run
#                that ended in an error, eval exit 2)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVALS_DIR="$REPO_ROOT/evals"
SCRIPT_DIR="$REPO_ROOT/scripts/evals"

die() { echo "evals: $*" >&2; exit 2; }
usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE="" BASE="" OUT="" RUNS="" MODELS="" CASE_GLOB="" PLUGIN_DIR="$REPO_ROOT"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --models) MODELS="${2:-}"; shift 2 ;;
    --case) CASE_GLOB="${2:-}"; shift 2 ;;
    --plugin-dir) PLUGIN_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "evals: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in
  changed) : "${RUNS:=1}" "${MODELS:=sonnet}" ;;
  full) : "${RUNS:=3}" "${MODELS:=sonnet,haiku}" ;;
  *) echo "evals: --mode changed|full is required" >&2; usage >&2; exit 2 ;;
esac
case "$RUNS" in ''|*[!0-9]*) die "--runs must be a positive integer" ;; esac

CLAUDE_BIN="${MYSPEC_EVAL_CLAUDE:-claude}"
THRESHOLD="${MYSPEC_EVAL_THRESHOLD:-0.8}"
CONCURRENCY="${MYSPEC_EVAL_CONCURRENCY:-4}"
ABLATION="${MYSPEC_EVAL_ABLATION:-none}"
if [ "$MODE" = changed ]; then MAX_COST="${MYSPEC_EVAL_MAX_COST_USD:-2}"; else MAX_COST="${MYSPEC_EVAL_MAX_COST_USD:-20}"; fi
DEADLINE="${MYSPEC_EVAL_DEADLINE_SECONDS:-0}"
case "$DEADLINE" in ''|*[!0-9]*) die "MYSPEC_EVAL_DEADLINE_SECONDS must be a whole number of seconds" ;; esac
# Tools beyond the read-only set that some case needs: feature-spec writes
# spec.md (Write, Edit); code-review reads the branch diff (git, read-only verbs).
ALLOW_TOOLS=(Write Edit "Bash(git diff:*)" "Bash(git log:*)" "Bash(git status:*)" "Bash(git show:*)"
  "Bash(git merge-base:*)" "Bash(git rev-parse:*)" "Bash(git branch:*)" "Bash(git symbolic-ref:*)")

# ---------------------------------------------------------------- case index

# All case directories (a directory holding prompt.md or case.yaml).
all_cases() {
  local d
  for d in "$EVALS_DIR"/*/; do
    d="${d%/}"
    [ -f "$d/prompt.md" ] || [ -f "$d/case.yaml" ] || continue
    basename "$d"
  done
}

# skill:<name> tags of one case, one per line.
case_skills() {
  cat "$EVALS_DIR/$1/prompt.md" "$EVALS_DIR/$1/case.yaml" 2>/dev/null \
    | grep -E '^tags:' | grep -oE 'skill:[A-Za-z0-9_-]+' | sed 's/^skill://' | sort -u
}

# ------------------------------------------------------------ changed mode

resolve_base() {
  if [ -n "$BASE" ]; then
    git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die "base ref not found: $BASE"
    echo "$BASE"; return
  fi
  local ref mb
  for ref in origin/main main; do
    if mb=$(git -C "$REPO_ROOT" merge-base "$ref" HEAD 2>/dev/null) && [ -n "$mb" ]; then
      echo "$mb"; return
    fi
  done
  die "cannot find a merge base with origin/main or main; pass --base"
}

# Prints the selected case names, one per line. Rules (evals/README.md):
#   skills/<s>/…, plugins/myspec/skills/<s>/…  → cases tagged skill:<s>
#   skills/_shared/<f>                          → cases tagged with any skill whose
#                                                 files mention _shared/<f> (transitively
#                                                 through other _shared files)
#   evals/<case>/…                              → that case
#   evals/_fixtures/<entry>…                    → cases whose files mention <entry>
select_changed() {
  local base="$1" changed f rest skill entry c
  changed=$(git -C "$REPO_ROOT" diff --name-only "$base" HEAD) || die "git diff $base HEAD failed"
  local skills="" shared="" fixtures="" cases=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rest="${f#plugins/myspec/}"
    case "$rest" in
      skills/_shared/*) shared="$shared ${rest#skills/_shared/}" ;;
      skills/*/*) skill="${rest#skills/}"; skills="$skills ${skill%%/*}" ;;
    esac
    case "$f" in
      evals/_fixtures/*) entry="${f#evals/_fixtures/}"; fixtures="$fixtures ${entry%%/*}" ;;
      evals/*/*) c="${f#evals/}"; c="${c%%/*}"; cases="$cases $c" ;;
    esac
  done <<< "$changed"

  # _shared closure: a _shared file that references a changed one is changed too.
  if [ -n "$shared" ]; then
    local grew=1 s g
    while [ "$grew" = 1 ]; do
      grew=0
      for g in "$REPO_ROOT"/skills/_shared/*; do
        [ -f "$g" ] || continue
        case " $shared " in *" $(basename "$g") "*) continue ;; esac
        for s in $shared; do
          if grep -qF "_shared/$s" "$g" || grep -qF "($s)" "$g" || grep -qF "./$s" "$g"; then
            shared="$shared $(basename "$g")"; grew=1; break
          fi
        done
      done
    done
    local sd
    for sd in "$REPO_ROOT"/skills/*/; do
      sd="${sd%/}"
      [ "$(basename "$sd")" = _shared ] && continue
      for s in $shared; do
        if grep -rqF "_shared/$s" "$sd"; then skills="$skills $(basename "$sd")"; break; fi
      done
    done
  fi

  local name sk hit
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    hit=""
    case " $cases " in *" $name "*) hit=1 ;; esac
    if [ -z "$hit" ] && [ -n "$skills" ]; then
      for sk in $(case_skills "$name"); do
        case " $skills " in *" $sk "*) hit=1; break ;; esac
      done
    fi
    if [ -z "$hit" ] && [ -n "$fixtures" ]; then
      for entry in $fixtures; do
        if grep -rqF -- "$entry" "$EVALS_DIR/$name"; then hit=1; break; fi
      done
    fi
    if [ -n "$hit" ]; then echo "$name"; fi
  done <<< "$(all_cases)"
  return 0
}

# ------------------------------------------------------------------ running

preflight() {
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "$CLAUDE_BIN is not on PATH; install Claude Code or skip with MYSPEC_SKIP_EVALS=1"
  command -v node >/dev/null 2>&1 || die "node is not on PATH (needed for the summary)"
  local status
  # perl alarm: a portable timeout, so a wedged auth check cannot hang a git hook.
  status=$(perl -e 'alarm shift; exec @ARGV' 20 "$CLAUDE_BIN" auth status --json 2>/dev/null) \
    || die "claude auth status failed or timed out; run: claude auth login"
  printf '%s' "$status" | grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*true' \
    || die "claude is not logged in; run: claude auth login"
  # `auth status` reads local state only, so it passes offline. Without this
  # probe every run would start, fail with "Connection refused" after its
  # retries, and cost minutes before reporting.
  local probe="${MYSPEC_EVAL_PROBE_URL:-${ANTHROPIC_BASE_URL:-https://api.anthropic.com}}" err
  if command -v curl >/dev/null 2>&1; then
    err=$(curl -sS -o /dev/null --max-time 8 "$probe" 2>&1) \
      || die "cannot reach $probe (offline, or proxy down): ${err:-curl failed}"
  fi
}

# Cost so far: agent runs plus judge calls, every arm, every finished invocation.
spent_usd() {
  node -e '
    const fs = require("fs"), path = require("path");
    let t = 0;
    const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === "aggregate-result.json") {
        try { for (const c of JSON.parse(fs.readFileSync(p, "utf8")).cases ?? [])
          for (const r of Object.values(c.arms ?? {}).flat()) t += (r.costUsd ?? 0) + (r.judgeCostUsd ?? 0);
        } catch {}
      } } };
    walk(process.argv[1]);
    console.log(t.toFixed(4));' "$OUT"
}

# run_eval <output-dir> <model> <max-cost> [--case <glob>] — one `claude plugin eval` invocation.
# Echoes the eval's exit code to <output-dir>/exit-code.
run_eval() {
  local outdir="$1" model="$2" cost="$3"; shift 3
  mkdir -p "$outdir"
  local cmd=("$CLAUDE_BIN" plugin eval "$PLUGIN_DIR"
    --trust-plugin --scaffold --no-publish
    --model "$model" --judge-model sonnet
    --runs "$RUNS" --ablation "$ABLATION" --threshold "$THRESHOLD"
    --concurrency "$CONCURRENCY" --max-cost-usd "$cost"
    --output-dir "$outdir" --report "$outdir/report.html"
    "$@"
    --allow-tools "${ALLOW_TOOLS[@]}")
  if [ "${MYSPEC_EVALS_DRY_RUN:-0}" = 1 ]; then
    printf 'dry-run:'; printf ' %q' "${cmd[@]}"; printf '\n'
    echo 0 > "$outdir/exit-code"
    return 0
  fi
  "${cmd[@]}" < /dev/null > "$outdir/eval.log" 2>&1
  echo $? > "$outdir/exit-code"
}

# Map one invocation's exit code to ours: 0 fine, 1 below threshold, 2 infra.
classify() {
  local outdir="$1" rc
  rc=$(cat "$outdir/exit-code" 2>/dev/null || echo 2)
  case "$rc" in
    0) echo 0 ;;
    # Exit 1 also covers a case file that failed to load, no cases found,
    # an untrusted directory or a bad option; only a written, loadable
    # result means "below threshold".
    1) if [ -f "$outdir/aggregate-result.json" ] \
          && ! grep -qiE 'failed to load|no eval cases found|not a trusted|unknown option|invalid' "$outdir/eval.log" 2>/dev/null; then
         echo 1
       else
         echo 2
       fi ;;
    *) echo 2 ;;
  esac
}

# ------------------------------------------------------------------ main

cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

if [ "$MODE" = changed ]; then
  base=$(resolve_base) || exit 2
  selected=$(select_changed "$base") || exit 2
else
  selected=$(all_cases)
fi
if [ -n "$CASE_GLOB" ]; then
  filtered=""
  while IFS= read -r c; do
    # shellcheck disable=SC2053 # the glob is intentional
    [ -n "$c" ] && [[ "$c" == $CASE_GLOB ]] && filtered="$filtered$c"$'\n'
  done <<< "$selected"
  selected="${filtered%$'\n'}"
fi

if [ -z "$selected" ]; then
  if [ "$MODE" = changed ]; then
    echo "evals: no eval cases cover the skills changed since ${base:0:12}; nothing to run."
  else
    echo "evals: no eval cases match${CASE_GLOB:+ --case $CASE_GLOB}; nothing to run."
  fi
  exit 0
fi

n=$(printf '%s\n' "$selected" | grep -c .)
echo "evals: mode=$MODE runs=$RUNS models=$MODELS ablation=$ABLATION cases=$n${base:+ base=${base:0:12}}"
printf '  %s\n' $selected

if [ "${MYSPEC_EVALS_DRY_RUN:-0}" != 1 ]; then preflight; fi

# The pid suffix keeps two runs started in the same second apart.
[ -n "$OUT" ] || OUT="$REPO_ROOT/.eval-results/$(date -u +%Y%m%dT%H%M%SZ)-$MODE-$$"
mkdir -p "$OUT" || die "cannot create $OUT"
echo "evals: results in $OUT"

worst=0
note() { if [ "$1" -gt "$worst" ]; then worst="$1"; fi; }

# Jobs, one per line: <output-dir>|<model>|<case glob or empty>.
# `claude plugin eval --case` takes one glob, so --mode changed runs one
# invocation per case, $CONCURRENCY at a time; --mode full runs one
# invocation per model, one after the other (each parallelises its own runs).
jobs_list=""
IFS=',' read -r -a model_list <<< "$MODELS"
for model in "${model_list[@]}"; do
  [ -n "$model" ] || continue
  if [ "$MODE" = full ]; then
    jobs_list="$jobs_list$OUT/$model|$model|$CASE_GLOB"$'\n'
  else
    while IFS= read -r c; do
      [ -n "$c" ] && jobs_list="$jobs_list$OUT/$model/$c|$model|$c"$'\n'
    done <<< "$selected"
  fi
done
if [ "$MODE" = full ]; then slots=1; else slots="$CONCURRENCY"; fi

started=$(date +%s)
running=""   # "pid:outdir pid:outdir …"
stopped=""   # why no further invocation was launched
launched=0
total=$(printf '%s' "$jobs_list" | grep -c .)
while :; do
  still=""
  for entry in $running; do
    if kill -0 "${entry%%:*}" 2>/dev/null; then still="$still $entry"; else wait "${entry%%:*}" 2>/dev/null; fi
  done
  running="$still"
  if [ "$DEADLINE" -gt 0 ] && [ $(( $(date +%s) - started )) -ge "$DEADLINE" ] && [ -z "$stopped" ]; then
    stopped="deadline of ${DEADLINE}s reached"
    for entry in $running; do
      pkill -TERM -P "${entry%%:*}" 2>/dev/null; kill -TERM "${entry%%:*}" 2>/dev/null
      echo 143 > "${entry#*:}/exit-code" 2>/dev/null
    done
    for entry in $running; do wait "${entry%%:*}" 2>/dev/null; done
    running=""
  fi
  n_running=$(printf '%s' "$running" | wc -w | tr -d ' ')
  while [ -z "$stopped" ] && [ "$launched" -lt "$total" ] && [ "$n_running" -lt "$slots" ]; do
    if [ "${MYSPEC_EVALS_DRY_RUN:-0}" = 1 ]; then left="$MAX_COST"; else
      left=$(LC_ALL=C awk -v cap="$MAX_COST" -v s="$(spent_usd)" 'BEGIN { printf "%.4f", cap - s }')
    fi
    if LC_ALL=C awk -v l="$left" 'BEGIN { exit !(l <= 0) }'; then stopped="cost ceiling \$$MAX_COST reached"; break; fi
    job=$(printf '%s' "$jobs_list" | sed -n "$((launched + 1))p")
    IFS='|' read -r j_out j_model j_case <<< "$job"
    run_eval "$j_out" "$j_model" "$left" ${j_case:+--case "$j_case"} &
    running="$running $!:$j_out"
    launched=$((launched + 1)); n_running=$((n_running + 1))
  done
  if [ -z "$running" ] && { [ -n "$stopped" ] || [ "$launched" -ge "$total" ]; }; then break; fi
  sleep 1
done
if [ -n "$stopped" ]; then
  echo "evals: $stopped; $((total - launched)) of $total invocation(s) not started, in-flight ones stopped" >&2
  note 2
fi
while IFS='|' read -r j_out _ _; do
  [ -n "$j_out" ] && [ -f "$j_out/exit-code" ] && note "$(classify "$j_out")"
done <<< "$jobs_list"

if [ "${MYSPEC_EVALS_DRY_RUN:-0}" = 1 ]; then exit 0; fi

node "$SCRIPT_DIR/summary.mjs" "$OUT" "$THRESHOLD"
note "$?"

for f in $(find "$OUT" -name exit-code 2>/dev/null); do
  rc=$(cat "$f")
  if [ "$rc" != 0 ] && [ "$(classify "$(dirname "$f")")" = 2 ]; then
    echo "evals: claude plugin eval exited $rc in ${f%/exit-code}; last lines of its log:" >&2
    grep -viE 'licen[cs]e' "$(dirname "$f")/eval.log" 2>/dev/null | tail -5 >&2
  fi
done

case "$worst" in
  0) exit 0 ;;
  1) if [ "${MYSPEC_EVALS_STRICT:-0}" = 1 ]; then
       echo "evals: below threshold $THRESHOLD (MYSPEC_EVALS_STRICT=1)" >&2; exit 1
     fi
     echo "evals: below threshold $THRESHOLD; report only (set MYSPEC_EVALS_STRICT=1 to fail)"; exit 0 ;;
  *) echo "evals: infrastructure error; scores above are not a verdict on the plugin" >&2; exit 2 ;;
esac
