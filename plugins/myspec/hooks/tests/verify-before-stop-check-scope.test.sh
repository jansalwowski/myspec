#!/usr/bin/env bash
# Fixture for the per-check settings of the stop gate (docs/stop-gate.md,
# R11 and R12): `checks[].paths` (#232), and `containers` with
# `checks[].runIn` (#221).
#
# paths: a check runs only when a file this session wrote in the checkout
# matches one of its globs; a required check skipped that way is named in the
# stop message, and an unusable setting runs the check. runIn: the check gets
# MYSPEC_CHECK_WORKDIR, this checkout's path inside the container, in the main
# checkout and in a worktree nested under the mount; a worktree outside the
# mount, or an undefined container, is refused without running. A runIn check
# satisfies the #220 container-exec refusal. cwd (#250): the check runs from
# that repo-relative directory, and a runIn check's workdir includes it.
#
# This suite keeps the paths that need the whole hook; each glob rule,
# unusable setting, unseen change, container spec and cwd value is a function
# test in lib/tests/stop-gate-run.test.sh.
#
# The write events are appended here directly through lib/session-event.sh,
# in the form mark-code-changed.sh records them.
#
# Usage: verify-before-stop-check-scope.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${1:-$HERE/../verify-before-stop.sh}"

ROOT=$(cd "$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/t2c-scope.XXXXXX")" && pwd -P)
SID="vbs-scope-$$"
RAN="$ROOT/ran"
trap 'rm -rf "$ROOT"' EXIT
SESSION_EVENT="$HERE/../../lib/session-event.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect() {  # expect <want> <got> <desc>
  if [ "$1" = "$2" ]; then ok; else fail "$3 (want '$1', got '$2')"; fi
}
has() {  # has <needle> <haystack> <desc>
  case "$2" in *"$1"*) ok ;; *) fail "$3 (no '$1' in: $2)" ;; esac
}
lacks() {  # lacks <needle> <haystack> <desc>
  case "$2" in *"$1"*) fail "$3 ('$1' in: $2)" ;; *) ok ;; esac
}

MAIN="$ROOT/app"
mkdir -p "$MAIN/.claude" "$MAIN/api" "$MAIN/web"
git init -q -b main "$MAIN"
git -C "$MAIN" config user.email t@t
git -C "$MAIN" config user.name t
printf '.claude/worktrees/\n.claude/state/\n' > "$MAIN/.gitignore"
printf '<?php\n' > "$MAIN/api/a.php"
printf 'export {}\n' > "$MAIN/web/a.ts"
printf '{"checks":[]}\n' > "$MAIN/.claude/verification.json"
git -C "$MAIN" add -A
git -C "$MAIN" commit -q -m init

# set_config <checkout> <json>: the verification.json there. Left uncommitted
# in the checkout it is written to; the gate reads the working tree.
set_config() {
  printf '%s\n' "$2" > "$1/.claude/verification.json"
}

# check <name> <command> [extra jq object] -> one required check that records
# its run in $RAN/<name> before running <command>.
check() {
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg n "$1" --arg c "echo ran > $RAN/$1; $2" --argjson x "$extra" \
    '{name: $n, command: $c, required: true} + $x'
}

