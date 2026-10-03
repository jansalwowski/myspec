#!/usr/bin/env bash
# Function tests for lib/stop-gate/run.sh: the caps, the container-exec
# forms, `cwd`, `paths` and `runIn` verdicts, loading checks through the
# settings reader, and the capped runner with its cleanup
# (docs/stop-gate.md, R5, R7, R8a, R11, R12; docs/verify-check-escapes.md).
# The module is sourced and its functions called on small fixtures; the
# end-to-end paths stay in hooks/tests/verify-before-stop*.test.sh.
#
# Usage: stop-gate-run.test.sh [path-to-lib]

set -uo pipefail

LIB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/session-event.sh
. "$LIB/session-event.sh"
# shellcheck source=lib/stop-gate/arm.sh
. "$LIB/stop-gate/arm.sh"
# shellcheck source=lib/stop-gate/run.sh
. "$LIB/stop-gate/run.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
RAN="$ROOT/ran"
PIDS="$ROOT/pids"
mkdir -p "$PIDS"
trap 'for p in "$PIDS"/*; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done; rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) fail "$3 (no '$2' in: $1)" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3 ('$2' in: $1)" ;; *) ok ;; esac; }
alive() { [ -f "$PIDS/$1" ] && kill -0 "$(cat "$PIDS/$1")" 2>/dev/null; }

git_() { git -c user.email=t@t -c user.name=t "$@"; }
REPO="$ROOT/app"
mkdir -p "$REPO/.claude" "$REPO/api" "$REPO/web"
git_ init -q -b main "$REPO"
printf '.claude/worktrees/\n.claude/state/\n' > "$REPO/.gitignore"
printf '<?php\n' > "$REPO/api/a.php"
printf 'export {}\n' > "$REPO/web/a.ts"
printf '{"checks":[]}\n' > "$REPO/.claude/verification.json"
git_ -C "$REPO" add -A
git_ -C "$REPO" commit -q -m init
NESTED="$REPO/.claude/worktrees/nested"
git_ -C "$REPO" worktree add -q -b feat-nested "$NESTED" main
OUTSIDE="$ROOT/outside-wt"
git_ -C "$REPO" worktree add -q -b feat-outside "$OUTSIDE" main

# --- caps (R7) --------------------------------------------------------------------
caps() { (MYSPEC_CHECK_CAP_SECONDS="$1" run_init; printf '%s/%s' "$CHECK_CAP_SECONDS" "$CLEANUP_CAP_SECONDS"; rm -f "$CAP_SENTINEL"); }
eq "$(caps '')" 120/30 "the default caps"
eq "$(caps 5)" 5/5 "a lower check cap lowers the cleanup cap with it"
eq "$(caps 60)" 60/30 "the cleanup cap is never above 30 s"
eq "$(caps 500)" 120/30 "the variable cannot raise the cap"
eq "$(caps abc)" 120/30 "a non-number is ignored"
eq "$(caps 0)" 120/30 "zero is ignored"

# --- the gate budget (R13) ---------------------------------------------------------------
budget() { (unset GATE_DEADLINE; MYSPEC_GATE_BUDGET_SECONDS="$1" gate_budget_init; printf '%s' "$GATE_BUDGET_SECONDS"); }
eq "$(budget '')" 300 "the default budget"
eq "$(budget 40)" 40 "a lower budget is honoured"
eq "$(budget 301)" 300 "the variable cannot raise the budget"
eq "$(budget 100000)" 300 "nor raise it by much"
eq "$(budget -5)" 300 "a negative value is ignored"
eq "$(budget 0)" 300 "zero is ignored"
eq "$( (GATE_DEADLINE=$(( $(date +%s) - 10 )); gate_remaining) )" 0 "a spent budget has 0 s left"
eq "$( (GATE_DEADLINE=$(( $(date +%s) + 60 )); gate_remaining) )" 60 "the seconds left"

