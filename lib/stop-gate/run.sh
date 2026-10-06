#!/usr/bin/env bash
# stop-gate/run.sh
# lint: sourced under set -euo pipefail
# Sourced by hooks/verify-before-stop.sh, after lib/hook-core.sh and
# stop-gate/arm.sh; never run. Loads a checkout's checks, decides per check
# whether it runs (`paths`, `cwd`, `runIn`, the container-exec refusal) and
# runs it under the capped runner. Requirements: docs/stop-gate.md (R5, R7,
# R8a, R11, R12) and docs/verify-check-escapes.md in the plugin repository.
# Tests: lib/tests/stop-gate-run.test.sh.
#
# Results go to the arrays run_init sets up: FAILED_CHECKS with FAILED_LOGS
# (kept for attribution, removed on exit), FAILED_CWDS and FAILED_OUTPUT,
# TIMED_OUT_CHECKS, UNVERIFIABLE_CHECKS, NOT_RUN_CHECKS, RAN_CHECKS,
# SCOPE_NOTES, and CHECKS_RAN.
# shellcheck disable=SC2034

# Per-check time cap (R7). A check that outlives it is killed and reported as
# timed out: the result is unknown, which is not a failure, and the report
# must say which one it is (a green suite killed at the cap once read as a
# red one). MYSPEC_CHECK_CAP_SECONDS may lower the cap (the hook tests use
# it); a value above the default is ignored, so it can never raise it. A
# check's cleanup command gets its own cap, lowered with the check cap and
# never above 30 s.
CHECK_CAP_DEFAULT=120
CLEANUP_CAP_DEFAULT=30

# Gate-wide budget (R13). One budget covers the whole stop: every check in
# every armed checkout, and their cleanup. Per-check caps alone let the worst
# case grow as checks x checkouts x 150 s, and then the harness's own Stop
# hook timeout (600 s by default, docs/verify-check-escapes.md) decides the
# outcome, discarding whatever the gate had found. The budget stays below
# it. A check that would start after the budget ran out is not run and is
# reported as such; one running when it runs out is capped at what is left
# and reported as timed out. MYSPEC_GATE_BUDGET_SECONDS lowers it and can
# never raise it. A cleanup after a timeout still gets GATE_CLEANUP_FLOOR
# seconds when the budget is spent, so remote work is not left running; the
# 30 s between the budget and the harness timeout in hooks.json covers that
# and the kill grace.
GATE_BUDGET_DEFAULT=300
GATE_CLEANUP_FLOOR=5

