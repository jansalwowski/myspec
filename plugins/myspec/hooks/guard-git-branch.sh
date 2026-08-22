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
# MATCHING: the blocklist is applied at COMMAND POSITION only, over input whose
# quoted spans and heredoc bodies have been blanked (lib/command-scan.sh). A
# plain substring match fires on the verb wherever it appears — inside a commit
# message, a PR body, or doc prose — and blocks a command that mutates nothing.
# Those false positives were this hook's dominant failure mode.
# Fixture: hooks/tests/guard-git-branch.test.sh
#
# Escape hatch: a command prefixed with MYSPEC_ALLOW_BRANCH_OPS=1 is approved.
# Intended for deliberate integration flows (feature-complete's branch merge
# documents it) — not for casual branch mutations by parallel agents. The
# block reason deliberately does NOT mention the prefix: a hook cannot verify
# user confirmation, so advertising the bypass would let any blocked agent
# wave itself through. Only flows whose skill documents the prefix know it.
#
# Sanctioned cleanup needs no bypass: lib/branch-cleanup.sh makes its git calls
# in a child process, which this hook never sees. The capability stays bound to
# that audited script — which proves containment and requires confirmation —
# rather than to a copyable string.
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

# A command that explicitly names a linked worktree is worktree work, whatever
# the cwd. `cd <worktree> && git checkout x` is the sanctioned path this hook's
# own message points at, so blocking it makes the guard contradict its advice.
# (`git -C <worktree> branch -d x` slipped through only by accident: `-C` sits
# where the verb is matched.)
while IFS= read -r candidate_wt; do
  if [ -n "$candidate_wt" ] && [ "$candidate_wt" != "$REPO_ROOT" ]; then
    if printf '%s' "$COMMAND" | grep -qF "$candidate_wt"; then
      echo '{"decision": "approve"}'
      exit 0
    fi
  fi
done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')

# Explicit opt-out for user-confirmed integration flows (see header)
if echo "$COMMAND" | grep -qE '(^|[[:space:]])MYSPEC_ALLOW_BRANCH_OPS=1[[:space:]]'; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Locate the shared scanner. The hook + lib ship as a pair:
#   myspec repo:      hooks/guard-git-branch.sh + lib/command-scan.sh
#   adopting project: .claude/hooks/...         + .claude/lib/...
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=""
for cand in \
  "$SCRIPT_DIR/../lib/command-scan.sh" \
  "$REPO_ROOT/.claude/lib/command-scan.sh" \
  "$REPO_ROOT/lib/command-scan.sh"; do
  if [ -f "$cand" ]; then
    LIB="$cand"
    break
  fi
done

# Scanner missing — fail open rather than block on infra error, matching how
# this hook already treats a missing jq or an unresolvable repo root.
if [ -z "$LIB" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# shellcheck source=/dev/null
. "$LIB"

# Blocked verbs, matched against the first word of a command segment.
BLOCKED_PATTERNS=(
  '^git[[:space:]]+checkout([[:space:]]|$)'
  '^git[[:space:]]+switch([[:space:]]|$)'
  '^git[[:space:]]+merge([[:space:]]|$)'
  '^git[[:space:]]+rebase([[:space:]]|$)'
  '^git[[:space:]]+branch[[:space:]]+(-[mMdDcC]|--move|--delete|--copy|--set-upstream)'
)

BLOCKED_CMD=$(find_matching_segment "$COMMAND" "${BLOCKED_PATTERNS[@]}")

if [ -n "$BLOCKED_CMD" ]; then
  REASON="BLOCKED: Branch-mutating git commands are not allowed on the main checkout. Use isolation: \"worktree\" in your Agent tool call instead. If you need to restore a file, use \`git restore <file>\` not \`git checkout\`. Blocked: $(printf '%s' "$BLOCKED_CMD" | head -c 200)"
  echo "{\"decision\": \"block\", \"reason\": $(printf '%s' "$REASON" | jq -Rs .)}"
  exit 0
fi

echo '{"decision": "approve"}'
