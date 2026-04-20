#!/usr/bin/env bash
# validate-frontmatter.sh
# PostToolUse hook — validates frontmatter on ${aiDir}/**/*.md writes/edits.
# Outputs warnings that the agent sees as feedback and must fix before continuing.
# Reads aiDir from .myspec.json (defaults to "ai" if not configured).

set -euo pipefail

# Requires jq
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Read stdin JSON
INPUT=$(cat)

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

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

if ! REPO_ROOT="$(resolve_repo_root)"; then
  exit 0
fi

# Resolve to absolute path
if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$REPO_ROOT/$FILE_PATH"
fi

# Only check .md files
if [[ "$FILE_PATH" != *.md ]]; then
  exit 0
fi

# Read aiDir from .myspec.json (default: "ai")
AI_DIR="ai"
if [ -f "$REPO_ROOT/.myspec.json" ] && command -v jq &>/dev/null; then
  CONFIGURED=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null)
  if [ -n "$CONFIGURED" ]; then
    AI_DIR="$CONFIGURED"
  fi
fi

# Only check files inside the AI documentation directory
RELATIVE=$(python3 -c "import os; print(os.path.relpath('$FILE_PATH', '$REPO_ROOT'))" 2>/dev/null || echo "$FILE_PATH")
if [[ "$RELATIVE" != ${AI_DIR}/* ]]; then
  exit 0
fi

# File must exist
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

CONTENT=$(cat "$FILE_PATH")
ISSUES=()

# Check frontmatter block exists
if ! echo "$CONTENT" | grep -qE "^---"; then
  ISSUES+=("missing frontmatter block entirely")
else
  FRONTMATTER=$(echo "$CONTENT" | awk '/^---/{p++; if(p==2) exit} p' | grep -v "^---")

  # Check title or name field
  if ! echo "$FRONTMATTER" | grep -qE "^(title|name):"; then
    ISSUES+=("missing required field: 'title' or 'name'")
  fi

  # Check at least one temporal field
  if ! echo "$FRONTMATTER" | grep -qE "^(updated|last_updated|created):"; then
    ISSUES+=("missing temporal field: 'updated', 'last_updated', or 'created'")
  fi
fi

if [ ${#ISSUES[@]} -gt 0 ]; then
  echo "⚠️  Frontmatter issue in $RELATIVE:"
  for ISSUE in "${ISSUES[@]}"; do
    echo "   - $ISSUE"
  done
  echo "   Fix frontmatter before completing this task."
fi

exit 0
