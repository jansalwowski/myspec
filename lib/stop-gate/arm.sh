#!/usr/bin/env bash
# stop-gate/arm.sh
# lint: sourced under set -euo pipefail
# Sourced by hooks/verify-before-stop.sh, after lib/hook-core.sh and
# lib/session-event.sh; never run. Which checkouts the stop gate verifies, and
# what it knows about each before a check runs: the files the session wrote
# there, the uncommitted changes, the base ref, and the session's
# feature-implement state. Requirements: docs/stop-gate.md (R1 to R3a, R5,
# R6) in the plugin repository. Tests: lib/tests/stop-gate-arm.test.sh.
#
# Reads ORIG_ROOT, STATE_HOME, SESSION_ID (and REPO_ROOT, ROOT_KEY per root);
# reports through globals the other stop-gate modules read.
# shellcheck disable=SC2034

# Whether to verify, and which checkouts. mark-code-changed.sh (PostToolUse)
# records every file the session writes as a `write` event in the session's
# state file (lib/session-event.sh), keyed by the physical root of the
# checkout holding it. A checkout is armed when a `code` write for its root
# comes after its last `verified` event. Each armed checkout of this
# repository (same git common dir as the cwd's) is verified, once: the
# harness cwd is not necessarily where the edits are, and verifying an
# untouched main checkout while the session edited a linked worktree reports
# a green that describes the wrong tree. A research session over a dirty
# tree, and a session whose writes all landed in another repository, run no
# checks.

# arm_init <repo root> -> sets ORIG_ROOT (physical) and STATE_HOME, the main
# checkout of the cwd's repository, where the writes to every checkout of it
# are filed.
arm_init() {
  ORIG_ROOT=$(cd "$1" && pwd -P)
  STATE_HOME=$(session_home "$ORIG_ROOT") || STATE_HOME="$ORIG_ROOT"
  ORIG_COMMON=$(common_dir "$ORIG_ROOT" || printf '')
  VERIFY_ROOTS=()
  NESTED_ROOTS=()
}

# common_dir <dir> -> the physical git common dir of the checkout at <dir>.
common_dir() {
  checkout_facts "$1" || return 1
  printf '%s\n' "$CF_COMMON_DIR"
}

add_verify_root() {
  local r
  for r in ${VERIFY_ROOTS[@]+"${VERIFY_ROOTS[@]}"}; do
    [ "$r" = "$1" ] && return 0
  done
  VERIFY_ROOTS+=("$1")
}

# same_repo <root> -> 0 when <root> is a checkout of the cwd's repository (the
# cwd's own root, for a project without git).
same_repo() {
  if [ -n "$ORIG_COMMON" ]; then
    [ "$(common_dir "$1" || printf '')" = "$ORIG_COMMON" ]
  else
    [ "$1" = "$ORIG_ROOT" ]
  fi
}

