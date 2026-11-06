#!/usr/bin/env bash
# Function tests for lib/stop-gate/attribute.sh, the stop gate's attribution
# rules (docs/stop-gate.md, R4) and the per-checkout block-or-warn decision
# (R6). The module is sourced and its functions called on hand-built check
# results; the end-to-end repros (#198 among them) stay in
# hooks/tests/verify-before-stop-attribution.test.sh.
#
# Usage: stop-gate-attribute.test.sh [path-to-lib]

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
# shellcheck source=lib/stop-gate/attribute.sh
. "$LIB/stop-gate/attribute.sh"
# shellcheck source=lib/stop-gate/report.sh
. "$LIB/stop-gate/report.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
eq() { if [ "$1" = "$2" ]; then ok; else fail "$3 (want '$2', got '$1')"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) fail "$3 (no '$2' in: $1)" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3 ('$2' in: $1)" ;; *) ok ;; esac; }

REPO="$ROOT/checkout"
mkdir -p "$REPO/pkg"
git -c init.defaultBranch=main init -q "$REPO"
for x in app.ts other.ts pkg/other.ts tsconfig.json; do printf 'ok\n' > "$REPO/$x"; done
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init

# --- names_in, join_lines, short_list -----------------------------------------------------
ROOT_KEY="$REPO"
printf 'other.ts\npkg/app.ts\n' > "$ROOT/paths"
names() { printf '%s\n' "$2" > "$ROOT/log"; names_in "$1" "$ROOT/paths" "$ROOT/log" | paste -sd' ' -; }
eq "$(names base 'error in src/deep/other.ts:2:1')" other.ts "base: matched by basename anywhere"
eq "$(names base 'app.ts.')" pkg/app.ts "base: a trailing period is dropped"
eq "$(names full 'other.ts:2:1 error')" other.ts "full: a repo-relative path"
eq "$(names full "$REPO/other.ts:2:1 error")" other.ts "full: an absolute path in this checkout"
eq "$(names full './other.ts')" other.ts "full: a leading ./"
eq "$(names full 'pkg/other.ts:2:1 error')" "" "full: a clean file with the same basename is another file"
eq "$(names full 'nothing here')" "" "full: no path, no match"
names_cwd() { printf '%s\n' "$3" > "$ROOT/log"; names_in "$1" "$ROOT/paths" "$ROOT/log" "$2" | paste -sd' ' -; }
eq "$(names_cwd full pkg 'app.ts:3 error')" pkg/app.ts "full: a path relative to the check's cwd (#255 review)"
eq "$(names_cwd full pkg 'other.ts:3 error')" other.ts "full: a repo-relative path still matches with a cwd"
eq "$(names_cwd full '' 'app.ts:3 error')" "" "full: without a cwd, no prefix is tried"
eq "$(printf 'a\nb\nc\n' | join_lines 2)" "a, b" "join_lines: the first N, comma-joined"
seq 1 2000 > "$ROOT/many"
eq "$(short_list "$ROOT/many" 3)" "1, 2, 3 and 1997 more" "short_list: the rest counted"
seq 1 200000 | join_lines 1 >/dev/null; eq "$?" 0 "join_lines reads all its input (no SIGPIPE)"

# --- attribute_failures (R4) ------------------------------------------------------------------
SESSION_ID=s1
arm_init "$REPO"
REPO_ROOT="$REPO"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"
# results <check>=<output>...: one failed check per argument, from index 0.
results() {
  local a i=0
  run_init
  rm -f "$CAP_SENTINEL"
  attribute_begin
  MYSPEC_SESSION_FILES=$(session_files)
  for a in "$@"; do
    printf '%s\n' "${a#*=}" > "$LOGS/$i"
    FAILED_CHECKS+=("${a%%=*}")
    FAILED_LOGS+=("$LOGS/$i")
    FAILED_CWDS+=("${RESULT_CWD:-}")
    FAILED_KNOWN+=("${RESULT_KNOWN:-}")
    FAILED_OUTPUT+=("[${a%%=*}] failed")
    i=$((i + 1))
  done
}
wrote() { session_append "$REPO" "$SESSION_ID" "$(jq -nc --arg r "$REPO" --arg p "$1" '{t: "write", root: $r, rel: $p, kind: "code"}')"; }
wrote app.ts
printf 'BROKEN\n' >> "$REPO/app.ts"

