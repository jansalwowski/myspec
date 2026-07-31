#!/usr/bin/env bash
# guard-git-branch.sh
# PreToolUse hook (Bash matcher) — blocks branch-mutating git commands when
# running in the main checkout. Works both as a copied Claude hook under
# `.claude/hooks/` and as a Codex plugin hook invoked from the plugin repo.
#
# Worktree detection: worktrees have .git as a FILE (gitdir: pointer).
# The main checkout has .git as a DIRECTORY.
#
# Note: `git checkout -- <file>` is also blocked. Use `git restore <file>` instead.
#
# Escape hatch: a command prefixed with MYSPEC_ALLOW_BRANCH_OPS=1 is approved.
# This marks a deliberate, user-confirmed flow (e.g. feature-complete's branch
# integration) as opposed to a casual branch mutation by a parallel agent.
#
# Output contract: {"decision": "block", "reason": "..."} or {"decision": "approve"}

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

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

if [ -z "$COMMAND" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

if ! REPO_ROOT="$(resolve_repo_root)"; then
  echo '{"decision": "approve"}'
  exit 0
fi

# If .git is a FILE, we are inside a worktree — allow everything
if [ -f "$REPO_ROOT/.git" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Explicit opt-out for user-confirmed integration flows (see header)
if echo "$COMMAND" | grep -qE '(^|[[:space:]])MYSPEC_ALLOW_BRANCH_OPS=1[[:space:]]'; then
  echo '{"decision": "approve"}'
  exit 0
fi

# We are on the main checkout — enforce the block list
BLOCKED_PATTERNS=(
  'git[[:space:]]+checkout([[:space:]]|$)'
  'git[[:space:]]+switch([[:space:]]|$)'
  'git[[:space:]]+merge([[:space:]]|$)'
  'git[[:space:]]+rebase([[:space:]]|$)'
  'git[[:space:]]+branch[[:space:]]+(-[mMdDcC]|--move|--delete|--copy|--set-upstream)'
)

for PATTERN in "${BLOCKED_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$PATTERN"; then
    BLOCKED_CMD=$(echo "$COMMAND" | head -c 200)
    REASON="BLOCKED: Branch-mutating git commands are not allowed on the main checkout. Use isolation: \"worktree\" in your Agent tool call instead. If you need to restore a file, use \`git restore <file>\` not \`git checkout\`. For a user-confirmed integration flow (e.g. feature-complete branch merge), prefix the command with MYSPEC_ALLOW_BRANCH_OPS=1. Blocked: ${BLOCKED_CMD}"
    echo "{\"decision\": \"block\", \"reason\": $(printf '%s' "$REASON" | jq -Rs .)}"
    exit 0
  fi
done

echo '{"decision": "approve"}'