# gate_budget_init -> GATE_BUDGET_SECONDS and GATE_DEADLINE, from now. The
# hook calls it first thing, so the conformance gates count too.
gate_budget_init() {
  GATE_BUDGET_SECONDS=$GATE_BUDGET_DEFAULT
  if [[ "${MYSPEC_GATE_BUDGET_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] && [ "$MYSPEC_GATE_BUDGET_SECONDS" -lt "$GATE_BUDGET_SECONDS" ]; then
    GATE_BUDGET_SECONDS=$MYSPEC_GATE_BUDGET_SECONDS
  fi
  GATE_DEADLINE=$(( $(date +%s) + GATE_BUDGET_SECONDS ))
}

# gate_remaining -> the seconds left in the budget, 0 when spent.
gate_remaining() {
  local r=$(( GATE_DEADLINE - $(date +%s) ))
  [ "$r" -gt 0 ] || r=0
  printf '%s\n' "$r"
}

# run_init -> the caps, the cap sentinel and the result arrays. Starts the
# budget unless gate_budget_init already did.
run_init() {
  [ -n "${GATE_DEADLINE:-}" ] || gate_budget_init
  CHECK_CAP_SECONDS=$CHECK_CAP_DEFAULT
  if [[ "${MYSPEC_CHECK_CAP_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] && [ "$MYSPEC_CHECK_CAP_SECONDS" -lt "$CHECK_CAP_SECONDS" ]; then
    CHECK_CAP_SECONDS=$MYSPEC_CHECK_CAP_SECONDS
  fi
  CLEANUP_CAP_SECONDS=$CLEANUP_CAP_DEFAULT
  [ "$CHECK_CAP_SECONDS" -lt "$CLEANUP_CAP_SECONDS" ] && CLEANUP_CAP_SECONDS=$CHECK_CAP_SECONDS
  CAP_SENTINEL=$(mktemp "${TMPDIR:-/tmp}/.myspec-cap.XXXXXX")
  rm -f "$CAP_SENTINEL"
  CHECK_LOG=""
  CHECK_RUN_LOG=""
  CHECK_CWD=""
  FAILED_CHECKS=()
  FAILED_LOGS=()
  # Each failed check's cwd, beside its log: attribution reads the paths a
  # tool printed relative to it.
  FAILED_CWDS=()
  FAILED_OUTPUT=()
  TIMED_OUT_CHECKS=()
  # Checks refused without running: their result would describe another tree.
  UNVERIFIABLE_CHECKS=()
  # Checks the budget left no time for, and the checks that did run (R13).
  NOT_RUN_CHECKS=()
  RAN_CHECKS=()
  # Checks skipped by their paths, and settings the reader or the gate
  # ignored: reported on every outcome, an approve included.
  SCOPE_NOTES=()
  CHECKS_RAN=0
}

# run_cleanup_files -> removes the sentinel and every log still on disk.
# shellcheck disable=SC2317 # called from the hook's EXIT trap
run_cleanup_files() {
  rm -f "$CAP_SENTINEL" ${CHECK_LOG:+"$CHECK_LOG"} ${CHECK_RUN_LOG:+"$CHECK_RUN_LOG"} ${FAILED_LOGS[@]+"${FAILED_LOGS[@]}"}
}

# run_with_cap <seconds> <command>: runs it under the cap and kills the whole
# process group at the deadline. Killing only the direct child is not enough:
# a test runner's workers would keep running (measured: 456 s under a 120 s
# cap). perl is in the macOS base system and in nearly every Linux image; it
# puts the command in its own process group, SIGTERMs the group at the
# deadline (SIGKILL once the command exits, at most 5 s later) and touches
# $CAP_SENTINEL so the caller knows the exit was the cap's, not the command's
# own. When the command exits on its own, whatever it left in its group (a
# server started with &, workers that did not exit) is killed too: nothing
# will read their output. Without perl, GNU timeout also signals the group at
# the deadline (it leads the group it runs in), and kill_group reaps the rest
# after it returns; its exit 124 is ambiguous, so the caller also checks the
# elapsed time. With neither, the command runs uncapped and its leftovers
# are not reaped.
# The group kill reaches only processes on this machine that stay in the
# group. Work a command runs in a container or on another host (docker exec,
# kubectl exec, ssh) outlives its client; the check's cleanup command is how
# the project stops it.
run_with_cap() {
  if command -v perl &>/dev/null; then
    perl -e '
      my ($cap, $sentinel) = (shift, shift);
      my $pid = fork() // exit 127;
      if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
      setpgrp($pid, $pid);
      local $SIG{ALRM} = sub {
        open(my $fh, ">", $sentinel); close($fh);
        kill "TERM", -$pid;
        for (1 .. 50) { last if waitpid($pid, 1) > 0; select(undef, undef, undef, 0.1) }
        kill "KILL", -$pid; waitpid($pid, 0); exit 124;
      };
      alarm $cap;
      waitpid($pid, 0);
      alarm 0;
      my $rc = ($? & 127) ? 128 + ($? & 127) : $? >> 8;
      if (kill 0, -$pid) {
        kill "TERM", -$pid;
        for (1 .. 20) { last unless kill 0, -$pid; select(undef, undef, undef, 0.1) }
        kill "KILL", -$pid;
      }
      exit $rc;
    ' "$1" "$CAP_SENTINEL" bash -c "$2"
  elif command -v gtimeout &>/dev/null || command -v timeout &>/dev/null; then
    local bin pid rc=0
    bin=$(command -v gtimeout || command -v timeout)
    "$bin" "$1" bash -c "$2" &
    pid=$!
    wait "$pid" || rc=$?
    kill_group "$pid"
    return "$rc"
  else
    bash -c "$2"
  fi
}

# kill_group <pgid>: TERM what is left of the process group, KILL after 2 s.
# A group that no longer exists (or a timeout that did not lead one) is a
# no-op.
kill_group() {
  kill -TERM -- "-$1" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 -- "-$1" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$1" 2>/dev/null || true
}

# capped <exit code> <elapsed> <cap> -> 0 when the exit was the cap's.
capped() {
  [ -f "$CAP_SENTINEL" ] || { [ "$1" -eq 124 ] && [ "$2" -ge "$3" ]; }
}

# relative_to <dir> <repo-relative path> -> the path relative to <dir>, a
# repo-relative directory ("" is the root): under it the prefix goes, outside
# it each segment of <dir> the two do not share becomes a ../.
relative_to() {
  local dir="$1" up=""
  while [ -n "$dir" ]; do
    case "$2" in "$dir"/*) printf '%s%s\n' "$up" "${2#"$dir"/}"; return ;; esac
    up="../$up"
    case "$dir" in */*) dir=${dir%/*} ;; *) dir="" ;; esac
  done
  printf '%s%s\n' "$up" "$2"
}

# session_files_from <dir> -> MYSPEC_SESSION_FILES with each path relative to
# <dir> (CHECK_CWD), where the check runs, so a per-file linter there can open
# them. paths_verdict matches the repo-relative list before this.
session_files_from() {
  local f
  [ -n "$1" ] || { printf '%s' "$MYSPEC_SESSION_FILES"; return; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    relative_to "$1" "$f"
  done <<< "$MYSPEC_SESSION_FILES"
}

# run_capped <seconds> <command> <run id> [keep]: runs <command> from the repo
# root, or the check's cwd under it (CHECK_CWD), under run_with_cap, with
# MYSPEC_SESSION_FILES relative to where it runs. Sets
# RUN_EXIT, RUN_ELAPSED and RUN_OUTPUT. With keep, the output file stays and
# RUN_LOG names it: the caller removes it, or keeps a failed check's log for
# attribution to read.
# Output goes to a file, not a $(...) capture: a process that escapes the
# group kill (it called setsid, or it is a detaching daemon) would otherwise
# hold the pipe open and keep the hook waiting until it exits on its own,
# whatever the cap says. Each run gets its own file, removed after reading,
# because such a process keeps writing to it: a shared file would put its
# output into the next check's report.
run_capped() {
  local start
  rm -f "$CAP_SENTINEL"
  CHECK_LOG=$(mktemp "${TMPDIR:-/tmp}/.myspec-check.XXXXXX")
  start=$(date +%s)
  (cd "$REPO_ROOT${CHECK_CWD:+/$CHECK_CWD}" && MYSPEC_SESSION_FILES=$(session_files_from "$CHECK_CWD") \
    MYSPEC_STOP_HOOK_ACTIVE=1 MYSPEC_CHECK_RUN_ID="$3" run_with_cap "$1" "$2") \
    >"$CHECK_LOG" 2>&1 </dev/null && RUN_EXIT=0 || RUN_EXIT=$?
  RUN_ELAPSED=$(( $(date +%s) - start ))
  RUN_OUTPUT=$(cat "$CHECK_LOG")
  RUN_LOG=""
  if [ -n "${4:-}" ]; then
    RUN_LOG="$CHECK_LOG"
  else
    rm -f "$CHECK_LOG"
  fi
  CHECK_LOG=""
}

# Container checks in a linked worktree (R8a, #220). A container exec runs in
# the container's working directory, which mounts the checkout the container
# (or compose project) was started from, as a rule the main checkout. From a
# linked worktree such a check either finds no running service or verifies
# the main checkout's tree. A check declares where its work runs with runIn
# (R12); one that does not, and whose command contains a declared exec form,
# is refused there instead of run. Nothing is inferred from the command's
# options: setup-doctor parses those and warns ahead of a stop.

# The exec forms, as data: another engine or wrapper is one more entry.
CONTAINER_EXEC_FORMS=("docker exec" "docker container exec" "docker compose exec" "docker-compose exec" "podman exec" "podman container exec" "podman compose exec" "podman-compose exec")

# container_exec_form <command> -> 0 when the command contains one of the
# forms as whole words, the program called by any path, with options (and a
# value after each) allowed between the words: `docker compose -p x exec`.
# What follows `exec` is never read.
container_exec_form() {
  local seps=$'\t\n;|&()"\'' gap='( -[^ ]+( [^ -][^ ]*)?)* ' c form re
  c=" ${1//[$seps]/ } "
  while [ "${c//  / }" != "$c" ]; do c=${c//  / }; done
  for form in "${CONTAINER_EXEC_FORMS[@]}"; do
    re="[ /]${form// /$gap} "
    [[ "$c" =~ $re ]] && return 0
  done
  return 1
}

# rel_dir <value> -> sets REL_DIR to the value as a repo-relative directory
# ("" for the root): a leading ./ and a trailing / are dropped, and . is the
# root. Returns 1 when it is absolute or has a .. segment. The rejection runs
# again after each strip, so ".//api" (which becomes "/api") and "./.." are
# refused too. One helper for `cwd` and a container's mountSource, so the two
# cannot drift on what is usable.
rel_dir() {
  local v="$1"
  while :; do
    case "$v" in
      /*|..|../*|*/..|*/../*) return 1 ;;
      ./*) v=${v#./} ;;
      */) v=${v%/} ;;
      *) break ;;
    esac
  done
  [ "$v" != . ] || v=""
  REL_DIR=$v
}

# check_cwd <check json> -> sets CHECK_CWD to the check's repo-relative cwd
# ("" for the checkout root, "" itself included), and CWD_IGNORED to the raw
# value when it is unusable (not a string, absolute, or with a .. segment):
# the check then runs from the root and the stop message names it, as for
# paths.
check_cwd() {
  local raw
  CHECK_CWD="" CWD_IGNORED=""
  raw=$(printf '%s' "$1" | jq -r 'if has("cwd") then (.cwd | if type == "string" then "s" + . else "x" + tojson end) else "" end')
  [ -n "$raw" ] || return 0
  case "$raw" in
    x*) CWD_IGNORED=${raw#x}; return 0 ;;
  esac
  raw=${raw#s}
  if ! rel_dir "$raw"; then
    CWD_IGNORED="\"$raw\""
    return 0
  fi
  CHECK_CWD=$REL_DIR
}

# Path scope (R11, #232). A check's `paths` is a list of repo-relative globs
# matched against each file this session wrote in the checkout. They compile
# through lib/glob-regex.sh, the one glob compiler (semantics there and in
# docs/stop-gate.md "Globs"), which hook-core sources. A glob that is empty,
# absolute or has a `..` segment is unusable, and so is a `paths` that is not
# a non-empty list of strings: the check then runs, and the stop message
# names the ignored setting (fail closed).

# paths_verdict <check json> -> sets PATHS_VERDICT to run (no paths, or a
# file matches), skip (no file matches) or ignored (unusable; the check
# runs), and PATHS_GLOBS to the globs joined with ", ".
paths_verdict() {
  local state glob re alt="" f
  PATHS_VERDICT=run
  PATHS_GLOBS=""
  state=$(printf '%s' "$1" | jq -r '.paths
    | if . == null then "absent"
      elif type == "array" and length > 0 and all(.[]; type == "string") then "list"
      else "bad" end')
  [ "$state" != absent ] || return 0
  if [ "$state" = bad ]; then
    PATHS_VERDICT=ignored
    return 0
  fi
  while IFS= read -r glob; do
    PATHS_GLOBS="${PATHS_GLOBS:+$PATHS_GLOBS, }$glob"
    if ! re=$(glob_regex "$glob"); then
      PATHS_VERDICT=ignored
      return 0
    fi
    alt="${alt:+$alt|}$re"
  done < <(printf '%s' "$1" | jq -r '.paths[]')
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [[ "$f" =~ $alt ]] && return 0
  done <<< "$MYSPEC_SESSION_FILES"
  # The ledger misses writes it cannot see: git revert or checkout, rm, a
  # code generator, a variable path. A path under the globs that git reports
  # changed, uncommitted or against the base, runs the check (fail closed).
  unseen_files
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [[ "$f" =~ $alt ]] && return 0
  done <<< "$UNSEEN_FILES"
  PATHS_VERDICT=skip
}

# unseen_files -> sets UNSEEN_FILES, once per checkout (arm_root resets it):
# the paths git reports changed there, uncommitted or untracked
# (changed_files) and, when a base ref resolved, against MYSPEC_BASE_REF,
# both sides of a rename included.
UNSEEN_READY=0
UNSEEN_FILES=""
unseen_files() {
  [ "$UNSEEN_READY" -eq 0 ] || return 0
  UNSEEN_READY=1
  UNSEEN_FILES=$({
    changed_files
    if [ -n "$MYSPEC_BASE_REF" ]; then
      git -C "$REPO_ROOT" diff --name-only --no-renames "$MYSPEC_BASE_REF" -- 2>/dev/null || true
    fi
  } | grep -v '^\.claude/state/' | sort -u || true)
}

# Containers (R12, #221). A container that bind-mounts part of the repository
# mounts the MAIN checkout's copy, so a check run in it sees the worktree only
# when the worktree lies under that mount. `containers` maps a name to
# {mountSource, mountTarget}: mountSource repo-relative (usually "."),
# mountTarget absolute inside the container. For a check with runIn, the
# check gets MYSPEC_CHECK_WORKDIR: where this checkout's mountSource sits in
# the container, mountTarget plus the path of <checkout>/<mountSource> under
# <main checkout>/<mountSource>. In the main checkout that is mountTarget.
# A check's cwd under mountSource is appended (#250).

# main_checkout <root> -> the physical path of the repository's main
# checkout. A submodule's is its superproject's main checkout plus the
# submodule's path, so a submodule of a linked worktree is not its own main.
# Otherwise checkout_facts decides (none for a bare repository).
main_checkout() {
  local sp main
  checkout_facts "$1" || { printf '%s\n' "$1"; return 0; }
  if [ "$CF_SUBMODULE" = 1 ]; then
    sp="$CF_SUPER"
    case "$1/" in "$sp"/*) ;; *) return 1 ;; esac
    main=$(main_checkout "$sp") || return 1
    printf '%s/%s\n' "$main" "${1#"$sp"/}"
    return 0
  fi
  [ -n "$CF_MAIN" ] || return 1
  printf '%s\n' "$CF_MAIN"
}

# check_workdir <root> <container name> <cwd> -> sets CHECK_WORKDIR, or
# REFUSE_REASON when the check cannot run there. Reads CONTAINERS_JSON (null
# when unset) and CONTAINERS_NOTES (load_checks).
check_workdir() {
  local spec src tgt main base self rel sub=""
  CHECK_WORKDIR=""
  REFUSE_REASON=""
  spec=$(printf '%s' "$CONTAINERS_JSON" | jq -c --arg n "$2" 'if type == "object" and has($n) then .[$n] else empty end')
  if [ -z "$spec" ]; then
    REFUSE_REASON="runIn names container \"$2\", which \`containers\` in .claude/verification.json does not define.${CONTAINERS_NOTES:+ $CONTAINERS_NOTES}"
    return 1
  fi
  # An empty value means missing or not a non-empty string.
  src=$(printf '%s' "$spec" | jq -r 'if type == "object" and (.mountSource | type) == "string" then .mountSource else "" end')
  tgt=$(printf '%s' "$spec" | jq -r 'if type == "object" and (.mountTarget | type) == "string" then .mountTarget else "" end')
  if [ -z "$src" ] || ! rel_dir "$src"; then
    REFUSE_REASON="container \"$2\" needs mountSource, the repo-relative directory it mounts (usually \".\"), without .. segments."
    return 1
  fi
  src=$REL_DIR
  case "$tgt" in
    /*) ;;
    *)
      REFUSE_REASON="container \"$2\" needs mountTarget, the absolute path its mountSource is mounted at inside the container."
      return 1 ;;
  esac
  while [ "${tgt%/}" != "$tgt" ]; do tgt="${tgt%/}"; done
  if ! main=$(main_checkout "$1"); then
    REFUSE_REASON="the main checkout of $1 could not be found, so where container \"$2\" sees this checkout is unknown."
    return 1
  fi
  base="$main${src:+/$src}"
  self="$1${src:+/$src}"
  if [ "$self" = "$base" ]; then
    rel=""
  else
    case "$self/" in
      "$base"/*) rel="/${self#"$base"/}" ;;
      *)
        REFUSE_REASON="this worktree is not visible inside the container: container \"$2\" mounts $base at ${tgt:-/}, and $self is not under it, so a check run there would see another tree. Create the worktree under $base (for example in the isolation.worktreeRoot of the main checkout), or run the tool on the host."
        return 1 ;;
    esac
  fi
  if [ -n "$3" ] && [ "$3" != "$src" ]; then
    case "$3/" in
      "${src:+$src/}"*) sub="/${3#"${src:+$src/}"}" ;;
      *)
        REFUSE_REASON="its cwd \"$3\" is not under mountSource \"$src\" of container \"$2\", so it is not visible inside the container."
        return 1 ;;
    esac
  fi
  CHECK_WORKDIR="$tgt$rel$sub"
  [ -n "$CHECK_WORKDIR" ] || CHECK_WORKDIR=/
}

# load_checks <config file> -> sets CHECKS_JSON and CONTAINERS_JSON (with
# CONTAINERS_NOTES) through the settings reader (read_setting in
# lib/hook-core.sh), from the checkout whose verification.json is in use.
# The reader ships with the hook; when it fails, the gate blocks with its
# reason instead of guessing at the checks, and records no verified event
# (GATE_UNVERIFIED), so the checkout stays armed until the install is fixed.
load_checks() {
  local config_root
  config_root=$(dirname "$(dirname "$1")")
  CONFIG_ROOT=$config_root
  read_setting verification.checks "$config_root" || load_checks_failed
  CHECKS_JSON=$SETTING
  [ -z "$SETTING_NOTES" ] || SCOPE_NOTES+=("$SETTING_NOTES")
  read_setting verification.containers "$config_root" || load_checks_failed
  CONTAINERS_JSON=$SETTING
  CONTAINERS_NOTES=$SETTING_NOTES
}

# load_checks_failed -> blocks. The hook shim already blocks on a missing lib
# file, so "lib missing" is said only when the reader itself is absent; a
# reader that is there and failed (a jq without --rawfile, say) is reported
# with its own error and what to check, since /myspec:update cannot fix it.
load_checks_failed() {
  GATE_UNVERIFIED=1
  if [ ! -f "$HOOK_LIB/myspec-config.sh" ]; then
    decision_block 'myspec lib missing, run /myspec:update. The settings reader (lib/myspec-config.sh) is not in %s, so no check ran.' "$HOOK_LIB"
  fi
  decision_block 'The settings reader (%s/myspec-config.sh) failed, so no check ran: %s. Check that jq is 1.6 or later (jq --version; the reader uses jq --rawfile), and run the reader to see its stderr: bash "%s/myspec-config.sh" get verification.checks --root "%s"' \
    "$HOOK_LIB" "${SETTING_NOTES:-no reason given}" "$HOOK_LIB" "${CONFIG_ROOT:-.}"
}

# run_checks <config file> -> runs each required check of the checkout
# arm_root set up. Order per check: paths (a skipped check is never refused),
# then cwd, then runIn or the R8a refusal, then the run.
run_checks() {
  local count i check name command diff_command cleanup run_in run_id truncated cleanup_note
  local remaining cap cut cleanup_cap
  load_checks "$1"
  count=$(printf '%s' "$CHECKS_JSON" | jq 'if type == "array" then length else 0 end')
  for ((i = 0; i < count; i++)); do
    check=$(printf '%s' "$CHECKS_JSON" | jq -c ".[$i]")
    [ "$(printf '%s' "$check" | jq -r '.required')" = "true" ] || continue

    name=$(printf '%s' "$check" | jq -r '.name')$ROOT_LABEL
    command=$(printf '%s' "$check" | jq -r '.command')
    diff_command=$(printf '%s' "$check" | jq -r '.diffCommand // ""')
    cleanup=$(printf '%s' "$check" | jq -r '.cleanup // ""')
    run_in=$(printf '%s' "$check" | jq -r '.runIn // empty | if type == "string" then . else "\(.)" end')
    unset MYSPEC_CHECK_WORKDIR
    check_cwd "$check"

    # A required check skipped by its paths is named in the stop message, so
    # the loosening never goes unseen.
    paths_verdict "$check"
    case "$PATHS_VERDICT" in
      skip)
        SCOPE_NOTES+=("$name: skipped, no file this session wrote matches its paths ($PATHS_GLOBS).")
        continue ;;
      ignored)
        SCOPE_NOTES+=("$name: its paths setting was ignored, so the check ran. paths must be a non-empty list of repo-relative globs, none absolute or with a .. segment${PATHS_GLOBS:+ (got $PATHS_GLOBS)}.") ;;
    esac
    [ -z "$CWD_IGNORED" ] || SCOPE_NOTES+=("$name: its cwd setting was ignored, so the check ran from the checkout root. cwd must be a repo-relative directory, not absolute and without a .. segment (got $CWD_IGNORED).")
    # A cwd missing in this checkout (a worktree made from a base that did
    # not have it yet) is a check that could not start, not one that failed.
    if [ -n "$CHECK_CWD" ] && [ ! -d "$REPO_ROOT/$CHECK_CWD" ]; then
      UNVERIFIABLE_CHECKS+=("$name")
      FAILED_OUTPUT+=("[$name not run: cwd missing] $CHECK_CWD is not a directory in $REPO_ROOT, so the check could not start there. This is not a test failure. Create the directory on this branch, or correct the check's cwd in .claude/verification.json.")
      continue
    fi

    if [ -n "${diff_command// /}" ] && [ -n "$MYSPEC_BASE_REF" ]; then
      command="$diff_command"
    fi

    # A check with runIn names where its work runs, so the gate can say where
    # this checkout is inside the container (or refuse when it is not there),
    # and its command is trusted to use that workdir. In a linked worktree, a
    # container exec without runIn would verify another tree (R8a).
    if [ -n "$run_in" ]; then
      if ! check_workdir "$REPO_ROOT" "$run_in" "$CHECK_CWD"; then
        UNVERIFIABLE_CHECKS+=("$name")
        FAILED_OUTPUT+=("[$name not run: runIn $run_in] $REFUSE_REASON This is not a test failure.")
        continue
      fi
      export MYSPEC_CHECK_WORKDIR="$CHECK_WORKDIR"
    elif [ "$ROOT_IS_LINKED" -eq 1 ] && container_exec_form "$command"; then
      UNVERIFIABLE_CHECKS+=("$name")
      FAILED_OUTPUT+=("[$name not run: unverifiable in a linked worktree] $command runs a container exec, which runs in the container's mount of the checkout it was started from (as a rule the main checkout), not $REPO_ROOT, so a result would describe another tree. This is not a test failure. Declare where it runs: give the check runIn, with the container's mount under containers in .claude/verification.json, and pass -w \"\$MYSPEC_CHECK_WORKDIR\" in its exec options; or run the tool on the host.")
      continue
    fi

    # The budget (R13): no time left, no run; less than the cap, a shorter
    # cap.
    remaining=$(gate_remaining)
    if [ "$remaining" -le 0 ]; then
      NOT_RUN_CHECKS+=("$name")
      continue
    fi
    cap=$CHECK_CAP_SECONDS
    cut=""
    if [ "$remaining" -lt "$cap" ]; then
      cap=$remaining
      cut=1
    fi

    # Exported to the check and to its cleanup, so a wrapper that starts work
    # the group kill cannot reach can tag it and the cleanup can find it.
    CHECKS_RAN=$((CHECKS_RAN + 1))
    RAN_CHECKS+=("$name")
    run_id="myspec-$(date +%s)-$$-$i"
    run_capped "$cap" "$command" "$run_id" keep
    CHECK_RUN_LOG=$RUN_LOG

    if [ "$RUN_EXIT" -ne 0 ]; then
      # Keep the end of the output: it names the result (a summary line, the
      # last error). The first 2000 characters of the last 50 lines cut that
      # end off mid-line.
      truncated=$(printf '%s\n' "$RUN_OUTPUT" | tail -50 | tail -c 2000)
      if capped "$RUN_EXIT" "$RUN_ELAPSED" "$cap"; then
        # Cleanup runs only here: a check that exited on its own took its
        # remote work with it (the client returns when that work ends).
        if [ -n "${cleanup// /}" ]; then
          cleanup_cap=$(gate_remaining)
          [ "$cleanup_cap" -ge "$GATE_CLEANUP_FLOOR" ] || cleanup_cap=$GATE_CLEANUP_FLOOR
          [ "$cleanup_cap" -le "$CLEANUP_CAP_SECONDS" ] || cleanup_cap=$CLEANUP_CAP_SECONDS
          run_capped "$cleanup_cap" "$cleanup" "$run_id"
          if [ "$RUN_EXIT" -eq 0 ]; then
            cleanup_note="Cleanup ran ($cleanup)."
          elif capped "$RUN_EXIT" "$RUN_ELAPSED" "$cleanup_cap"; then
            cleanup_note="Cleanup timed out after ${cleanup_cap}s ($cleanup): work this check started in a container, on another host or detached may still be running. Confirm it stopped before running the check again."
          else
            cleanup_note="Cleanup failed (exit $RUN_EXIT) ($cleanup): work this check started in a container, on another host or detached may still be running. Confirm it stopped before running the check again. Cleanup output: $(printf '%s\n' "$RUN_OUTPUT" | tail -10 | tail -c 600)"
          fi
        else
          cleanup_note="No cleanup declared. The kill reaches only processes on this machine that stay in the check's process group: work it runs in a container or on another host (docker exec, kubectl exec, ssh) or detaches keeps running. Confirm that stopped before running the check again, or give the check a cleanup command in .claude/verification.json."
        fi
        TIMED_OUT_CHECKS+=("$name${cut:+ (at the gate budget, ${cap}s)}")
        FAILED_OUTPUT+=("[$name timed out after ${cap}s${cut:+, the rest of the gate budget}] $command was killed before it finished, so its result is unknown. This is not a test failure. $cleanup_note Then run the check directly and report its real exit code; if it passes but is slow, reduce its runtime (narrow what it runs). Do not raise the cap. Output so far:"$'\n'"$truncated")
      else
        FAILED_CHECKS+=("$name")
        FAILED_LOGS+=("$CHECK_RUN_LOG")
        FAILED_CWDS+=("$CHECK_CWD")
        CHECK_RUN_LOG=""
        FAILED_OUTPUT+=("[$name] $command failed:"$'\n'"$truncated")
      fi
    fi
    # A passed or timed-out check's log is not needed any more.
    if [ -n "$CHECK_RUN_LOG" ]; then
      rm -f "$CHECK_RUN_LOG"
      CHECK_RUN_LOG=""
    fi
  done
}
