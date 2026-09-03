#!/usr/bin/env bash
# require-isolation-decision.sh
# PreToolUse hook (Write|Edit matcher) — gates the first SOURCE edit in the main
# checkout until an isolation decision (develop vs worktree) is recorded for the
# session. Rules live in .claude/rules/work-isolation.md.
#
# Worktree detection: worktrees have .git as a FILE (gitdir: pointer); the main
# checkout has .git as a DIRECTORY. Inside a worktree the decision is already
# made, so everything is approved.
#
# Marker: .claude/state/isolation/<session_id>.json  (gitignored), written by
# .claude/lib/set-isolation.sh.
#
# Subagents get their own session_id from the harness and cannot call
# AskUserQuestion. Rather than prompting, they inherit the newest develop-mode
# marker written within INHERIT_TTL. Consequence: a fresh top-level session
# started within that window silently inherits the previous answer instead of
# asking. Run `.claude/lib/set-isolation.sh --reset <session_id>` to force a re-ask.
#
# Configuration (all optional, .myspec.json):
#   aiDir                       doc tree; edits there never trigger the prompt
#   isolation.worktreeRoot      where worktrees live (default .claude/worktrees)
#
# Output contract: {"decision": "block", "reason": "..."} or {"decision": "approve"}

set -euo pipefail

OWN_TTL=28800      # 8h — a session's own decision stays valid this long
INHERIT_TTL=14400  # 4h — window in which a subagent inherits a parent's decision

approve() {
  echo '{"decision": "approve"}'
  exit 0
}

block() {
  printf '{"decision": "block", "reason": %s}\n' "$(printf '%s' "$1" | jq -Rs .)"
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  approve
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
  done <<JSON
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
JSON

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

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  approve
fi

if ! REPO_ROOT="$(resolve_repo_root)"; then
  approve
fi

# Only a myspec project carries the isolation contract.
[ -f "$REPO_ROOT/.myspec.json" ] || approve

# Inside a worktree — the isolation decision is already made by construction.
if [ -f "$REPO_ROOT/.git" ]; then
  approve
fi

# aiDir is required since 2.0; .ai is the documented default when absent.
AI_DIR=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null)
AI_DIR="${AI_DIR%/}"
AI_DIR="${AI_DIR:-.ai}"
WORKTREE_ROOT=$(jq -r '.isolation.worktreeRoot // ".claude/worktrees"' "$REPO_ROOT/.myspec.json" 2>/dev/null)
WORKTREE_ROOT="${WORKTREE_ROOT%/}"

# Paths that never need an isolation decision: agent infrastructure and docs.
# Everything else (source, config, tests, package.json, …) is gated.
EXEMPT_PREFIXES=(
  "$AI_DIR/"
  ".claude/"
  "docs/"
)

# Root-level agent configuration — same category as .claude/, not shipped code.
EXEMPT_FILES=(
  "CLAUDE.md"
  "AGENTS.md"
  ".mcp.json"
)

# Paths that must resolve to the MAIN CHECKOUT whatever the session answered.
#
# Distinct from EXEMPT_PREFIXES, which only suppress the prompt (branch 3) and
# are still subject to a worktree answer. These bypass the worktree block
# itself, so the list stays narrow: per-checkout state that another rule pins
# to the main checkout.
#
#   .claude/state/           gitignored harness state — live session logs,
#                            isolation markers, the memory ID registry
#   <aiDir>/memory/sessions/ the session archive, written by session-complete
#                            in the main checkout whatever mode the session
#                            chose; a worktree session would otherwise have no
#                            legitimate place to archive itself
MAIN_CHECKOUT_ONLY_PREFIXES=(
  ".claude/state/"
  "$AI_DIR/memory/sessions/"
)

