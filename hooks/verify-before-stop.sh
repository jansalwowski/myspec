#!/usr/bin/env bash
# verify-before-stop.sh
# Stop hook: runs the checks in .claude/verification.json before the agent
# completes, in each checkout of this repository where the session wrote code
# since the last run. Prints {"decision": "block", "reason": ...} on a
# failure, else {"decision": "approve"} (with a systemMessage when something
# was skipped or only warns). Requirements behind each rule: docs/stop-gate.md
# in the plugin repository.
#
# The work is in lib/stop-gate/, one module per part, each with its own
# function tests (lib/tests/stop-gate-*.test.sh):
#   arm.sh        which checkouts are armed, and what the session wrote there
#   provision.sh  the provision-record comparison in a linked worktree (R8)
#   run.sh        loading checks, paths/cwd/runIn verdicts, the capped runner
#   attribute.sh  whether a checkout's failures block or warn (R4, R6)
#   report.sh     the conformance gates and the decision
# This file parses the payload, guards re-entry and calls them in order.

set -euo pipefail

# Every gate below reads JSON, so without jq or the shared lib there is
# nothing to verify with.
approve() {
  echo '{"decision": "approve"}'
  exit 0
}
command -v jq >/dev/null 2>&1 || approve
HOOK_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/hook-core.sh"
[ -f "$HOOK_CORE" ] || HOOK_CORE="${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"
LIB_DIR=$(dirname "$HOOK_CORE")
for f in session-event.sh stop-gate/arm.sh stop-gate/provision.sh; do
  if [ ! -f "$HOOK_CORE" ] || [ ! -f "$LIB_DIR/$f" ]; then approve; fi
done
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/session-event.sh
. "$HOOK_LIB/session-event.sh"
# shellcheck source=lib/stop-gate/arm.sh
. "$HOOK_LIB/stop-gate/arm.sh"
# shellcheck source=lib/stop-gate/provision.sh
. "$HOOK_LIB/stop-gate/provision.sh"
# Per-check time cap (R7). A check that outlives it is killed and reported as
# timed out: the result is unknown, which is not a failure, and the report
# must say which one it is (a green suite killed at the cap once read as a
# red one). MYSPEC_CHECK_CAP_SECONDS may lower the cap (the hook tests use
# it); a value above the default is ignored, so it can never raise it. A
# check's cleanup command gets its own cap, lowered with the check cap and
# never above 30 s.
CHECK_CAP_DEFAULT=120
CLEANUP_CAP_DEFAULT=30

