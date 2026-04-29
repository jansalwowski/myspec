#!/usr/bin/env bash
# mark-code-changed.sh
# PostToolUse hook — marks that code files were changed in this session.
# Creates a session-scoped marker file so verify-before-stop.sh only runs
# verification when the current session actually modified code.
# Also auto-creates ${aiDir}/memory/sessions/active/{session_id}.md on first
# code edit so memory tracking works automatically for single- and
# multi-agent sessions without manual /myspec:session-start.

set -euo pipefail

# Requires jq for JSON parsing
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)

resolve_repo_root() {
  local candidate resolved

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

  if resolved=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if resolved=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
INPUT_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Only mark for code files (not docs, config, etc.)
# Common extensions across multiple stacks — add more as needed
if [[ ! "$FILE_PATH" =~ \.(ts|tsx|vue|js|jsx|mts|cts|py|rb|go|java|php|rs|cs|swift|kt)$ ]]; then
  exit 0
fi

touch "/tmp/.myspec-code-changed-${SESSION_ID}"

# Auto-create per-session active log on first code edit.
# Multi-agent safe: each agent has a distinct session_id from the harness,
# so concurrent agents write to separate files and never race.
if ! REPO_ROOT="$(resolve_repo_root)"; then
  exit 0
fi

# Read aiDir from .myspec.json (default: "ai")
AI_DIR="ai"
if [ -f "$REPO_ROOT/.myspec.json" ]; then
  CONFIGURED=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null)
  if [ -n "$CONFIGURED" ]; then
    AI_DIR="$CONFIGURED"
  fi
fi

ACTIVE_DIR="$REPO_ROOT/$AI_DIR/memory/sessions/active"
ACTIVE_FILE="$ACTIVE_DIR/${SESSION_ID}.md"

if [ -f "$ACTIVE_FILE" ]; then
  exit 0
fi

mkdir -p "$ACTIVE_DIR"

# Topic seed: parent directory name of the first edited file
TOPIC_SEED=$(basename "$(dirname "$FILE_PATH")" 2>/dev/null || echo "auto")
[ -z "$TOPIC_SEED" ] && TOPIC_SEED="auto"
STARTED=$(date '+%Y-%m-%d %H:%M')
SHORT_ID="${SESSION_ID:0:8}"

cat > "$ACTIVE_FILE" <<EOF
---
session_id: $SESSION_ID
topic: "auto:$TOPIC_SEED"
feature: ""
mode: implementation
started: $STARTED
status: active
auto_created: true
cwd: $INPUT_CWD
---

# Session $SHORT_ID — auto:$TOPIC_SEED

## Context
Auto-created on first code edit at \`$FILE_PATH\`. Refine topic, feature, and mode as the work crystallizes.

## Log

| # | Action | File(s) | Result | Attempt | Type | Note |
|---|--------|---------|--------|---------|------|------|

## Insights

## Outcome
<!-- Fill on /myspec:session-complete -->
- **What worked**:
- **Root cause**:
- **Key insights**:

## Extraction Candidates
<!-- Fill on /myspec:session-complete -->
EOF

exit 0
