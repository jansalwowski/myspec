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
# satisfies the #220 container-exec refusal.
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

out=$(stop "$MAIN" code:worker/main.go file:docs/notes.md)
expect no "$(ran Api)" "paths: no match, api check skipped"
expect no "$(ran Web)" "paths: no match, web check skipped"
expect yes "$(ran All)" "paths: no match, unscoped check still runs"

# A non-code write is a session write too: it can match a check's paths.
out=$(stop "$MAIN" code:worker/main.go file:web/tsconfig.json)
expect yes "$(ran Web)" "paths: a non-code file the session wrote matches"

# A required check skipped by paths is named in a block message as well.
API_RED=$(check Api false '{"paths":["api/**"]}')
set_config "$MAIN" "{\"checks\":[$API_RED,$WEB]}"
out=$(stop "$MAIN" code:api/a.php)
expect block "$(decision "$out")" "paths: a failing matched check blocks"
has "Web: skipped" "$(text "$out")" "paths: the block message names the skipped required check"

# Only checks that would have run are reported: a check that is not required
# is never run, with or without paths.
OPT=$(jq -nc '{name: "Opt", command: "true", required: false, paths: ["web/**"]}')
set_config "$MAIN" "{\"checks\":[$API,$OPT]}"
out=$(stop "$MAIN" code:api/a.php)
lacks "Opt" "$(text "$out")" "paths: a check that is not required is not reported"

# Glob semantics, documented in docs/stop-gate.md.
# glob_case <glob> <written path> <yes|no> <desc>
glob_case() {
  local c
  c=$(check G true "$(jq -nc --arg g "$1" '{paths: [$g]}')")
  set_config "$MAIN" "{\"checks\":[$c]}"
  stop "$MAIN" "code:$2" >/dev/null
  expect "$3" "$(ran G)" "glob '$1' vs '$2': $4"
}
glob_case 'api/**' api/a.php yes "** under a directory"
glob_case 'api/**' api/v1/deep/a.php yes "** spans segments"
glob_case 'api/**' apix/a.php no "a directory prefix is a whole segment"
glob_case 'api/' api/v1/a.php yes "a trailing / is everything under it"
glob_case '**/*.php' a.php yes "**/ matches zero segments"
glob_case '**/*.php' api/v1/a.php yes "**/ matches several segments"
glob_case '*.php' api/a.php no "* stays within one segment and the glob is anchored at the root"
glob_case '*.php' a.php yes "* at the root"
glob_case 'api/*/a.php' api/v1/a.php yes "* is one segment"
glob_case 'api/*/a.php' api/v1/v2/a.php no "* is not two segments"
glob_case 'a/**/b.ts' a/b.ts yes "a/**/b matches a/b"
glob_case 'a/**/b.ts' a/x/y/b.ts yes "a/**/b matches deeper"
glob_case 'src/?.go' src/a.go yes "? is one character"
glob_case 'src/?.go' src/ab.go no "? is not two characters"
glob_case './web/**' web/a.ts yes "a leading ./ is dropped"
glob_case 'web/a.ts' web/a.ts yes "a literal path"
glob_case 'web/a.ts' web/axts no ". is literal"
glob_case 'web/[ab].ts' web/a.ts no "[ is literal, not a class"
glob_case 'web/[ab].ts' 'web/[ab].ts' yes "[ matches itself"
glob_case 'a**b/x' azzb/x yes "** inside a segment is a plain *"
glob_case 'a**b/x' a/b/x no "** inside a segment does not cross /"

# An unusable paths setting runs the check, and the message names it.
for bad in '"api/**"' '[]' '["/abs/**"]' '["../api/**"]' '[""]' '[1]'; do
  c=$(check B true "{\"paths\":$bad}")
  set_config "$MAIN" "{\"checks\":[$c]}"
  out=$(stop "$MAIN" code:web/a.ts)
  expect yes "$(ran B)" "paths $bad is unusable, so the check runs"
  has "paths setting was ignored" "$(text "$out")" "paths $bad: the message names the ignored setting"
done

# A linked worktree is scoped by the files written in it, not in main.
WT_P="$MAIN/.claude/worktrees/paths"
git -C "$MAIN" worktree add -q -b feat-paths "$WT_P" main
set_config "$WT_P" "{\"checks\":[$API,$WEB]}"
out=$(stop "$WT_P" code:web/a.ts)
expect yes "$(ran Web)" "worktree: the check matching its own write runs"
expect no "$(ran Api)" "worktree: the other check is skipped"

