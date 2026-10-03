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
for f in session-event.sh stop-gate/arm.sh stop-gate/provision.sh stop-gate/run.sh stop-gate/attribute.sh stop-gate/report.sh; do
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
# shellcheck source=lib/stop-gate/report.sh
. "$HOOK_LIB/stop-gate/report.sh"

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