case "$FILE_PATH" in
  /*) ABS_PATH="$FILE_PATH" ;;
  *)  ABS_PATH="$REPO_ROOT/$FILE_PATH" ;;
esac

# A linked worktree lives INSIDE the repo (<worktreeRoot>/<slug>/), so a file
# there is reached by a main-checkout-relative path and would otherwise be
# judged a main-checkout edit. Resolve the root from the FILE's own directory:
# in a worktree that root has .git as a FILE, which is the whole point of the
# session's isolation choice — approve it.
FILE_DIR="$(dirname "$ABS_PATH")"
while [ -n "$FILE_DIR" ] && [ "$FILE_DIR" != "/" ] && [ ! -d "$FILE_DIR" ]; do
  FILE_DIR="$(dirname "$FILE_DIR")"
done

if FILE_ROOT="$(git -C "$FILE_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  if [ -f "$FILE_ROOT/.git" ]; then
    approve
  fi
fi

REL_PATH="${ABS_PATH#"$REPO_ROOT"/}"

# Prefix strip was a no-op → the file lives outside the repo (scratchpad, /tmp).
if [ "$REL_PATH" = "$ABS_PATH" ]; then
  approve
fi

# Checked BEFORE any mode logic: these paths have exactly one correct location,
# so no isolation answer can redirect them. See the list's comment above.
for PREFIX in "${MAIN_CHECKOUT_ONLY_PREFIXES[@]}"; do
  case "$REL_PATH" in
    "$PREFIX"*) approve ;;
  esac
done

# Exemption is about the PROMPT, not about the tree. A doc edit never triggers
# the isolation question (branch 3 below), but once a session has answered
# "worktree", docs obey that answer like everything else — otherwise the guard
# is off for exactly the file types a docs-PR session edits.
IS_EXEMPT=0

for PREFIX in "${EXEMPT_PREFIXES[@]}"; do
  case "$REL_PATH" in
    "$PREFIX"*) IS_EXEMPT=1 ;;
  esac
done

for EXEMPT in "${EXEMPT_FILES[@]}"; do
  if [ "$REL_PATH" = "$EXEMPT" ]; then
    IS_EXEMPT=1
  fi
done

STATE_DIR="$REPO_ROOT/.claude/state/isolation"
NOW=$(date +%s)
MARKER_MODE=""
MARKER_AGE=0

read_marker() {
  MARKER_MODE=$(jq -r '.mode // empty' "$1" 2>/dev/null || printf '')
  MARKER_AGE=$(( NOW - $(jq -r '.decided_at // 0' "$1" 2>/dev/null || printf 0) ))
}

DEFAULT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

WORKTREE_REASON="BLOCKED: this session chose WORKTREE isolation, but the edit targets the main checkout.

Create the worktree if you have not already, then make every edit inside it:
  git worktree add -b <type>/<slug> \"\$(git rev-parse --show-toplevel)/$WORKTREE_ROOT/<slug>\" origin/$DEFAULT_BRANCH
  .claude/lib/worktree-provision.sh \"\$(git rev-parse --show-toplevel)/$WORKTREE_ROOT/<slug>\" --base origin/$DEFAULT_BRANCH

Use absolute paths and \`git -C <worktree>\` for all git operations. See .claude/rules/work-isolation.md.

Blocked edit: $REL_PATH"

# 1. This session's own decision.
if [ -n "$SESSION_ID" ] && [ -f "$STATE_DIR/${SESSION_ID}.json" ]; then
  read_marker "$STATE_DIR/${SESSION_ID}.json"

  if [ "$MARKER_AGE" -lt "$OWN_TTL" ] && [ "$MARKER_MODE" = "develop" ]; then
    approve
  fi

  if [ "$MARKER_AGE" -lt "$OWN_TTL" ] && [ "$MARKER_MODE" = "worktree" ]; then
    block "$WORKTREE_REASON"
  fi
fi

# 2. Inherited decision — subagents cannot prompt, so they follow the parent.
if [ -d "$STATE_DIR" ]; then
  NEWEST=$(ls -t "$STATE_DIR"/*.json 2>/dev/null | head -1 || printf '')

  if [ -n "$NEWEST" ] && [ -f "$NEWEST" ]; then
    read_marker "$NEWEST"

    if [ "$MARKER_AGE" -lt "$INHERIT_TTL" ] && [ "$MARKER_MODE" = "develop" ]; then
      approve
    fi

    if [ "$MARKER_AGE" -lt "$INHERIT_TTL" ] && [ "$MARKER_MODE" = "worktree" ]; then
      block "$WORKTREE_REASON"
    fi
  fi
fi

# 3. No decision anywhere — ask, unless the file is exempt from prompting.
if [ "$IS_EXEMPT" -eq 1 ]; then
  approve
fi

block "BLOCKED: no work-isolation decision recorded for this session.

Before editing source files in the main checkout, ask where the work should happen. Call AskUserQuestion with ONE question:

  header:   \"Isolation\"
  question: \"This task edits source files. Where should the work happen?\"
  options:
    - \"develop\"  — \"Edits land in your checkout; test immediately. No branch yet.\"
    - \"Worktree\" — \"Isolated branch in $WORKTREE_ROOT/; PR opened when done.\"

Mark ONE option \"(Recommended)\" using the task-shape heuristic in .claude/rules/work-isolation.md — do not present them as equals.

Then record the answer (session id is already filled in):
  .claude/lib/set-isolation.sh $SESSION_ID develop
  .claude/lib/set-isolation.sh $SESSION_ID worktree

Do NOT ask about a PR now — that question belongs at the end of the work.

If you are a SUBAGENT: do not prompt. Stop and report to your parent that no isolation decision exists.

Blocked edit: $REL_PATH"
