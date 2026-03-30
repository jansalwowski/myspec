#!/usr/bin/env bash
# verify-before-stop.sh
# Claude Code Stop hook — runs verification checks before agent completes.
# Reads commands from .claude/verification.json (requires jq).
# Outputs {"decision": "block", "reason": "..."} on failure or {"decision": "approve"} on success.

set -euo pipefail

# Prevent infinite loop: if Claude is already running due to this hook, approve immediately
if [ "${CLAUDE_STOP_HOOK_ACTIVE:-}" = "1" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Find repo root (directory containing .claude/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# Read stdin JSON (Stop hook receives session context)
INPUT=$(cat)

# Check if this session actually changed code files.
# mark-code-changed.sh (PostToolUse) touches a marker file when Claude edits code.
# This avoids running verification for brainstorming/planning sessions with pre-existing changes.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
MARKER_FILE="/tmp/.claude-code-changed-${SESSION_ID}"

if [ -z "$SESSION_ID" ] || [ ! -f "$MARKER_FILE" ]; then
  # No code files changed by Claude this session — skip verification
  echo '{"decision": "approve"}'
  exit 0
fi

# Clean up marker after verification runs (success or failure)
trap 'rm -f "$MARKER_FILE"' EXIT

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

  # Run the command with a timeout (120s max per check)
  # macOS lacks `timeout`; use `gtimeout` (brew install coreutils) if available, else run without timeout
  if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout 120"
  elif command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout 120"
  else
    TIMEOUT_CMD=""
  fi
  OUTPUT=$(cd "$REPO_ROOT" && $TIMEOUT_CMD bash -c "$COMMAND" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?

  if [ "$EXIT_CODE" -ne 0 ]; then
    FAILED_CHECKS+=("$NAME")
    # Truncate output to avoid giant JSON
    TRUNCATED=$(echo "$OUTPUT" | tail -50 | head -c 2000)
    FAILED_OUTPUT+=("[$NAME] $COMMAND failed:\n$TRUNCATED")
  fi
done

if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
  NAMES=$(IFS=", "; echo "${FAILED_CHECKS[*]}")
  DETAILS=$(IFS="\n---\n"; echo "${FAILED_OUTPUT[*]}")
  # Escape for JSON
  REASON=$(printf "Verification failed (%s). Fix errors before completing.\n\n%s" "$NAMES" "$DETAILS" | jq -Rs .)
  echo "{\"decision\": \"block\", \"reason\": $REASON}"
  exit 0
fi

echo '{"decision": "approve"}'