# Changes the ledger cannot see (git revert, rm, codegen, a variable path):
# a path under the globs that git reports changed, uncommitted or against the
# base, runs the check even when the ledger has no matching write.
WT_U="$MAIN/.claude/worktrees/unseen"
git -C "$MAIN" worktree add -q -b feat-unseen "$WT_U" main
set_config "$WT_U" "{\"checks\":[$API,$WEB]}"
out=$(stop "$WT_U" code:web/a.ts)
expect no "$(ran Api)" "unseen: a clean api/ stays skipped"
has "Api: skipped" "$(text "$out")" "unseen: the clean skip is still named"
rm "$WT_U/api/a.php"
out=$(stop "$WT_U" code:web/a.ts)
expect yes "$(ran Api)" "unseen: an rm under api/ the ledger lacks runs the api check"
expect yes "$(ran Web)" "unseen: the check matching the ledger still runs"
lacks "Api: skipped" "$(text "$out")" "unseen: the rm-armed check is not reported skipped"
git -C "$WT_U" checkout -q -- api/a.php
printf '<?php // gen\n' > "$WT_U/api/gen.php"
out=$(stop "$WT_U" code:web/a.ts)
expect yes "$(ran Api)" "unseen: an untracked file under api/ (codegen) runs the api check"
rm "$WT_U/api/gen.php"
printf '<?php // v2\n' > "$WT_U/api/a.php"
git -C "$WT_U" commit -q -am "api change" 
out=$(stop "$WT_U" code:web/a.ts)
expect yes "$(ran Api)" "unseen: a committed change under api/ against the base (git revert) runs the api check"

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

# Nested under the checkout, but not under a mount of api/ only.
container_config "$WT_N" "$(workdir_check Sub apionly)"
out=$(stop "$WT_N" code:api/a.php)
expect block "$(decision "$out")" "nested worktree outside an api/ mount: refused"
has "this worktree is not visible inside the container" "$(text "$out")" "nested worktree outside an api/ mount: the reason says why"
expect not-run "$(wd Sub)" "nested worktree outside an api/ mount: the check never runs"

# A worktree outside the main checkout is not visible in the container.
WT_O="$ROOT/outside-wt"
git -C "$MAIN" worktree add -q -b feat-outside "$WT_O" main
container_config "$WT_O" "$(workdir_check Lint app)"
out=$(stop "$WT_O" code:api/a.php)
expect block "$(decision "$out")" "worktree outside mountSource: refused, blocks"
has "this worktree is not visible inside the container" "$(text "$out")" "worktree outside mountSource: the reason says why"
has "not run" "$(text "$out")" "worktree outside mountSource: the headline says it was not run"
expect not-run "$(wd Lint)" "worktree outside mountSource: the check never runs"

# An undefined container refuses the check with a clear reason.
container_config "$MAIN" "$(workdir_check Lint nope)"
out=$(stop "$MAIN" code:api/a.php)
expect block "$(decision "$out")" "undefined container: refused, blocks"
has 'runIn names container "nope"' "$(text "$out")" "undefined container: the reason names it"
has "does not define" "$(text "$out")" "undefined container: the reason says it is not defined"
expect not-run "$(wd Lint)" "undefined container: the check never runs"

# containers that is not an object: the reader ignores it and says so.
set_config "$MAIN" "{\"containers\":\"app\",\"checks\":[$(workdir_check Lint app)]}"
out=$(stop "$MAIN" code:api/a.php)
expect block "$(decision "$out")" "containers not an object: a runIn check is refused"
has "ignoring verification.containers" "$(text "$out")" "containers not an object: the reader's note is in the reason"

# A container without a usable mountTarget or mountSource is refused.
for spec in '{"mountSource":"."}' '{"mountSource":".","mountTarget":"srv"}' '{"mountSource":"../x","mountTarget":"/srv"}' '{"mountTarget":"/srv"}'; do
  set_config "$MAIN" "{\"containers\":{\"app\":$spec},\"checks\":[$(workdir_check Lint app)]}"
  out=$(stop "$MAIN" code:api/a.php)
  expect block "$(decision "$out")" "container $spec: refused"
  expect not-run "$(wd Lint)" "container $spec: the check never runs"
done

