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
for f in session-event.sh stop-gate/arm.sh stop-gate/provision.sh stop-gate/run.sh stop-gate/attribute.sh; do
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
# shellcheck source=lib/stop-gate/run.sh
. "$HOOK_LIB/stop-gate/run.sh"
# shellcheck source=lib/stop-gate/attribute.sh
. "$HOOK_LIB/stop-gate/attribute.sh"
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