results lint='app.ts:1 BROKEN'
attribute_failures
eq "$ATTRIBUTION|$ATTRIBUTION_WARN" "|0" "rule 1: every change is the session's, no paragraph, no warning"
# T is the list arm_root exported, not a second read of the state file (#254 review).
# shellcheck disable=SC2317,SC2329 # session_files is called by attribute_failures, if at all
eq "$(session_files() { :; }; attribute_failures; printf '%s|%s' "$ATTRIBUTION" "$ATTRIBUTION_WARN")" "|0" "T comes from MYSPEC_SESSION_FILES, read once"

printf 'BROKEN\n' >> "$REPO/other.ts"
results lint='other.ts:2 BROKEN'
attribute_failures
eq "$ATTRIBUTION_WARN" 1 "rule 3: a failure naming only a foreign file warns"
has "$ATTRIBUTION" "names only files changed outside this session: other.ts" "rule 3: the paragraph names the foreign file"
has "$ATTRIBUTION" "This checkout has uncommitted changes this session did not write (other.ts)" "the paragraph lists F"

results lint='app.ts:1 BROKEN' types='other.ts:2 BROKEN'
attribute_failures
eq "$ATTRIBUTION_WARN" 0 "rule 2: one failure naming the session's file blocks them all"
has "$ATTRIBUTION" "lint names files this session wrote: app.ts" "rule 2: the paragraph says which failure is the session's"

results lint='exit 1'
attribute_failures
eq "$ATTRIBUTION_WARN" 0 "rule 4: a failure that names no file blocks"
has "$ATTRIBUTION" "lint names none of the changed files" "rule 4: and says so"

results lint='pkg/other.ts:2 BROKEN'
attribute_failures
eq "$ATTRIBUTION_WARN" 0 "a clean file with the foreign file's basename is not foreign"

results lint='other.ts:2 BROKEN'
TIMED_OUT_CHECKS+=(slow)
attribute_failures
eq "$ATTRIBUTION_WARN" 0 "a timeout is never downgraded"
results lint='other.ts:2 BROKEN'
UNVERIFIABLE_CHECKS+=(container)
attribute_failures
eq "$ATTRIBUTION_WARN" 0 "a refused check is never downgraded"
results lint='other.ts:2 BROKEN'
NOT_RUN_CHECKS+=(later)
attribute_failures
eq "$ATTRIBUTION_WARN" 0 "R13: a check the budget left unrun is never downgraded"

# A check run from cwd "api" prints api/src/Foo.php as src/Foo.php: a file
# only another session changed there warns, not blocks (#255 review).
mkdir -p "$REPO/api/src"
printf 'BROKEN\n' > "$REPO/api/src/Foo.php"
RESULT_CWD=api results phpcs='FILE: src/Foo.php ERROR'
attribute_failures
eq "$ATTRIBUTION_WARN" 1 "cwd: a failure naming another session's file relative to the cwd warns"
has "$ATTRIBUTION" "phpcs names only files changed outside this session: api/src/Foo.php" "cwd: the paragraph names it repo-relative"
rm -rf "$REPO/api"

mkdir -p "$REPO/.claude/state"
printf 'x\n' > "$REPO/.claude/state/x.ts"
results lint='other.ts:2 BROKEN'
attribute_failures
lacks "$ATTRIBUTION" ".claude/state/x.ts" ".claude/state/ is no one's work (not ignored here, so git lists it)"
rm -f "$REPO/.claude/state/x.ts"

ROOT_KEY="$ROOT/elsewhere" ORIG_ROOT="$REPO"
results lint='exit 1'
REPO_ROOT="$REPO"
attribute_failures
has "$ATTRIBUTION" "The checkout at $ROOT/elsewhere has uncommitted changes" "another checkout is named by its path"
ROOT_KEY="$REPO"

