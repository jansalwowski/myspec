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
#   content.sh    the content checks over the session's Bash writes (R14)
# This file parses the payload, guards re-entry and calls them in order.

set -euo pipefail

# A check the gate runs gets MYSPEC_STOP_HOOK_ACTIVE=1 (stop-gate/run.sh). A
# check that starts a nested Claude Code session (claude -p, an eval runner,
# an LLM judge) reaches this hook again from inside the gate. Approve at
# once: otherwise the inner session runs the conformance gates and, when it
# wrote code, its own checks, which can start claude again (R10).
if [ -n "${MYSPEC_STOP_HOOK_ACTIVE:-}" ]; then
  echo '{"decision": "approve", "reason": "nested session inside a stop-gate check (MYSPEC_STOP_HOOK_ACTIVE): the outer gate verifies"}'
  exit 0
fi

# Every gate below reads JSON, so without jq there is nothing to verify with.
approve() {
  echo '{"decision": "approve"}'
  exit 0
}
command -v jq >/dev/null 2>&1 || approve
PAYLOAD=$(cat)

# The libs are the plugin's lib/, reached through CLAUDE_PLUGIN_ROOT, which
# the harness exports to a hook declared in the plugin's hooks.json. A missing
# one means the hook did not run from the plugin (a stale project copy, or a
# hand-wired command): block once and say so, rather than guess at the
# checks. The continuation after that block approves (R10).
HOOK_CORE="${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"
LIB_DIR=$(dirname "$HOOK_CORE")
MISSING=""
for f in hook-core.sh session-event.sh glob-regex.sh myspec-config.sh myspec-config.schema.json \
    markdown-section-check.sh content-checks.sh stop-gate/arm.sh stop-gate/provision.sh stop-gate/run.sh \
    stop-gate/attribute.sh stop-gate/report.sh stop-gate/content.sh; do
  [ -f "$LIB_DIR/$f" ] || MISSING="${MISSING:+$MISSING, }$f"
done
if [ -n "$MISSING" ]; then
  [ "$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" != "true" ] || approve
  jq -nc --arg r "myspec lib missing: the stop gate needs $MISSING under \${CLAUDE_PLUGIN_ROOT}/lib (${CLAUDE_PLUGIN_ROOT:-unset}), so no check ran. The hook runs from the plugin's hooks.json since 3.0; a copy wired in .claude/settings.json is retired by /myspec:update." '{decision: "block", reason: $r}'
  exit 0
fi
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
# shellcheck source=lib/content-checks.sh
. "$HOOK_LIB/content-checks.sh"
# shellcheck source=lib/stop-gate/content.sh
. "$HOOK_LIB/stop-gate/content.sh"

# The gate-wide budget (R13) starts here.
gate_budget_init
payload_parse "$PAYLOAD" STOP_HOOK_ACTIVE=.stop_hook_active SESSION_ID=.session_id CWDS="$HOOK_CWDS"

# Prevent infinite loop on re-entry (R10): the harness sends
# stop_hook_active in the payload on the continuation after a prior block.
[ "$STOP_HOOK_ACTIVE" != "true" ] || approve

REPO_ROOT=$(hook_repo_root "$CWDS" myspec) || approve
conformance_gates "$REPO_ROOT"

# The content gates (R14) run before the checks, in any tracked project: a
# Bash write that leaked a path or skipped a tech-spec's reuse audit blocks
# whether or not the project has verification.json checks.
arm_init "$REPO_ROOT"
content_gates

CONFIG_FILE="$REPO_ROOT/.claude/verification.json"
[ -f "$CONFIG_FILE" ] || approve

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