# run_init -> the caps, the cap sentinel and the result arrays.
run_init() {
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
# names the ignored setting (fail closed). Without the compiler every
# `paths` is ignored the same way.
declare -F glob_regex >/dev/null || glob_regex() { return 1; }

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
# REFUSE_REASON when the check cannot run there. Reads CONTAINERS_JSON and
# CONTAINERS_NOTES (load_checks).
check_workdir() {
  local spec src tgt main base self rel sub=""
  CHECK_WORKDIR=""
  REFUSE_REASON=""
  if [ -z "$CONTAINERS_JSON" ]; then
    REFUSE_REASON="runIn names container \"$2\", but the containers setting could not be read (lib/myspec-config.sh was not found next to this hook)."
    return 1
  fi
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
# Without the reader, the checks are read from the file as before;
# CONTAINERS_JSON stays empty and a runIn check is refused.
load_checks() {
  local config_root
  config_root=$(dirname "$(dirname "$1")")
  CONTAINERS_JSON=""
  CONTAINERS_NOTES=""
  if read_setting verification.checks "$config_root"; then
    CHECKS_JSON=$SETTING
    [ -z "$SETTING_NOTES" ] || SCOPE_NOTES+=("$SETTING_NOTES")
    if read_setting verification.containers "$config_root"; then
      CONTAINERS_JSON=$SETTING
      CONTAINERS_NOTES=$SETTING_NOTES
    fi
  else
    CHECKS_JSON=$(jq -c '.checks' "$1")
  fi
}

# run_checks <config file> -> runs each required check of the checkout
# arm_root set up. Order per check: paths (a skipped check is never refused),
# then cwd, then runIn or the R8a refusal, then the run.
run_checks() {
  local count i check name command diff_command cleanup run_in run_id truncated cleanup_note
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
      FAILED_OUTPUT+=("[$name not run: cwd $CHECK_CWD] $CHECK_CWD is not a directory in $REPO_ROOT, so the check could not start there. This is not a test failure. Create the directory on this branch, or correct the check's cwd in .claude/verification.json.")
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

    # Exported to the check and to its cleanup, so a wrapper that starts work
    # the group kill cannot reach can tag it and the cleanup can find it.
    CHECKS_RAN=$((CHECKS_RAN + 1))
    run_id="myspec-$(date +%s)-$$-$i"
    run_capped "$CHECK_CAP_SECONDS" "$command" "$run_id" keep
    CHECK_RUN_LOG=$RUN_LOG

    if [ "$RUN_EXIT" -ne 0 ]; then
      # Keep the end of the output: it names the result (a summary line, the
      # last error). The first 2000 characters of the last 50 lines cut that
      # end off mid-line.
      truncated=$(printf '%s\n' "$RUN_OUTPUT" | tail -50 | tail -c 2000)
      if capped "$RUN_EXIT" "$RUN_ELAPSED" "$CHECK_CAP_SECONDS"; then
        # Cleanup runs only here: a check that exited on its own took its
        # remote work with it (the client returns when that work ends).
        if [ -n "${cleanup// /}" ]; then
          run_capped "$CLEANUP_CAP_SECONDS" "$cleanup" "$run_id"
          if [ "$RUN_EXIT" -eq 0 ]; then
            cleanup_note="Cleanup ran ($cleanup)."
          elif capped "$RUN_EXIT" "$RUN_ELAPSED" "$CLEANUP_CAP_SECONDS"; then
            cleanup_note="Cleanup timed out after ${CLEANUP_CAP_SECONDS}s ($cleanup): work this check started in a container, on another host or detached may still be running. Confirm it stopped before running the check again."
          else
            cleanup_note="Cleanup failed (exit $RUN_EXIT) ($cleanup): work this check started in a container, on another host or detached may still be running. Confirm it stopped before running the check again. Cleanup output: $(printf '%s\n' "$RUN_OUTPUT" | tail -10 | tail -c 600)"
          fi
        else
          cleanup_note="No cleanup declared. The kill reaches only processes on this machine that stay in the check's process group: work it runs in a container or on another host (docker exec, kubectl exec, ssh) or detaches keeps running. Confirm that stopped before running the check again, or give the check a cleanup command in .claude/verification.json."
        fi
        TIMED_OUT_CHECKS+=("$name")
        FAILED_OUTPUT+=("[$name timed out after ${CHECK_CAP_SECONDS}s] $command was killed before it finished, so its result is unknown. This is not a test failure. $cleanup_note Then run the check directly and report its real exit code; if it passes but is slow, reduce its runtime (narrow what it runs). Do not raise the cap. Output so far:"$'\n'"$truncated")
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
# attribute_init -> the notes the report reads. A failure blocks unless the
# session is in a live feature-implement run or attribution clears it.
attribute_init() {
  BLOCKING_FAILURE=0
  WARN_NOTES=()
  BLOCK_NOTES=()
}

# attribute_begin -> marks where the current checkout's results start in the
# run.sh arrays.
attribute_begin() {
  ROOT_FAILURES=${#FAILED_OUTPUT[@]}
  ROOT_FAILED_START=${#FAILED_CHECKS[@]}
  ROOT_TIMED_START=${#TIMED_OUT_CHECKS[@]}
  ROOT_UNVERIFIABLE_START=${#UNVERIFIABLE_CHECKS[@]}
}

# names_in <base|full> <paths file> <output file> [cwd] -> the listed paths the
# output names. The output is split into runs of path characters, and each run
# is looked up: by basename in base mode; in full mode as a repo-relative path,
# once a leading ./ or this checkout's root (ROOT_KEY) is dropped, and, for a
# check run from a cwd, also as <cwd>/<run>: a tool there prints paths
# relative to it (src/Foo.php for api/src/Foo.php). A lookup,
# not a substring scan per path, keeps a multi-megabyte test log under a
# second. Every awk here runs under LC_ALL=C: a check's log can hold bytes
# that are not valid in the locale's encoding, and macOS awk then exits 2
# ("towc: multibyte conversion failure"), which under set -e ended the hook
# before it decided. Bytes are all the matching needs.
names_in() {
  LC_ALL=C MODE="$1" ROOT="$ROOT_KEY/" CWD="${4:-}" awk '
    FILENAME == ARGV[1] {
      key = $0
      if (ENVIRON["MODE"] == "base") sub(/.*\//, "", key)
      if (key == "") next
      if (key in want) want[key] = want[key] "\n" $0
      else want[key] = $0
      next
    }
    {
      gsub(/[^A-Za-z0-9_.@\/-]+/, " ")
      n = split($0, tok, " ")
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t in seen) continue
        seen[t] = 1
        sub(/\.+$/, "", t)
        if (ENVIRON["MODE"] == "base") {
          sub(/.*\//, "", t)
        } else {
          r = ENVIRON["ROOT"]
          if (substr(t, 1, length(r)) == r) t = substr(t, length(r) + 1)
          while (substr(t, 1, 2) == "./") t = substr(t, 3)
          if (!(t in want) && ENVIRON["CWD"] != "" && ((ENVIRON["CWD"] "/" t) in want)) t = ENVIRON["CWD"] "/" t
        }
        if ((t in want) && !(t in hit)) {
          hit[t] = 1
          print want[t]
        }
      }
    }' "$2" "$3"
}

# join_lines <max> -> the first <max> lines of stdin joined with ", ". It
# reads all of stdin: `head` would exit early, and under pipefail the
# writer's SIGPIPE would become the hook's own exit, with no decision printed.
join_lines() {
  LC_ALL=C awk -v max="$1" 'NR <= max { printf "%s%s", (NR > 1 ? ", " : ""), $0 }'
}

# short_list <file> <max> -> "a, b, c and N more"
short_list() {
  local total list
  total=$(grep -c . "$1" || true)
  list=$(join_lines "$2" < "$1")
  if [ "$total" -gt "$2" ]; then
    list="$list and $((total - $2)) more"
  fi
  printf '%s' "$list"
}

# attribute_failures: for the checks of the checkout at ROOT_KEY (from index
# ROOT_FAILED_START on, T from MYSPEC_SESSION_FILES), sets ATTRIBUTION (a paragraph for the report, empty
# when every uncommitted change there is this session's) and ATTRIBUTION_WARN=1
# when its failures should warn instead of block.
attribute_failures() {
  local tfile ffile i own foreign where lines="" unknown=0 owned=0
  ATTRIBUTION=""
  ATTRIBUTION_WARN=0
  tfile=$(mktemp "${TMPDIR:-/tmp}/.myspec-attr.XXXXXX")
  ffile=$(mktemp "${TMPDIR:-/tmp}/.myspec-attr.XXXXXX")
  # T is MYSPEC_SESSION_FILES, which arm_root read once for this checkout:
  # reading the state file again here would parse it twice per failing root.
  [ -z "${MYSPEC_SESSION_FILES:-}" ] || printf '%s\n' "$MYSPEC_SESSION_FILES" > "$tfile"
  # .claude/state/ is per-checkout hook state, not anyone's work. At most 1000
  # paths take part: past that, a failure matches nothing, which blocks.
  changed_files | grep -v '^\.claude/state/' | sort -u | grep -vxF -f "$tfile" | LC_ALL=C awk 'NR <= 1000' > "$ffile" || true
  if [ ! -s "$ffile" ]; then
    rm -f "$tfile" "$ffile"
    return 0
  fi
  for ((i = ROOT_FAILED_START; i < ${#FAILED_CHECKS[@]}; i++)); do
    own=$(names_in base "$tfile" "${FAILED_LOGS[$i]}" | join_lines 5)
    if [ -n "$own" ]; then
      owned=1
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names files this session wrote: $own"
      continue
    fi
    foreign=$(names_in full "$ffile" "${FAILED_LOGS[$i]}" "${FAILED_CWDS[$i]:-}" | join_lines 5)
    if [ -n "$foreign" ]; then
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names only files changed outside this session: $foreign"
    else
      unknown=1
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names none of the changed files"
    fi
  done
  if [ "$owned" -eq 0 ] && [ "$unknown" -eq 0 ] && [ ${#TIMED_OUT_CHECKS[@]} -eq "$ROOT_TIMED_START" ] \
      && [ ${#UNVERIFIABLE_CHECKS[@]} -eq "$ROOT_UNVERIFIABLE_START" ]; then
    ATTRIBUTION_WARN=1
  fi
  where="This checkout"
  [ "$ROOT_KEY" = "$ORIG_ROOT" ] || where="The checkout at $ROOT_KEY"
  ATTRIBUTION="$where has uncommitted changes this session did not write ($(short_list "$ffile" 10)), so a failure may not be yours.$lines"
  rm -f "$tfile" "$ffile"
}

# attribute_root -> after the current checkout's checks ran: nothing when
# they all passed; a warning during a live feature-implement run (R6) or when
# attribution clears every failure (R4); otherwise BLOCKING_FAILURE=1, with
# the attribution paragraph when there is one.
attribute_root() {
  [ "${#FAILED_OUTPUT[@]}" -gt "$ROOT_FAILURES" ] || return 0
  if [ "$IMPLEMENT_ACTIVE" -eq 1 ]; then
    WARN_NOTES+=("Failing${ROOT_LABEL} during feature-implement orchestration; not blocking (session-event.sh implement start). The final verification step still gates.")
    return 0
  fi
  ATTRIBUTION=""
  ATTRIBUTION_WARN=0
  if [ "${#FAILED_CHECKS[@]}" -gt "$ROOT_FAILED_START" ]; then
    attribute_failures
  fi
  if [ "$ATTRIBUTION_WARN" -eq 1 ]; then
    # The failures are real, but they name only files another session left
    # uncommitted.
    WARN_NOTES+=("Not blocking: every failure${ROOT_LABEL} names only files changed outside this session. $ATTRIBUTION"$'\n'"A worktree per session keeps each session's gate to its own changes.")
  else
    BLOCKING_FAILURE=1
    if [ -n "$ATTRIBUTION" ]; then
      BLOCK_NOTES+=("$ATTRIBUTION")
    fi
  fi
}
# conformance_gates <repo root> -> blocks (decision_block exits) on memory or
# setup conformance errors under uncommitted changes.
# Memory: the index tables are generated and the ID allocator refuses on
# drift, so drift a session leaves behind (an unregenerated index, a memory
# without hook:, a duplicate ID) should surface here, in the session that
# caused it. Gated on uncommitted changes under the memory tree: pre-existing
# drift the agent never touched is bootstrap's to report. Only errors block
# (the doctor exits 1 on errors alone): a duplicate ID that lives only on
# stale branches is a warning, since no change in this session can fix it
# (#124).
# Setup: only the wiring and schema groups. A hook that is registered but
# missing, not executable, or fails bash -n is silently inert, and an
# unparseable .myspec.json or verification.json degrades this very gate: all
# of them are damage the session just did and can undo now. Framework drift
# is excluded (its usual cause is a pending /myspec:update), and so is the
# features group, which reads a file outside the trigger below. Gated on
# uncommitted changes to the harness config, as the memory check is.
# Both use $(...) and -n, not `| grep -q .`: grep exits on the first line, a
# status longer than a pipe buffer then kills git with SIGPIPE, and under
# pipefail the `if` read false and skipped the gate.
conformance_gates() {
  local root="$1" doctor="$1/.claude/lib/memory-doctor.mjs" setup="$1/.claude/lib/setup-doctor.mjs" ai out
  [ -f "$root/.myspec.json" ] && command -v node >/dev/null 2>&1 || return 0
  if [ -f "$doctor" ]; then
    # aiDir is required since 2.0; .ai is the documented default when absent,
    # the same resolution memory-files.mjs uses.
    ai=$(ai_dir "$root")
    if [ -n "$ai" ] && [ -n "$(git -C "$root" status --porcelain -- "$ai/memory" 2>/dev/null)" ]; then
      if ! out=$(cd "$root" && node "$doctor" --quiet 2>&1); then
        decision_block 'Memory conformance check failed for changes under %s/memory. Fix these before stopping (node .claude/lib/memory-index.mjs regenerates the tables; the doctor names the rest):\n\n%s' "$ai" "$(printf '%s' "$out" | tail -30)"
      fi
    fi
  fi
  if [ -f "$setup" ] && [ -n "$(git -C "$root" status --porcelain -- .claude .myspec.json 2>/dev/null)" ]; then
    if ! out=$(cd "$root" && node "$setup" --quiet wiring schema 2>&1); then
      decision_block 'Setup conformance check failed for changes under .claude/ or .myspec.json. Each of these makes a hook or a gate silently stop working, so fix them before stopping:\n\n%s' "$(printf '%s' "$out" | tail -30)"
    fi
  fi
}

# report_decision -> prints the decision and exits 0. Reads the run.sh
# arrays, the attribute.sh notes and SCOPE_NOTES. Sets GATE_DECIDED=1 just
# before the decision goes out: finish_run records `verified` only then, so a
# hook that dies on the way (set -e) leaves its checkouts armed.
report_decision() {
  local scope="" names="" timed unver details="" notes entry headline message
  # One line per note, deduplicated (a note from the reader repeats per root).
  if [ "${#SCOPE_NOTES[@]}" -gt 0 ]; then
    scope="Scope: $(printf '%s\n' "${SCOPE_NOTES[@]}" | LC_ALL=C awk '!seen[$0]++ { printf "%s%s", (n++ ? " " : ""), $0 }')"
  fi

  if [ ${#FAILED_CHECKS[@]} -gt 0 ] || [ ${#TIMED_OUT_CHECKS[@]} -gt 0 ] || [ ${#UNVERIFIABLE_CHECKS[@]} -gt 0 ]; then
    # The headline separates the outcomes: "failed" is a result, "timed out"
    # and "not run" are the absence of one.
    if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
      names=$(printf '%s, ' "${FAILED_CHECKS[@]}"); names="failed: ${names%, }"
    fi
    if [ ${#TIMED_OUT_CHECKS[@]} -gt 0 ]; then
      timed=$(printf '%s, ' "${TIMED_OUT_CHECKS[@]}"); timed="timed out after ${CHECK_CAP_SECONDS}s, result unknown: ${timed%, }"
      names="${names:+$names; }$timed"
    fi
    if [ ${#UNVERIFIABLE_CHECKS[@]} -gt 0 ]; then
      unver=$(printf '%s, ' "${UNVERIFIABLE_CHECKS[@]}"); unver="not run, unverifiable here: ${unver%, }"
      names="${names:+$names; }$unver"
    fi
    # Real newline-delimited separators: a multi-char IFS join uses only its
    # first character (4eb8ccb).
    for entry in "${FAILED_OUTPUT[@]}"; do
      details+="${entry}"$'\n---\n'
    done
    details=${details%$'\n---\n'}
    notes="${scope:+$scope$'\n\n'}"
    for entry in ${WARN_NOTES[@]+"${WARN_NOTES[@]}"}; do
      notes+="${entry}"$'\n\n'
    done
    if [ "$BLOCKING_FAILURE" -eq 0 ]; then
      # Non-blocking: no decision block, so the stop proceeds; systemMessage
      # surfaces the failure to the user.
      message=$(printf "Verification failing (%s).\n\n%s%s" "$names" "$notes" "$details" | jq -Rs .)
      GATE_DECIDED=1
      echo "{\"decision\": \"approve\", \"systemMessage\": $message}"
      exit 0
    fi
    if [ "${#BLOCK_NOTES[@]}" -gt 0 ]; then
      for entry in "${BLOCK_NOTES[@]}"; do
        notes+="${entry}"$'\n\n'
      done
      notes+="Fix what your changes broke. Do not edit files changed outside this session to make a check pass: another session sharing this checkout may be working on them. If a failure comes from those changes, say so and stop. A Bash side effect (an install, code generation) is not recorded as this session's write, so if you made one of those changes, it is yours."$'\n\n'
    fi
    GATE_DECIDED=1
    decision_block "Verification did not pass (%s). Fix the failures your changes caused before completing; for a timeout, get the real result first.\n\n%s%s" "$names" "$notes" "$details"
  fi

  if [ -n "$scope" ]; then
    headline="Verification passed."
    [ "$CHECKS_RAN" -gt 0 ] || headline="Verification ran no check."
    message=$(printf '%s %s' "$headline" "$scope" | jq -Rs .)
    GATE_DECIDED=1
    echo "{\"decision\": \"approve\", \"systemMessage\": $message}"
    exit 0
  fi
  GATE_DECIDED=1
  echo '{"decision": "approve"}'
  exit 0
}

payload_parse "$(cat)" STOP_HOOK_ACTIVE=.stop_hook_active SESSION_ID=.session_id CWDS="$HOOK_CWDS"

# Prevent infinite loop on re-entry (R10). The harness signals this via
# stop_hook_active in the stdin JSON (the continuation after a prior block);
# env vars kept as a fallback for hosts that set them instead.
if [ "$STOP_HOOK_ACTIVE" = "true" ] || [ "${CLAUDE_STOP_HOOK_ACTIVE:-}" = "1" ] \
    || [ "${MYSPEC_STOP_HOOK_ACTIVE:-}" = "1" ]; then
  approve
fi

REPO_ROOT=$(hook_repo_root "$CWDS" myspec) || approve
conformance_gates "$REPO_ROOT"

CONFIG_FILE="$REPO_ROOT/.claude/verification.json"
[ -f "$CONFIG_FILE" ] || approve

arm_init "$REPO_ROOT"
armed_roots
# No code written in this repository since the last run: nothing to verify.
[ "${#VERIFY_ROOTS[@]}" -gt 0 ] || approve
provision_check "${VERIFY_ROOTS[@]}"

run_init
# finish_run records `verified` only once report_decision printed a decision
# (GATE_DECIDED): an abort before that leaves every checkout armed.
trap 'finish_run; run_cleanup_files' EXIT
implement_state
attribute_init
for root in "${VERIFY_ROOTS[@]}"; do
  arm_root "$root"
  attribute_begin
  config="$root/.claude/verification.json"
  [ -f "$config" ] || config="$CONFIG_FILE"
  run_checks "$config"
  attribute_root
done
rm -f "$CAP_SENTINEL"
report_decision