# --- attribute_root (R4, R6) ---------------------------------------------------------------
decide() {  # decide <implement 0|1> <check=output>... -> block|warn|none and the notes
  attribute_init
  IMPLEMENT_ACTIVE="$1"
  shift
  results "$@"
  ROOT_LABEL=""
  attribute_root
  printf '%s|%s|%s' "$BLOCKING_FAILURE" "${WARN_NOTES[*]:-}" "${BLOCK_NOTES[*]:-}"
}
out=$(decide 0)
eq "$out" "0||" "no failure: nothing to report"
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=0; results; NOT_RUN_CHECKS+=(later); ROOT_LABEL=""; attribute_root; printf '%s' "$BLOCKING_FAILURE")
eq "$out" 1 "R13: a checkout whose only problem is an unrun check blocks"
# R13 under R6: a check the budget left unrun did not fail (#257 review).
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=1; results; NOT_RUN_CHECKS+=(later); ROOT_LABEL=""; attribute_root; printf '%s|%s' "$BLOCKING_FAILURE" "${WARN_NOTES[*]}")
has "$out" "0|Checks not run (gate budget) during feature-implement orchestration" "R6: only unrun checks warn as not run"
lacks "$out" "Failing" "R6: only unrun checks are not called failing"
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=1; results; NOT_RUN_CHECKS+=(later); RAN_CHECKS=(); SCOPE_NOTES=(); GATE_BUDGET_SECONDS=300; ROOT_LABEL=""; attribute_root; report_decision)
has "$out" "Verification incomplete (not run, gate budget of 300s spent: later)" "report: only unrun checks headline as incomplete"
lacks "$out" "failing" "report: only unrun checks are not called failing"
out=$(attribute_init; IMPLEMENT_ACTIVE=1; results lint='app.ts:1 BROKEN'; RAN_CHECKS=(lint); SCOPE_NOTES=(); ROOT_LABEL=""; attribute_root; report_decision)
has "$out" "Verification failing (failed: lint)" "report: a real failure still headlines as failing"
out=$(decide 1 lint='app.ts:1 BROKEN')
eq "${out%%|*}" 0 "R6: a live feature-implement run warns"
has "$out" "during feature-implement orchestration" "R6: the warning says why"
out=$(decide 0 lint='other.ts:2 BROKEN')
eq "${out%%|*}" 0 "R4: an all-foreign failure warns"
has "$out" "A worktree per session" "R4: the warning points at isolation"
out=$(decide 0 lint='app.ts:1 BROKEN')
eq "${out%%|*}" 1 "R4: the session's own failure blocks"
has "$out" "names files this session wrote: app.ts" "R4: the block carries the paragraph"