# armed_roots -> fills VERIFY_ROOTS from the session's armed checkouts. A
# checkout nested inside the cwd's tree that is not a checkout of this
# repository (a submodule, whose common dir is .git/modules/<name>) is
# verified through the cwd's checkout, whose checks may build or test it. Its
# root still gets its `verified` event (NESTED_ROOTS).
armed_roots() {
  local root
  [ -n "$SESSION_ID" ] || return 0
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    if same_repo "$root"; then
      add_verify_root "$root"
    else
      case "$root/" in
        "$ORIG_ROOT"/*)
          add_verify_root "$ORIG_ROOT"
          NESTED_ROOTS+=("$root")
          ;;
      esac
    fi
  done < <(session_armed_roots "$STATE_HOME" "$SESSION_ID")
}

# Once the checks run (success or failure), the state file gets a `verified`
# event for each verified checkout, so only a later code write re-arms it.
# The writes stay: they are the list of what this session wrote, which
# attribution needs on every later run. A run that could not read its
# checks (GATE_UNVERIFIED, run.sh) records nothing.
finish_run() {
  local r
  [ "${GATE_UNVERIFIED:-0}" -eq 0 ] || return 0
  for r in "${VERIFY_ROOTS[@]}" ${NESTED_ROOTS[@]+"${NESTED_ROOTS[@]}"}; do
    session_append "$STATE_HOME" "$SESSION_ID" "$(jq -nc --arg r "$r" '{t: "verified", root: $r}')" || true
  done
}

# session_files -> repo-relative paths this session wrote in the checkout at
# ROOT_KEY, including those in a checkout nested inside it (a submodule).
session_files() {
  session_written "$STATE_HOME" "$SESSION_ID" "$ROOT_KEY"
}

# changed_files -> uncommitted and untracked paths in REPO_ROOT, both sides of
# a rename.
changed_files() {
  local entry second=0
  while IFS= read -r -d '' entry; do
    if [ "$second" -eq 1 ]; then
      second=0
      printf '%s\n' "$entry"
      continue
    fi
    printf '%s\n' "${entry:3}"
    case "${entry:0:2}" in
      *R*|*C*) second=1 ;;
    esac
  done < <(git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
}

# base_ref -> sets MYSPEC_BASE_REF for REPO_ROOT (R5). A repo whose lint or
# type-check is already red on the default branch cannot use a whole-repo
# command as a gate: it blocks every stop over debt this session did not
# create. Such a check declares a `diffCommand`, and this is the ref it
# measures against: the merge base with the default branch, so the range is
# "what this branch changed" on a feature branch and "what is uncommitted"
# when HEAD is that branch. Empty when no default branch resolves (no remote
# and no main/master); the check then runs its whole-repo command.
base_ref() {
  local default candidate
  MYSPEC_BASE_REF=""
  default=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
  if [ -z "$default" ]; then
    for candidate in origin/main origin/master main master; do
      if git -C "$REPO_ROOT" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
        default="$candidate"
        break
      fi
    done
  fi
  if [ -n "$default" ]; then
    MYSPEC_BASE_REF=$(git -C "$REPO_ROOT" merge-base HEAD "$default" 2>/dev/null || printf '')
  fi
}

# arm_root <root> -> per-checkout state for the checks of <root>: REPO_ROOT,
# ROOT_KEY, ROOT_LABEL (names a check by its checkout when that is not the
# cwd's), ROOT_IS_LINKED, MYSPEC_SESSION_FILES (one repo-relative path per
# line, for a check that scopes itself to them, a per-file linter) and
# MYSPEC_BASE_REF, both exported to the checks.
arm_root() {
  REPO_ROOT="$1"
  ROOT_KEY="$1"
  ROOT_LABEL=""
  [ "$1" = "$ORIG_ROOT" ] || ROOT_LABEL=" [in $1]"
  ROOT_IS_LINKED=0
  is_linked_worktree "$1" && ROOT_IS_LINKED=1
  MYSPEC_SESSION_FILES=$(session_files)
  export MYSPEC_SESSION_FILES
  UNSEEN_READY=0
  UNSEEN_FILES=""
  base_ref
  export MYSPEC_BASE_REF
}

# is_linked_worktree <dir> -> 0 when <dir> is a linked worktree, or a
# submodule checked out inside one, not a main checkout. A submodule's git
# dir is its own common dir, so its superproject decides: a submodule of a
# linked worktree sits in that worktree's tree, and the containers its
# checks reach were started from the main checkout's copy.
is_linked_worktree() {
  checkout_facts "$1" || return 1
  [ "$CF_LINKED" = 1 ] && return 0
  [ "$CF_SUBMODULE" = 1 ] && is_linked_worktree "$CF_SUPER"
}

# Orchestration state (R6). While /myspec:feature-implement runs, the
# controller ends many turns on a tree that is red by design: a barrier
# accepted with a recorded failure, a fix round in flight in a subagent, a
# failing test owned by the next phase. Blocking there forces a turn the
# controller cannot use, so failures downgrade to a non-blocking warning. The
# state is the session's own, read once for the whole session: the task
# worktrees its subagents edit share the session id, so the same state covers
# them. A start older than HOOK_DECISION_TTL (8h) is a crashed run, and the
# gate blocks. Only the verification.json checks are downgraded; the
# conformance and provision blocks are session damage, not expected red.
# implement_state -> sets IMPLEMENT_ACTIVE to 1 or 0.
implement_state() {
  IMPLEMENT_ACTIVE=0
  if session_implement_active "$STATE_HOME" "$SESSION_ID"; then
    IMPLEMENT_ACTIVE=1
  fi
}
