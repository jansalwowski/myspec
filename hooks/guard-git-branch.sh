#!/usr/bin/env bash
# guard-git-branch.sh
# PreToolUse hook (Bash matcher) — blocks branch-mutating git commands when
# running in the main checkout. Agents must use `isolation: "worktree"` instead.
#
# Worktree detection: worktrees have .git as a FILE (gitdir: pointer).
# The main checkout has .git as a DIRECTORY.
#
# Note: `git checkout -- <file>` is also blocked. Use `git restore <file>` instead.
#
# Output contract: {"decision": "block", "reason": "..."} or {"decision": "approve"}

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Locate the repo root relative to this hook file's location:
# .claude/hooks/guard-git-branch.sh → two levels up = repo root
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"

# If .git is a FILE, we are inside a worktree — allow everything
if [ -f "$REPO_ROOT/.git" ]; then
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
    REASON="BLOCKED: Branch-mutating git commands are not allowed on the main checkout. Use isolation: \"worktree\" in your Agent tool call instead. If you need to restore a file, use \`git restore <file>\` not \`git checkout\`. Blocked: ${BLOCKED_CMD}"
    echo "{\"decision\": \"block\", \"reason\": $(printf '%s' "$REASON" | jq -Rs .)}"
    exit 0
  fi
done

echo '{"decision": "approve"}'