# --- knownFailures (R15, #394) ----------------------------------------------------
# A suite red on the default branch: its failing file is listed, with a reason.
mkdir -p "$REPO/tests/legacy" "$REPO/tests/unit"
for x in tests/legacy/old_test.py tests/legacy/older_test.py tests/unit/new_test.py src.py; do printf 'ok\n' > "$REPO/$x"; done
git -C "$REPO" add tests src.py
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m tests
git -C "$REPO" checkout -q -- other.ts
known() {  # known <glob> <reason> -> one entry line, as run.sh stores it
  printf '%s\t%s\t%s' "$(glob_regex "$1")" "$1" "$2"
}
KNOWN_LEGACY=$(known 'tests/legacy/**' 'red on main, TICKET-1')
kdecide() {  # kdecide <check=output>... -> block flag|warn notes|known notes|block notes
  attribute_init
  IMPLEMENT_ACTIVE=0
  results "$@"
  ROOT_LABEL=""
  attribute_root
  printf '%s|%s|%s|%s' "$BLOCKING_FAILURE" "${WARN_NOTES[*]:-}" "${KNOWN_NOTES[*]:-}" "${BLOCK_NOTES[*]:-}"
}
# The session's only uncommitted change is app.ts: F is empty, so without
# knownFailures rule 1 blocks.
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='FAILED tests/legacy/old_test.py::test_x - AssertionError')
eq "${out%%|*}" 0 "R15: a failure naming only a listed file warns"
has "$out" "tests fails only on its knownFailures: tests/legacy/** (red on main, TICKET-1)" "R15: the warning names the check, the entry and its reason"
has "$out" "lists under knownFailures" "R15: the warning says why it does not block"
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests="FAIL $REPO/tests/legacy/old_test.py")
eq "${out%%|*}" 0 "R15: an absolute path in this checkout is matched repo-relative"
out=$(RESULT_CWD=tests RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='FAIL legacy/old_test.py')
eq "${out%%|*}" 0 "R15: a path relative to the check's cwd is matched as <cwd>/<path>"
out=$(kdecide tests='FAILED tests/legacy/old_test.py::test_x')
eq "${out%%|*}" 1 "R15: without knownFailures the same failure blocks"
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='FAILED tests/legacy/old_test.py::test_x'$'\n''src/app.ts:3 caused by app.ts')
eq "${out%%|*}" 1 "R15: a failure that also names a file this session wrote blocks"
has "$out" "knownFailures not applied, it names files this session wrote: app.ts" "R15: and says why"
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='FAILED tests/legacy/old_test.py::test_x'$'\n''FAILED tests/unit/new_test.py::test_y')
eq "${out%%|*}" 1 "R15: a failure that also names an unlisted file blocks"
has "$out" "it also names files no entry matches: tests/unit/new_test.py" "R15: and names that file"
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='tests/unit/new_test.py .... PASSED'$'\n''FAILED tests/legacy/old_test.py')
eq "${out%%|*}" 1 "R15: a passing file the runner lists blocks too (errs toward blocking)"
has "$out" "it also names files no entry matches: tests/unit/new_test.py" "R15: the passing file is named"
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='FAILED tests/legacy/old_test.py'$'\n''  File "src.py", line 3')
eq "${out%%|*}" 1 "R15: a tracked file in a stack trace is a file outside the entries"
has "$out" "it also names files no entry matches: src.py" "R15: the stack-trace file is named"
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='FAILED legacy/new_test.py')
eq "${out%%|*}" 1 "R15: a file named by a basename outside the entries blocks"
has "$out" "it also names files no entry matches: legacy/new_test.py" "R15: the basename-matched file is named"
out=$(RESULT_KNOWN="$KNOWN_LEGACY" kdecide tests='Segmentation fault')
eq "${out%%|*}" 1 "R15: a failure that names no listed file blocks"
has "$out" "it names no file an entry matches" "R15: and says so"
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=0; RESULT_KNOWN="$KNOWN_LEGACY" results tests='FAILED tests/legacy/old_test.py'; TIMED_OUT_CHECKS+=(slow); ROOT_LABEL=""; attribute_root; printf '%s|%s' "$BLOCKING_FAILURE" "${KNOWN_NOTES[*]:-}")
eq "$out" "1|tests fails only on its knownFailures: tests/legacy/** (red on main, TICKET-1)." "R15: a timeout in the checkout is never downgraded"
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=0; RESULT_KNOWN="$KNOWN_LEGACY" results tests='FAILED tests/legacy/old_test.py'; UNVERIFIABLE_CHECKS+=(container); ROOT_LABEL=""; attribute_root; printf '%s|%s' "$BLOCKING_FAILURE" "${KNOWN_NOTES[*]:-}")
eq "$out" "1|tests fails only on its knownFailures: tests/legacy/** (red on main, TICKET-1)." "R15: a refused check in the checkout is never downgraded"
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=0; RESULT_KNOWN="$KNOWN_LEGACY" results tests='FAILED tests/legacy/old_test.py'; NOT_RUN_CHECKS+=(later); ROOT_LABEL=""; attribute_root; printf '%s|%s' "$BLOCKING_FAILURE" "${KNOWN_NOTES[*]:-}")
eq "$out" "1|tests fails only on its knownFailures: tests/legacy/** (red on main, TICKET-1)." "R15: a check the budget left unrun is never downgraded"
# One known check beside one the session broke: the session's blocks.
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=0; results tests='FAILED tests/legacy/old_test.py' lint='app.ts:1 BROKEN'; FAILED_KNOWN=("$KNOWN_LEGACY" ""); ROOT_LABEL=""; attribute_root; printf '%s|%s' "$BLOCKING_FAILURE" "${KNOWN_NOTES[*]:-}")
eq "$out" "1|tests fails only on its knownFailures: tests/legacy/** (red on main, TICKET-1)." "R15: another failing check still blocks, the known one settled"
# One known check beside one naming only another session's file: both settled.
printf 'BROKEN\n' >> "$REPO/other.ts"
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=0; results tests='FAILED tests/legacy/old_test.py' lint='other.ts:2 BROKEN'; FAILED_KNOWN=("$KNOWN_LEGACY" ""); ROOT_LABEL=""; attribute_root; printf '%s|%s' "$BLOCKING_FAILURE" "${WARN_NOTES[*]}")
eq "${out%%|*}" 0 "R15 with R4: a known failure and an all-foreign one warn"
has "$out" "or is a known failure" "R15 with R4: the warning says both"
git -C "$REPO" checkout -q -- other.ts
# The report carries the known-failure note in the approve's systemMessage.
# shellcheck disable=SC2030,SC2031 # each case builds its results in its own subshell
out=$(attribute_init; IMPLEMENT_ACTIVE=0; RESULT_KNOWN="$KNOWN_LEGACY" results tests='FAILED tests/legacy/old_test.py'; RAN_CHECKS=(tests); SCOPE_NOTES=(); ROOT_LABEL=""; attribute_root; report_decision)
eq "$(printf '%s' "$out" | jq -r .decision)" approve "R15 report: a known failure approves"
has "$(printf '%s' "$out" | jq -r .systemMessage)" "tests fails only on its knownFailures" "R15 report: the systemMessage names it"

printf '\nstop-gate-attribute: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