# --- container_exec_form (R8a) ----------------------------------------------------------
for c in "docker exec app make lint" \
         "docker container exec app make lint" \
         "docker compose exec svc make lint" \
         "docker-compose -f compose.yaml exec svc make lint" \
         "podman exec app make lint" \
         "podman container exec app make lint" \
         "podman compose exec svc make lint" \
         "podman-compose exec svc make lint" \
         "docker  compose   exec svc make lint" \
         "docker --context ci compose -p app exec svc make lint" \
         "docker compose exec -w /srv/wt svc make lint" \
         "true && docker compose exec -T svc make lint" \
         "sh -c 'docker exec app make lint'" \
         "env /usr/local/bin/docker exec app make lint"; do
  container_exec_form "$c" && ok || fail "exec form: '$c' is a container exec"
done
for c in "docker run --rm -v .:/srv img make lint" \
         "docker container ls" \
         "docker compose ps" \
         "docker compose run --rm svc make lint" \
         "docker compose run svc sh -c exec" \
         "echo mydocker exec"; do
  container_exec_form "$c" && fail "exec form: '$c' is not a container exec" || ok
done

# --- check_cwd ----------------------------------------------------------------------------
cwd_of() { check_cwd "$1"; printf '%s|%s' "$CHECK_CWD" "$CWD_IGNORED"; }
eq "$(cwd_of '{}')" "|" "no cwd: the root"
eq "$(cwd_of '{"cwd":"api"}')" "api|" "a relative cwd"
eq "$(cwd_of '{"cwd":"./web/"}')" "web|" "./ and a trailing / are dropped"
eq "$(cwd_of '{"cwd":"."}')" "|" ". is the root"
for bad in '"/tmp"' '"../app"' '"api/../.."' '""' '3'; do
  eq "$(cwd_of "{\"cwd\":$bad}")" "|$bad" "cwd $bad is ignored and named"
done

