#!/usr/bin/env bash
# verify-before-stop.sh
# Stop hook — runs verification checks before agent completes.
# Reads commands from .claude/verification.json (requires jq).
# Outputs {"decision": "block", "reason": "..."} on failure or {"decision": "approve"} on success.

set -euo pipefail

# Read stdin JSON (Stop hook receives session context)
INPUT=$(cat)

# Prevent infinite loop on re-entry. The harness signals this via
# stop_hook_active in the stdin JSON (the continuation after a prior block);
# env vars kept as a fallback for hosts that set them instead.
if command -v jq >/dev/null 2>&1; then
  if [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    echo '{"decision": "approve"}'
    exit 0
  fi
fi
if [ "${CLAUDE_STOP_HOOK_ACTIVE:-}" = "1" ] || [ "${MYSPEC_STOP_HOOK_ACTIVE:-}" = "1" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

resolve_repo_root() {
  local candidate resolved

  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if resolved=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
        printf '%s\n' "$resolved"
        return 0
      fi
      if [ -f "$candidate/.myspec.json" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done <<EOF
$(printf '%s' "$INPUT" | jq -r '
  [
    .cwd,
    .workdir,
    .workspace.cwd,
    .session.cwd,
    .tool_input.cwd,
    .tool_input.workdir
  ] | map(select(type == "string" and . != "")) | .[]
' 2>/dev/null)
EOF
  fi

  if resolved=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if resolved=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

if ! REPO_ROOT="$(resolve_repo_root)"; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Memory conformance. The index tables are generated and the ID allocator
# refuses on drift, so drift a session leaves behind (an unregenerated index, a
# memory without hook:, a duplicate ID) should surface here, in the session that
# caused it, not in the next session's claim. Gated on uncommitted changes under
# the memory tree: pre-existing drift the agent never touched is bootstrap's to
# report, not a reason to block a stop.
DOCTOR="$REPO_ROOT/.claude/lib/memory-doctor.mjs"
if [ -f "$DOCTOR" ] && [ -f "$REPO_ROOT/.myspec.json" ] && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  MEMORY_AI_DIR=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null | sed 's#/*$##')
  if [ -z "$MEMORY_AI_DIR" ]; then
    if [ -d "$REPO_ROOT/.ai" ] || [ ! -d "$REPO_ROOT/ai" ]; then MEMORY_AI_DIR=".ai"; else MEMORY_AI_DIR="ai"; fi
  fi
  if [ -n "$MEMORY_AI_DIR" ] && git -C "$REPO_ROOT" status --porcelain -- "$MEMORY_AI_DIR/memory" 2>/dev/null | grep -q .; then
    if ! DOCTOR_OUT=$(cd "$REPO_ROOT" && node "$DOCTOR" --quiet 2>&1); then
      REASON=$(printf 'Memory conformance check failed for changes under %s/memory. Fix these before stopping (node .claude/lib/memory-index.mjs regenerates the tables; the doctor names the rest):\n\n%s' "$MEMORY_AI_DIR" "$(printf '%s' "$DOCTOR_OUT" | tail -30)" | jq -Rs .)
      echo "{\"decision\": \"block\", \"reason\": $REASON}"
      exit 0
    fi
  fi
fi

# Setup conformance. Only the wiring and schema groups: a hook that is
# registered but missing, not executable, or fails bash -n is silently inert,
# and an unparseable .myspec.json or verification.json degrades this very gate
# to approve — all of them are damage the session just did and can undo now.
# Framework drift is deliberately excluded: its usual cause is a pending
# /myspec:update, and blocking on that would halt every commit made between a
# plugin release and the next update run. The features group is excluded too —
# it reads a file under the aiDir, outside the trigger below, so including it
# would block a stop over something this session never touched. Gated on
# uncommitted changes to the harness config, for the same reason the memory
# check above is gated.
SETUP_DOCTOR="$REPO_ROOT/.claude/lib/setup-doctor.mjs"
if [ -f "$SETUP_DOCTOR" ] && [ -f "$REPO_ROOT/.myspec.json" ] && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" status --porcelain -- .claude .myspec.json 2>/dev/null | grep -q .; then
    if ! SETUP_OUT=$(cd "$REPO_ROOT" && node "$SETUP_DOCTOR" --quiet wiring schema 2>&1); then
      REASON=$(printf 'Setup conformance check failed for changes under .claude/ or .myspec.json. Each of these makes a hook or a gate silently stop working, so fix them before stopping:\n\n%s' "$(printf '%s' "$SETUP_OUT" | tail -30)" | jq -Rs .)
      echo "{\"decision\": \"block\", \"reason\": $REASON}"
      exit 0
    fi
  fi
fi

CONFIG_FILE="$REPO_ROOT/.claude/verification.json"

# If no config file, skip (graceful degradation)
if [ ! -f "$CONFIG_FILE" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check if jq is available
if ! command -v jq &>/dev/null; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check if this session actually changed code files.
# mark-code-changed.sh (PostToolUse) touches a marker file when the agent edits code.
# This avoids running verification for brainstorming/planning sessions with pre-existing changes.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
MARKER_FILE="/tmp/.myspec-code-changed-${SESSION_ID}"

if [ -z "$SESSION_ID" ] || [ ! -f "$MARKER_FILE" ]; then
  # No code files changed by Claude this session — skip verification
  echo '{"decision": "approve"}'
  exit 0
fi

# A symlinked node_modules makes every check below run against ANOTHER
# checkout dependency tree, so the gate reports a green that describes the
# wrong tree. That silent false pass is worse than no gate at all, so block.
# The marker is deliberately left in place (the EXIT trap is registered below)
# so the block persists until a real install exists.
# Deliberate link: export MYSPEC_ALLOW_LINKED_MODULES=1 before launching.
if [ -L "$REPO_ROOT/node_modules" ] && [ "${MYSPEC_ALLOW_LINKED_MODULES:-}" != "1" ]; then
  REASON=$(printf 'node_modules in %s is a symlink, so lint, type-check and test results here describe a different checkout dependency tree. Run a real install in this worktree before reporting any result as verified.' "$REPO_ROOT" | jq -Rs .)
  echo "{\"decision\": \"block\", \"reason\": $REASON}"
  exit 0
fi

# Clean up marker after verification runs (success or failure)
trap 'rm -f "$MARKER_FILE"' EXIT

# 120s cap per check. Stock macOS has neither `timeout` nor `gtimeout` (the
# latter needs coreutils), and the previous prefix-string form degraded to no
# cap at all on exactly that machine — the gate then hangs on a stuck check
# instead of failing it, which reads as a frozen agent. perl is in the macOS
# base system; alarm(2) survives exec, so SIGALRM terminates the bash -c child
# at the deadline (exit 142). A function, not a command prefix: the perl form
# cannot survive the word-splitting an unquoted $TIMEOUT_CMD relies on.
run_with_cap() {
  if command -v gtimeout &>/dev/null; then
    gtimeout 120 bash -c "$1"
  elif command -v timeout &>/dev/null; then
    timeout 120 bash -c "$1"
  else
    perl -e 'alarm 120; exec @ARGV' bash -c "$1"
  fi
}

# Run each required check
FAILED_CHECKS=()
FAILED_OUTPUT=()

CHECKS_COUNT=$(jq '.checks | length' "$CONFIG_FILE")

for i in $(seq 0 $((CHECKS_COUNT - 1))); do
  REQUIRED=$(jq -r ".checks[$i].required" "$CONFIG_FILE")
  if [ "$REQUIRED" != "true" ]; then
    continue
  fi

  NAME=$(jq -r ".checks[$i].name" "$CONFIG_FILE")
  COMMAND=$(jq -r ".checks[$i].command" "$CONFIG_FILE")

  OUTPUT=$(cd "$REPO_ROOT" && MYSPEC_STOP_HOOK_ACTIVE=1 run_with_cap "$COMMAND" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?

  if [ "$EXIT_CODE" -ne 0 ]; then
    FAILED_CHECKS+=("$NAME")
    # Truncate output to avoid giant JSON
    TRUNCATED=$(echo "$OUTPUT" | tail -50 | head -c 2000)
    FAILED_OUTPUT+=("[$NAME] $COMMAND failed:"$'\n'"$TRUNCATED")
  fi
done

if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
  NAMES=$(printf '%s, ' "${FAILED_CHECKS[@]}"); NAMES=${NAMES%, }
  # Join with real newline-delimited separators (multi-char IFS joins only
  # use the first character, so the old IFS="\n---\n" emitted literal '\')
  DETAILS=""
  for ENTRY in "${FAILED_OUTPUT[@]}"; do
    DETAILS+="${ENTRY}"$'\n---\n'
  done
  DETAILS=${DETAILS%$'\n---\n'}
  # Escape for JSON
  REASON=$(printf "Verification failed (%s). Fix errors before completing.\n\n%s" "$NAMES" "$DETAILS" | jq -Rs .)
  echo "{\"decision\": \"block\", \"reason\": $REASON}"
  exit 0
fi

echo '{"decision": "approve"}'