# A check without runIn never sees a workdir, not even one from the caller.
container_config "$MAIN" "$(workdir_check Plain '')"
out=$(MYSPEC_CHECK_WORKDIR=/stale stop "$MAIN" code:api/a.php)
expect unset "$(wd Plain)" "no runIn: MYSPEC_CHECK_WORKDIR is not exported"

# paths is applied before runIn: a skipped check is not refused.
c=$(jq -nc '{name: "Skip", command: "true", required: true, runIn: "nope", paths: ["web/**"]}')
set_config "$MAIN" "{\"checks\":[$c]}"
out=$(stop "$MAIN" code:api/a.php)
expect approve "$(decision "$out")" "a check skipped by paths is not refused for its runIn"

# --- runIn and the #220 container-exec refusal ---------------------------------
# An exec without -w that reads the workdir some other way.
EXEC_NO_W="docker compose exec app sh -c 'cd \"\$MYSPEC_CHECK_WORKDIR\" && make lint'"
exec_check() {  # exec_check <runIn or empty>
  jq -nc --arg c "echo ran > $RAN/X; $EXEC_NO_W" --arg r "$1" \
    '{name: "X", command: $c, required: true} + (if $r == "" then {} else {runIn: $r} end)'
}
container_config "$WT_N" "$(exec_check '')"
out=$(stop "$WT_N" code:api/a.php)
expect block "$(decision "$out")" "nested worktree: an exec without -w and without runIn is refused (#220)"
has "unverifiable in a linked worktree" "$(text "$out")" "nested worktree: the #220 reason names runIn as a way out"
has "runIn" "$(text "$out")" "nested worktree: the #220 reason points at runIn"
expect no "$(ran X)" "nested worktree: the #220-refused check never runs"

container_config "$WT_N" "$(exec_check app)"
out=$(stop "$WT_N" code:api/a.php)
expect approve "$(decision "$out")" "nested worktree: runIn satisfies the #220 refusal"
expect yes "$(ran X)" "nested worktree: the runIn check runs"

# runIn exempts only a command that uses the workdir: an exec with neither
# -w/--workdir nor MYSPEC_CHECK_WORKDIR still runs in the container's default
# directory, the main checkout's tree.
plain_exec() {  # plain_exec <runIn> <exec options>
  jq -nc --arg c "echo ran > $RAN/P; docker compose exec $2 app make lint" --arg r "$1" \
    '{name: "P", command: $c, required: true, runIn: $r}'
}
# The literal $MYSPEC_CHECK_WORKDIR below is meant: the hook expands it.
# shellcheck disable=SC2016
{
container_config "$WT_N" "$(plain_exec app '')"
out=$(stop "$WT_N" code:api/a.php)
expect block "$(decision "$out")" "nested worktree: runIn with an exec lacking -w and the workdir is refused"
expect no "$(ran P)" "nested worktree: runIn with an unpinned exec never runs"
has '-w "$MYSPEC_CHECK_WORKDIR"' "$(text "$out")" "nested worktree: the refusal says to pass -w \"\$MYSPEC_CHECK_WORKDIR\""
container_config "$WT_N" "$(plain_exec app '-w "$MYSPEC_CHECK_WORKDIR"')"
out=$(stop "$WT_N" code:api/a.php)
expect approve "$(decision "$out")" "nested worktree: runIn with -w \"\$MYSPEC_CHECK_WORKDIR\" runs"
expect yes "$(ran P)" "nested worktree: runIn with -w runs the check"
}
container_config "$WT_N" "$(plain_exec app '-Tw /var/www/html/.claude/worktrees/nested')"
out=$(stop "$WT_N" code:api/a.php)
expect yes "$(ran P)" "nested worktree: runIn with a -Tw cluster runs the check"
container_config "$MAIN" "$(plain_exec app '')"
out=$(stop "$MAIN" code:api/a.php)
expect yes "$(ran P)" "main checkout: runIn with a plain exec runs (R8a is for linked worktrees)"

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

container_config "$WT_O" "$(exec_check app)"
out=$(stop "$WT_O" code:api/a.php)
expect block "$(decision "$out")" "outside worktree: runIn does not bypass visibility"
expect no "$(ran X)" "outside worktree: the check never runs"
lacks "unverifiable in a linked worktree" "$(text "$out")" "outside worktree: the reason is visibility, not #220"

printf '\nverify-before-stop-check-scope: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
