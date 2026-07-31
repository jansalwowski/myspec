#!/usr/bin/env bash
# validate-frontmatter.sh
# PostToolUse hook — validates frontmatter on ${aiDir}/**/*.md writes/edits.
# Emits a block-decision JSON so the agent sees the issues as feedback and
# fixes them before continuing (exit-0 stdout alone never reaches the agent).
# Reads aiDir from .myspec.json (defaults to "ai" if not configured).
# Accepted fields mirror the framework's own templates: identity is any of
# title/name/topic/id/type; temporal is any of updated/last_updated/created/
# started/date. ${aiDir}/ideas/ is exempt (its seed docs ship frontmatter-less).

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

# Only check files inside the AI documentation directory (pure-shell prefix
# strip — no python3 dependency, no quote-injection via the file path)
RELATIVE="${FILE_PATH#"$REPO_ROOT"/}"
if [[ "$RELATIVE" != ${AI_DIR}/* ]]; then
  exit 0
fi

# The ideas queue ships frontmatter-less seed docs (PRIORITY-LISTING.md,
# *-INSTRUCTIONS.md) that idea skills edit on every triage — exempt the subtree
if [[ "$RELATIVE" == ${AI_DIR}/ideas/* ]]; then
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

  # Check an identity field (matches every framework template:
  # docs use title, skills use name, sessions use topic, memories use id,
  # type indexes use type)
  if ! echo "$FRONTMATTER" | grep -qE "^(title|name|topic|id|type):"; then
    ISSUES+=("missing identity field: one of 'title', 'name', 'topic', 'id', 'type'")
  fi

  # Check at least one temporal field (sessions use started, episodic
  # memories use date)
  if ! echo "$FRONTMATTER" | grep -qE "^(updated|last_updated|created|started|date):"; then
    ISSUES+=("missing temporal field: one of 'updated', 'last_updated', 'created', 'started', 'date'")
  fi
fi

if [ ${#ISSUES[@]} -gt 0 ]; then
  REASON="Frontmatter issue in ${RELATIVE}:"
  for ISSUE in "${ISSUES[@]}"; do
    REASON="${REASON}
  - ${ISSUE}"
  done
  REASON="${REASON}
Fix the frontmatter before continuing (templates: \${aiDir}/.templates/)."
  # Emit a block decision — the harness surfaces the reason back to the agent;
  # plain stdout with exit 0 would be transcript-only and never seen.
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$REASON" | jq -Rs .)"
fi

exit 0
