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
#
# Environment:
#   MYSPEC_EVALS_STRICT=1          exit 1 when a case scores below threshold (default: report only)
#   MYSPEC_EVAL_THRESHOLD          case score threshold, default 0.8
#   MYSPEC_EVAL_MAX_COST_USD       cost ceiling per claude invocation; default 2 (changed, per case) / 20 (full, per model)
#   MYSPEC_EVAL_CONCURRENCY        parallel runs, default 4
#   MYSPEC_EVAL_ABLATION           none (default) | with-without
#   MYSPEC_EVALS_DRY_RUN=1         print the selection and the commands, run nothing
#   MYSPEC_EVAL_CLAUDE             claude binary, default: claude (tests point it at a stub)
#
# Exit status: 0 ran (report only) · 1 below threshold, only when strict ·
#              2 infrastructure error (claude missing, not logged in, bad ref,
#                cost ceiling hit, usage limit, eval exit 2)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVALS_DIR="$REPO_ROOT/evals"
SCRIPT_DIR="$REPO_ROOT/scripts/evals"

die() { echo "evals: $*" >&2; exit 2; }
usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE="" BASE="" OUT="" RUNS="" MODELS="" CASE_GLOB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --models) MODELS="${2:-}"; shift 2 ;;
    --case) CASE_GLOB="${2:-}"; shift 2 ;;
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
}

# run_eval <output-dir> <model> [--case <glob>] — one `claude plugin eval` invocation.
# Echoes the eval's exit code to <output-dir>/exit-code.
run_eval() {
  local outdir="$1" model="$2"; shift 2
  mkdir -p "$outdir"
  local cmd=("$CLAUDE_BIN" plugin eval "$REPO_ROOT"
    --trust-plugin --scaffold --no-publish
    --model "$model" --judge-model sonnet
    --runs "$RUNS" --ablation "$ABLATION" --threshold "$THRESHOLD"
    --concurrency "$CONCURRENCY" --max-cost-usd "$MAX_COST"
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

[ -n "$OUT" ] || OUT="$REPO_ROOT/.eval-results/$(date -u +%Y%m%dT%H%M%SZ)-$MODE"
mkdir -p "$OUT" || die "cannot create $OUT"
echo "evals: results in $OUT"

worst=0
note() { [ "$1" -gt "$worst" ] && worst="$1"; }

IFS=',' read -r -a model_list <<< "$MODELS"
for model in "${model_list[@]}"; do
  [ -n "$model" ] || continue
  if [ "$MODE" = full ]; then
    run_eval "$OUT/$model" "$model" ${CASE_GLOB:+--case "$CASE_GLOB"}
    note "$(classify "$OUT/$model")"
  else
    # `claude plugin eval --case` takes one glob, so a selection of several
    # cases runs as one invocation per case, up to $CONCURRENCY at a time.
    pids=()
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      run_eval "$OUT/$model/$c" "$model" --case "$c" &
      pids+=($!)
      if [ "${#pids[@]}" -ge "$CONCURRENCY" ]; then wait "${pids[0]}"; pids=("${pids[@]:1}"); fi
    done <<< "$selected"
    wait
    while IFS= read -r c; do
      [ -n "$c" ] && note "$(classify "$OUT/$model/$c")"
    done <<< "$selected"
  fi
done

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
