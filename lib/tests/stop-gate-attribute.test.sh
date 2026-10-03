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
  for a in "$@"; do
    printf '%s\n' "${a#*=}" > "$LOGS/$i"
    FAILED_CHECKS+=("${a%%=*}")
    FAILED_LOGS+=("$LOGS/$i")
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
out=$(decide 1 lint='app.ts:1 BROKEN')
eq "${out%%|*}" 0 "R6: a live feature-implement run warns"
has "$out" "during feature-implement orchestration" "R6: the warning says why"
out=$(decide 0 lint='other.ts:2 BROKEN')
eq "${out%%|*}" 0 "R4: an all-foreign failure warns"
has "$out" "A worktree per session" "R4: the warning points at isolation"
out=$(decide 0 lint='app.ts:1 BROKEN')
eq "${out%%|*}" 1 "R4: the session's own failure blocks"
has "$out" "names files this session wrote: app.ts" "R4: the block carries the paragraph"

printf '\nstop-gate-attribute: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