# stop <root> <kind:path>... -> hook stdout. Each argument is one write event
# for <root>. Env from the caller reaches the hook. Each call is a new session:
# it runs in a $( ) subshell, so the counter lives in a file.
printf '0\n' > "$ROOT/n"
stop() {
  local root="$1" a sid n
  shift
  n=$(( $(cat "$ROOT/n") + 1 ))
  printf '%s\n' "$n" > "$ROOT/n"
  sid="$SID-$n"
  rm -rf "$RAN"
  mkdir -p "$RAN"
  for a in "$@"; do
    bash "$SESSION_EVENT" --root "$root" append "$sid" \
      "$(jq -nc --arg k "${a%%:*}" --arg r "$root" --arg p "${a#*:}" '{t: "write", root: $r, rel: $p, kind: $k}')"
  done
  jq -n --arg s "$sid" --arg d "$root" '{session_id: $s, cwd: $d}' \
    | PATH="$ROOT/bin:$PATH" bash "$HOOK" 2>/dev/null
}

decision() { printf '%s' "$1" | jq -r '.decision // "none"' 2>/dev/null || printf 'not-json'; }
text()     { printf '%s' "$1" | jq -r '(.reason // "") + (.systemMessage // "")' 2>/dev/null; }
ran()      { [ -f "$RAN/$1" ] && printf yes || printf no; }

# --- paths (#232) -------------------------------------------------------------
API=$(check Api true '{"paths":["api/**"]}')
WEB=$(check Web true '{"paths":["web/**"]}')
ALL=$(check All true)
set_config "$MAIN" "{\"checks\":[$API,$WEB,$ALL]}"

out=$(stop "$MAIN" code:api/a.php)
expect approve "$(decision "$out")" "paths: a pass with a skipped check approves"
expect yes "$(ran Api)" "paths: a check whose glob matches a written file runs"
expect no "$(ran Web)" "paths: a check whose globs match no written file is skipped"
expect yes "$(ran All)" "paths: a check without paths always runs"
has "Web: skipped" "$(text "$out")" "paths: the approve message names the skipped required check"
has "web/**" "$(text "$out")" "paths: the message gives the globs that did not match"
lacks "Api: skipped" "$(text "$out")" "paths: a check that ran is not reported as skipped"

# A required check skipped by paths is named in a block message as well.
API_RED=$(check Api false '{"paths":["api/**"]}')
set_config "$MAIN" "{\"checks\":[$API_RED,$WEB]}"
out=$(stop "$MAIN" code:api/a.php)
expect block "$(decision "$out")" "paths: a failing matched check blocks"
has "Web: skipped" "$(text "$out")" "paths: the block message names the skipped required check"

# --- containers and runIn (#221) -----------------------------------------------
# A fake docker on PATH: every exec passes.
mkdir -p "$ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/docker"
chmod +x "$ROOT/bin/docker"
CONTAINERS='{"app":{"mountSource":".","mountTarget":"/var/www/html"},"apionly":{"mountSource":"./api/","mountTarget":"/srv/api/"}}'
# workdir_check <name> <runIn> -> a check that records MYSPEC_CHECK_WORKDIR.
workdir_check() {
  jq -nc --arg n "$1" --arg c "printf '%s' \"\${MYSPEC_CHECK_WORKDIR-unset}\" > $RAN/$1.wd; docker compose exec -w \"\$MYSPEC_CHECK_WORKDIR\" app make lint" \
    --arg r "$2" '{name: $n, command: $c, required: true} + (if $r == "" then {} else {runIn: $r} end)'
}
wd() { cat "$RAN/$1.wd" 2>/dev/null || printf 'not-run'; }
container_config() {  # container_config <checkout> <check>...
  local c="$1" list
  shift
  list=$(printf '%s,' "$@")
  set_config "$c" "{\"containers\":$CONTAINERS,\"checks\":[${list%,}]}"
}

# Main checkout: the workdir is mountTarget.
container_config "$MAIN" "$(workdir_check Lint app)" "$(workdir_check Sub apionly)"
out=$(stop "$MAIN" code:api/a.php)
expect approve "$(decision "$out")" "main checkout: a runIn check runs and passes"
expect /var/www/html "$(wd Lint)" "main checkout: MYSPEC_CHECK_WORKDIR is mountTarget"
expect /srv/api "$(wd Sub)" "main checkout: a subdirectory mount is its own mountTarget"

# A worktree nested under the main checkout's mount: mountTarget + its path.
WT_N="$MAIN/.claude/worktrees/nested"
git -C "$MAIN" worktree add -q -b feat-nested "$WT_N" main
container_config "$WT_N" "$(workdir_check Lint app)"
out=$(stop "$WT_N" code:api/a.php)
expect approve "$(decision "$out")" "nested worktree: a runIn check runs and passes"
expect /var/www/html/.claude/worktrees/nested "$(wd Lint)" "nested worktree: MYSPEC_CHECK_WORKDIR is its path under the mount"

# A worktree outside the main checkout is not visible in the container.
WT_O="$ROOT/outside-wt"
git -C "$MAIN" worktree add -q -b feat-outside "$WT_O" main
container_config "$WT_O" "$(workdir_check Lint app)"
out=$(stop "$WT_O" code:api/a.php)
expect block "$(decision "$out")" "worktree outside mountSource: refused, blocks"
has "this worktree is not visible inside the container" "$(text "$out")" "worktree outside mountSource: the reason says why"
has "not run" "$(text "$out")" "worktree outside mountSource: the headline says it was not run"
expect not-run "$(wd Lint)" "worktree outside mountSource: the check never runs"

# --- runIn and the #220 container-exec refusal ---------------------------------
# An exec that reads the workdir without -w.
EXEC_NO_W="docker compose exec app sh -c 'cd \"\$MYSPEC_CHECK_WORKDIR\" && make lint'"
exec_check() {  # exec_check <runIn or empty>
  jq -nc --arg c "echo ran > $RAN/X; $EXEC_NO_W" --arg r "$1" \
    '{name: "X", command: $c, required: true} + (if $r == "" then {} else {runIn: $r} end)'
}
container_config "$WT_N" "$(exec_check '')"
out=$(stop "$WT_N" code:api/a.php)
expect block "$(decision "$out")" "nested worktree: an exec without runIn is refused (#220)"
has "unverifiable in a linked worktree" "$(text "$out")" "nested worktree: the #220 reason names runIn as a way out"
has "runIn" "$(text "$out")" "nested worktree: the #220 reason points at runIn"
expect no "$(ran X)" "nested worktree: the #220-refused check never runs"

container_config "$WT_N" "$(exec_check app)"
out=$(stop "$WT_N" code:api/a.php)
expect approve "$(decision "$out")" "nested worktree: runIn satisfies the #220 refusal"
expect yes "$(ran X)" "nested worktree: the runIn check runs"

# --- per-check cwd (#250) -------------------------------------------------------
# cwd_check <name> <cwd json> [runIn] -> a check that records where it ran
# and the workdir it got.
cwd_check() {
  jq -nc --arg n "$1" --argjson d "$2" --arg r "${3:-}" \
    --arg c "pwd -P > $RAN/$1.pwd; printf '%s' \"\${MYSPEC_CHECK_WORKDIR-unset}\" > $RAN/$1.wd" \
    '{name: $n, command: $c, required: true, cwd: $d} + (if $r == "" then {} else {runIn: $r} end)'
}
where() { cat "$RAN/$1.pwd" 2>/dev/null || printf 'not-run'; }

container_config "$MAIN" "$(cwd_check Rel '"api"')" "$(cwd_check Dot '"./web/"')"
out=$(stop "$MAIN" code:api/a.php)
expect approve "$(decision "$out")" "cwd: relative cwds run and pass"
expect "$MAIN/api" "$(where Rel)" "cwd: a relative cwd runs the check there"
expect "$MAIN/web" "$(where Dot)" "cwd: ./ and a trailing / are dropped"
lacks "cwd setting was ignored" "$(text "$out")" "cwd: a usable cwd is not reported"

# With cwd, MYSPEC_SESSION_FILES is relative to it, so a per-file linter run
# there finds the files (#255 review): under cwd the prefix goes, outside it
# the path gets ../.
printf 'export {}\n' > "$MAIN/web/b.ts"
c=$(jq -nc --arg c 'printf "%s\n" "$MYSPEC_SESSION_FILES" > '"$RAN"'/Lint.files; for f in $MYSPEC_SESSION_FILES; do test -f "$f" || { echo "missing $f"; exit 1; }; done' \
  '{name: "Lint", command: $c, required: true, cwd: "api"}')
container_config "$MAIN" "$c"
out=$(stop "$MAIN" code:api/a.php file:web/b.ts)
expect approve "$(decision "$out")" "cwd: every MYSPEC_SESSION_FILES path resolves from the check's cwd"
expect "$(printf 'a.php\n../web/b.ts')" "$(cat "$RAN/Lint.files" 2>/dev/null)" "cwd: MYSPEC_SESSION_FILES is relative to the cwd"
rm -f "$MAIN/web/b.ts"

# The documented example pins the compose project, and runs in a worktree.
# The docs live at the repository root, above both copies of this suite.
DOCS="$(git -C "$HERE" rev-parse --show-toplevel)/docs/stop-gate.md"
# shellcheck disable=SC2016
DOC_CMD=$(sed -n '/^```json$/,/^```$/p' "$DOCS" | sed '1d;$d' | jq -r '.checks[0].command')
has ' -p ' "$DOC_CMD" "docs example: the compose project is pinned with -p"
c=$(jq -nc --arg c "echo ran > $RAN/D; $DOC_CMD" '{name: "D", command: $c, required: true, runIn: "app"}')
container_config "$WT_N" "$c"
out=$(stop "$WT_N" code:api/a.php)
expect yes "$(ran D)" "docs example: runs in a nested worktree"

printf '\nverify-before-stop-check-scope: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