# --- paths_verdict (R11) ----------------------------------------------------------------------
REPO_ROOT="$REPO"
MYSPEC_BASE_REF=""
# verdict <glob json list> <session file> -> PATHS_VERDICT, with git's view empty.
verdict() {
  MYSPEC_SESSION_FILES="$2" UNSEEN_READY=1 UNSEEN_FILES=""
  paths_verdict "{\"paths\":$1}"
  printf '%s' "$PATHS_VERDICT"
}
glob_case() {  # glob_case <glob> <path> <run|skip> <desc>
  eq "$(verdict "$(jq -nc --arg g "$1" '[$g]')" "$2")" "$3" "glob '$1' vs '$2': $4"
}
glob_case 'api/**' api/a.php run "** under a directory"
glob_case 'api/**' api/v1/deep/a.php run "** spans segments"
glob_case 'api/**' apix/a.php skip "a directory prefix is a whole segment"
glob_case 'api/' api/v1/a.php run "a trailing / is everything under it"
glob_case '**/*.php' a.php run "**/ matches zero segments"
glob_case '**/*.php' api/v1/a.php run "**/ matches several segments"
glob_case '*.php' api/a.php skip "* stays within one segment and the glob is anchored at the root"
glob_case '*.php' a.php run "* at the root"
glob_case 'api/*/a.php' api/v1/a.php run "* is one segment"
glob_case 'api/*/a.php' api/v1/v2/a.php skip "* is not two segments"
glob_case 'a/**/b.ts' a/b.ts run "a/**/b matches a/b"
glob_case 'a/**/b.ts' a/x/y/b.ts run "a/**/b matches deeper"
glob_case 'src/?.go' src/a.go run "? is one character"
glob_case 'src/?.go' src/ab.go skip "? is not two characters"
glob_case './web/**' web/a.ts run "a leading ./ is dropped"
glob_case 'web/a.ts' web/axts skip ". is literal"
glob_case 'web/[ab].ts' web/a.ts skip "[ is literal, not a class"
glob_case 'web/[ab].ts' 'web/[ab].ts' run "[ matches itself"
glob_case 'a**b/x' azzb/x run "** inside a segment is a plain *"
glob_case 'a**b/x' a/b/x skip "** inside a segment does not cross /"
eq "$(verdict '["api/**","web/**"]' "$(printf 'docs/x.md\nweb/tsconfig.json')")" run "any glob, any written file (a non-code one included)"
for bad in '"api/**"' '[]' '["/abs/**"]' '["../api/**"]' '[""]' '[1]'; do
  eq "$(verdict "$bad" web/a.ts)" ignored "paths $bad is unusable"
done
MYSPEC_SESSION_FILES="" UNSEEN_READY=1 UNSEEN_FILES=""
paths_verdict '{"name":"x"}'
eq "$PATHS_VERDICT" run "no paths: the check runs"

# Changes the ledger cannot see run the check: git's view of the checkout.
unseen_verdict() {  # unseen_verdict <root> -> the verdict of api/** with only web/a.ts written
  REPO_ROOT="$1"
  base_ref
  MYSPEC_SESSION_FILES=web/a.ts UNSEEN_READY=0
  paths_verdict '{"paths":["api/**"]}'
  printf '%s' "$PATHS_VERDICT"
}
U="$REPO/.claude/worktrees/unseen"
git_ -C "$REPO" worktree add -q -b feat-unseen "$U" main
eq "$(unseen_verdict "$U")" skip "unseen: a clean api/ skips"
rm "$U/api/a.php"
eq "$(unseen_verdict "$U")" run "unseen: an rm the ledger lacks runs the check"
git_ -C "$U" checkout -q -- api/a.php
printf '<?php // gen\n' > "$U/api/gen.php"
eq "$(unseen_verdict "$U")" run "unseen: an untracked file (codegen) runs the check"
rm "$U/api/gen.php"
printf '<?php // v2\n' > "$U/api/a.php"
git_ -C "$U" commit -q -am "api change"
eq "$(unseen_verdict "$U")" run "unseen: a commit against the base (git revert) runs the check"

# --- check_workdir and main_checkout (R12) -------------------------------------------------------
CONTAINERS_JSON='{"app":{"mountSource":".","mountTarget":"/var/www/html"},"apionly":{"mountSource":"./api/","mountTarget":"/srv/api/"}}'
CONTAINERS_NOTES=""
workdir() {  # workdir <root> <container> [cwd] -> the workdir, or "refused: <reason>"
  if check_workdir "$1" "$2" "${3:-}"; then printf '%s' "$CHECK_WORKDIR"; else printf 'refused: %s' "$REFUSE_REASON"; fi
}
eq "$(workdir "$REPO" app)" /var/www/html "main checkout: mountTarget"
eq "$(workdir "$REPO" apionly)" /srv/api "main checkout: a subdirectory mount is its own mountTarget"
eq "$(workdir "$NESTED" app)" /var/www/html/.claude/worktrees/nested "nested worktree: its path under the mount"
has "$(workdir "$NESTED" apionly)" "this worktree is not visible inside the container" "nested worktree outside an api/ mount is refused"
has "$(workdir "$OUTSIDE" app)" "this worktree is not visible inside the container" "a worktree outside mountSource is refused"
# shellcheck disable=SC2016 # backticks in the expected message
has "$(workdir "$REPO" nope)" 'runIn names container "nope", which `containers`' "an undefined container is refused"
eq "$(workdir "$NESTED" app api)" /var/www/html/.claude/worktrees/nested/api "cwd: the workdir includes it"
eq "$(workdir "$REPO" apionly api/sub)" /srv/api/sub "cwd: relative to a subdirectory mount"
has "$(workdir "$REPO" apionly web)" 'cwd "web" is not under mountSource' "cwd outside mountSource is refused"
for spec in '{"mountSource":"."}' '{"mountSource":".","mountTarget":"srv"}' '{"mountSource":"../x","mountTarget":"/srv"}' '{"mountTarget":"/srv"}' '"x"'; do
  CONTAINERS_JSON="{\"app\":$spec}"
  has "$(workdir "$REPO" app)" "refused: container \"app\" needs mount" "container $spec is refused"
done

# --- run_checks: the per-check order and its messages --------------------------------------------
N=0
# gate <root> <checks json> [kind:rel...] -> a JSON summary of one run_checks
# over <root>, each argument a write event of a new session. Env reaches it;
# GATE_HOME names the checkout holding the state file (default: REPO).
gate() {
  local root="$1" cfg="$2" a
  shift 2
  N=$((N + 1))
  SESSION_ID="run-$N"
  rm -rf "$RAN" && mkdir -p "$RAN"
  for a in "$@"; do
    session_append "${GATE_HOME:-$REPO}" "$SESSION_ID" "$(jq -nc --arg r "$root" --arg k "${a%%:*}" --arg p "${a#*:}" '{t: "write", root: $r, rel: $p, kind: $k}')"
  done
  printf '%s\n' "$cfg" > "$root/.claude/verification.json"
  (
    arm_init "${GATE_HOME:-$REPO}"
    arm_root "$root"
    run_init
    trap run_cleanup_files EXIT
    run_checks "$root/.claude/verification.json"
    jq -n --arg ran "$CHECKS_RAN" \
      --argjson failed "$(jq -nc '$ARGS.positional' --args ${FAILED_CHECKS[@]+"${FAILED_CHECKS[@]}"})" \
      --argjson timed "$(jq -nc '$ARGS.positional' --args ${TIMED_OUT_CHECKS[@]+"${TIMED_OUT_CHECKS[@]}"})" \
      --argjson unver "$(jq -nc '$ARGS.positional' --args ${UNVERIFIABLE_CHECKS[@]+"${UNVERIFIABLE_CHECKS[@]}"})" \
      --argjson output "$(jq -nc '$ARGS.positional' --args ${FAILED_OUTPUT[@]+"${FAILED_OUTPUT[@]}"})" \
      --argjson scope "$(jq -nc '$ARGS.positional' --args ${SCOPE_NOTES[@]+"${SCOPE_NOTES[@]}"})" \
      --argjson notrun "$(jq -nc '$ARGS.positional' --args ${NOT_RUN_CHECKS[@]+"${NOT_RUN_CHECKS[@]}"})" \
      '{ran: ($ran | tonumber), failed: $failed, timed: $timed, unver: $unver, notrun: $notrun, output: ($output | join("\n---\n")), scope: ($scope | join(" "))}'
  )
}
check() {  # check <name> <command> [extra json] -> a required check that records its run
  local x="${3:-}"
  [ -n "$x" ] || x='{}'
  jq -nc --arg n "$1" --arg c "echo ran > $RAN/$1; $2" --argjson x "$x" '{name: $n, command: $c, required: true} + $x'
}
ran() { [ -f "$RAN/$1" ] && printf yes || printf no; }
f() { printf '%s' "$1" | jq -r "$2"; }

out=$(gate "$REPO" "{\"checks\":[$(check Api true '{"paths":["api/**"]}'),$(check Web true '{"paths":["web/**"]}'),{\"name\":\"Opt\",\"command\":\"true\",\"required\":false,\"paths\":[\"web/**\"]}]}" code:api/a.php)
eq "$(ran Api)$(ran Web)" yesno "paths: the matching check runs, the other is skipped"
has "$(f "$out" .scope)" "Web: skipped, no file this session wrote matches its paths (web/**)" "paths: the skip is named with its globs"
lacks "$(f "$out" .scope)" "Opt" "a check that is not required is neither run nor reported"
out=$(gate "$REPO" "{\"checks\":[$(check B true '{"paths":[1]}')]}" code:web/a.ts)
eq "$(ran B)" yes "paths unusable: the check runs"
has "$(f "$out" .scope)" "B: its paths setting was ignored" "paths unusable: the message names it"

out=$(gate "$NESTED" "{\"checks\":[$(check C 'pwd -P > '"$RAN"'/C.pwd' '{"cwd":"api"}'),$(check D 'pwd -P > '"$RAN"'/D.pwd' '{"cwd":"/tmp"}')]}" code:api/a.php)
eq "$(cat "$RAN/C.pwd")" "$NESTED/api" "cwd: under the verified checkout, not the main one"
eq "$(cat "$RAN/D.pwd")" "$NESTED" "cwd unusable: the check runs from the root"
has "$(f "$out" .scope)" ": its cwd setting was ignored, so the check ran from the checkout root" "cwd unusable: the message names it"

# diffCommand (R5): used when a base ref resolved, the whole-repo command otherwise.
DIFF=$(jq -nc --arg r "$RAN" '{name: "L", command: "echo whole > \($r)/L", diffCommand: "echo \"diff $MYSPEC_BASE_REF\" > \($r)/L", required: true}')
gate "$NESTED" "{\"checks\":[$DIFF]}" code:api/a.php >/dev/null
eq "$(cat "$RAN/L")" "diff $(git -C "$NESTED" merge-base HEAD main)" "diffCommand runs against MYSPEC_BASE_REF"
NOBASE="$ROOT/nobase"
mkdir -p "$NOBASE/.claude"
git_ init -q -b trunk "$NOBASE" && git_ -C "$NOBASE" commit -q --allow-empty -m init
GATE_HOME="$NOBASE" gate "$NOBASE" "{\"checks\":[$DIFF]}" code:a.ts >/dev/null
eq "$(cat "$RAN/L")" "whole" "without a base ref, the whole-repo command runs"

# runIn and the R8a refusal.
CONTAINERS='{"app":{"mountSource":".","mountTarget":"/var/www/html"}}'
mkdir -p "$ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/docker"
chmod +x "$ROOT/bin/docker"
PATH="$ROOT/bin:$PATH"
EXEC="docker compose exec app make lint"
WD="printf '%s' \"\${MYSPEC_CHECK_WORKDIR-unset}\" > $RAN/wd; $EXEC"
out=$(gate "$NESTED" "{\"containers\":$CONTAINERS,\"checks\":[$(check X "$EXEC")]}" code:api/a.php)
eq "$(f "$out" '.unver | join(",")')" "X [in $NESTED]" "linked worktree: an exec without runIn is refused"
has "$(f "$out" .output)" "not run: unverifiable in a linked worktree" "linked worktree: the refusal says why"
eq "$(ran X)" no "linked worktree: the refused check never runs"
out=$(gate "$NESTED" "{\"containers\":$CONTAINERS,\"checks\":[$(check P "$WD" '{"runIn":"app"}')]}" code:api/a.php)
eq "$(ran P)$(cat "$RAN/wd")" "yes/var/www/html/.claude/worktrees/nested" "a runIn check is trusted without -w and gets its workdir"
out=$(MYSPEC_CHECK_WORKDIR=/stale gate "$REPO" "{\"checks\":[$(check Plain "$WD")]}" code:api/a.php)
eq "$(cat "$RAN/wd")" unset "no runIn: MYSPEC_CHECK_WORKDIR is not exported"
out=$(gate "$REPO" "{\"checks\":[$(check Skip true '{"runIn":"nope","paths":["web/**"]}')]}" code:api/a.php)
eq "$(f "$out" '.unver | length')" 0 "paths before runIn: a skipped check is not refused"
out=$(gate "$REPO" "{\"containers\":\"app\",\"checks\":[$(check R "$WD" '{"runIn":"app"}')]}" code:api/a.php)
has "$(f "$out" .output)" "ignoring verification.containers" "containers not an object: the reader's note is in the refusal"
eq "$(ran R)" no "containers not an object: the check never runs"

# The budget in run_checks (R13): a spent budget runs nothing; a short one
# caps the running check at what is left and leaves the rest unrun.
out=$(GATE_DEADLINE=$(( $(date +%s) - 1 )) gate "$REPO" "{\"checks\":[$(check one true),$(check two true)]}" code:a.ts)
eq "$(ran one)$(ran two)" nono "budget spent: no check starts"
eq "$(f "$out" '.notrun | join(",")')" one,two "budget spent: every check is reported not run"
eq "$(f "$out" '.ran')|$(f "$out" '.output')" "0|" "budget spent: nothing ran, nothing failed"
START=$(date +%s)
out=$(MYSPEC_GATE_BUDGET_SECONDS=2 gate "$REPO" "{\"checks\":[$(check slow 'sleep 30'),$(check after true)]}" code:a.ts)
[ $(( $(date +%s) - START )) -lt 8 ] && ok || fail "budget: the running check is capped at what is left"
# What is left is 1 or 2 s, by where the second boundary falls.
has "$(f "$out" '.timed | join(",")')" "slow (at the gate budget, " "budget: the capped check is a timeout at the budget"
has "$(f "$out" .output)" "s, the rest of the gate budget] " "budget: the timeout says the budget cut it"
eq "$(ran after)" no "budget: the next check does not start"
eq "$(f "$out" '.notrun | join(",")')" after "budget: the next check is reported not run"

# --- the capped runner (R7, docs/verify-check-escapes.md) ------------------------------------------
export MYSPEC_CHECK_CAP_SECONDS=1
# shellcheck disable=SC2016 # expanded by the check, not here
out=$(gate "$REPO" "{\"checks\":[$(check env 'printf "%s %s" "$MYSPEC_STOP_HOOK_ACTIVE" "$MYSPEC_CHECK_RUN_ID" > '"$RAN"'/env')]}" code:a.ts)
has "$(cat "$RAN/env")" "1 myspec-" "the check sees MYSPEC_STOP_HOOK_ACTIVE and its MYSPEC_CHECK_RUN_ID"

# A cap well above the run: an exit 124 at the cap's second would be
# ambiguous without perl (capped).
out=$(MYSPEC_CHECK_CAP_SECONDS=5 gate "$REPO" "{\"checks\":[$(check red 'echo boom; exit 124')]}" code:a.ts)
eq "$(f "$out" '.failed | join(",")')$(f "$out" '.timed | length')" red0 "a fast exit 124 is a failure, not a timeout"

out=$(gate "$REPO" '{"checks":[{"name":"long","command":"head -c 5000 /dev/zero | tr \"\\\\0\" x; echo; echo TAIL-MARKER; exit 1","required":true}]}' code:a.ts)
has "$(f "$out" .output)" TAIL-MARKER "long output keeps its last line"

START=$(date +%s)
out=$(gate "$REPO" "{\"checks\":[$(check leaky "sh -c 'echo \$\$ > $PIDS/leftover; exec sleep 30' & echo done")]}" code:a.ts)
[ $(( $(date +%s) - START )) -lt 6 ] && ok || fail "a passing check's leftover child does not hold the run"
eq "$(f "$out" '.failed | length')" 0 "a passing check that leaves a child still passes"
sleep 1
alive leftover && fail "a passing check's leftover child is killed" || ok

START=$(date +%s)
out=$(gate "$REPO" "{\"checks\":[$(check detached "perl -MPOSIX -e 'setsid; open(my \$f, q(>), q($PIDS/detached)); print \$f \$\$; close \$f; exec q(sleep), 30' & wait")]}" code:a.ts)
[ $(( $(date +%s) - START )) -lt 8 ] && ok || fail "a grandchild outside the group does not hold the run"
eq "$(f "$out" '.timed | join(",")')" detached "the detached check times out"
has "$(f "$out" .output)" "No cleanup declared" "a timeout without cleanup says what may still run"

out=$(gate "$REPO" '{"checks":[{"name":"remote","command":"sleep 30","cleanup":"echo cleanup-said-no; exit 3","required":true}]}' code:a.ts)
has "$(f "$out" .output)" "Cleanup failed (exit 3)" "a failing cleanup is reported with its exit code"
has "$(f "$out" .output)" "cleanup-said-no" "a failing cleanup's output is shown"
START=$(date +%s)
out=$(gate "$REPO" '{"checks":[{"name":"remote","command":"sleep 30","cleanup":"sleep 30","required":true}]}' code:a.ts)
has "$(f "$out" .output)" "Cleanup timed out after 1s" "a slow cleanup is capped with the check cap"
[ $(( $(date +%s) - START )) -lt 10 ] && ok || fail "the cleanup cap bounds the wait"

rm -f "$ROOT/cleanup.ran"
gate "$REPO" "{\"checks\":[{\"name\":\"red\",\"command\":\"exit 1\",\"cleanup\":\"touch $ROOT/cleanup.ran\",\"required\":true},{\"name\":\"green\",\"command\":\"true\",\"cleanup\":\"touch $ROOT/cleanup.ran\",\"required\":true}]}" code:a.ts >/dev/null
[ -e "$ROOT/cleanup.ran" ] && fail "cleanup does not run for a check that exited on its own" || ok

export MYSPEC_CHECK_CAP_SECONDS=3
out=$(gate "$REPO" "{\"checks\":[{\"name\":\"a\",\"command\":\"perl -MPOSIX -e 'exit 0 if fork; setsid; open(my \$f, q(>), q($PIDS/writer)); print \$f \$\$; close \$f; \$| = 1; for (1 .. 100) { print qq(LEAK-\$_\\\\n); select(undef, undef, undef, 0.1) }'; echo a-ok\",\"required\":true},{\"name\":\"b\",\"command\":\"sleep 1; echo b-own-output; exit 1\",\"required\":true}]}" code:a.ts)
has "$(f "$out" .output)" b-own-output "the failing check's own output is reported"
lacks "$(f "$out" .output)" LEAK "a detached writer from an earlier check does not reach a later check's output"
unset MYSPEC_CHECK_CAP_SECONDS

# Without perl, the GNU timeout fallback also kills a finished check's leftovers.
TIMEOUT_BIN=$(command -v gtimeout || command -v timeout || true)
if [ -n "$TIMEOUT_BIN" ] && "$TIMEOUT_BIN" --version 2>/dev/null | grep -q 'GNU coreutils'; then
  NOPERL="$ROOT/noperl-bin"
  mkdir -p "$NOPERL"
  IFS=: read -ra PATH_DIRS <<< "$PATH"
  for d in "${PATH_DIRS[@]}"; do
    for x in "$d"/*; do
      name=${x##*/}
      case "$name" in perl*) continue ;; esac
      [ -x "$x" ] && [ ! -e "$NOPERL/$name" ] && ln -s "$x" "$NOPERL/$name"
    done
  done
  rm -f "$PIDS/leftover"
  START=$(date +%s)
  out=$(PATH="$NOPERL" MYSPEC_CHECK_CAP_SECONDS=2 gate "$REPO" "{\"checks\":[$(check leaky "sh -c 'echo \$\$ > $PIDS/leftover; exec sleep 30' & echo done")]}" code:a.ts)
  eq "$(f "$out" '.failed | length')" 0 "no-perl: a passing check that leaves a child still passes"
  [ $(( $(date +%s) - START )) -lt 6 ] && ok || fail "no-perl: a leftover child does not hold the run"
  sleep 1
  alive leftover && fail "no-perl: a passing check's leftover child is killed" || ok
else
  printf 'SKIP  no-perl fallback: GNU timeout not installed\n' >&2
fi

printf '\nstop-gate-run: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
