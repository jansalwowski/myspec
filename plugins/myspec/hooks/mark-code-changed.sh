#!/usr/bin/env bash
# mark-code-changed.sh
# PostToolUse hook — marks that code files were changed in this session.
# Creates a session-scoped marker file so verify-before-stop.sh only runs
# verification when the current session actually modified code.

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Only mark for code files (not docs, config, etc.)
# Common extensions across multiple stacks — add more as needed
if [[ "$FILE_PATH" =~ \.(ts|tsx|vue|js|jsx|mts|cts|py|rb|go|java|php|rs|cs|swift|kt)$ ]]; then
  touch "/tmp/.myspec-code-changed-${SESSION_ID}"
fi

exit 0
