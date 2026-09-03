#!/usr/bin/env bash
# mark-code-changed.sh
# PostToolUse hook — marks that code files were changed in this session.
# Creates a session-scoped marker file so verify-before-stop.sh only runs
# verification when the current session actually modified code.
# Also auto-creates ${aiDir}/memory/sessions/active/{session_id}.md on first
# code edit so memory tracking works automatically for single- and
# multi-agent sessions without manual /myspec:session-start.
#
# The session store is pinned to the PRIMARY worktree of the repository the
# EDITED FILE belongs to. Resolving from the hook payload's cwd instead lets a
# log land inside a linked worktree — where the bootstrap staleness sweep never
# sees it and `git worktree remove` destroys it, since session files are
# gitignored — or, for a session editing across repositories, in a repo that has
# nothing to do with the work.

set -euo pipefail

# Requires jq for JSON parsing
if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)

# Nearest existing directory at or above the edited file. PostToolUse runs after
# the write, so the parent normally exists; walking up keeps resolution working
# when it does not.
anchor_dir_for_file() {
  local dir
  dir="$(dirname "$1")"

  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ] && [ ! -d "$dir" ]; do
    dir="$(dirname "$dir")"
  done

  if [ -d "$dir" ]; then
    printf '%s\n' "$dir"
    return 0
  fi

  return 1
}

# Pin a git toplevel to the primary worktree. A linked worktree is its own
# toplevel, so `--show-toplevel` inside .claude/worktrees/<slug> returns the
# worktree; the parent of the common git dir is the main checkout. The two
# already agree in the primary worktree, so this is a no-op there.
main_worktree_root() {
  local path="$1"
  local common_git_dir

  common_git_dir=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1

  # Submodules and bare repos have a common dir that is not named `.git`; for
  # those the plain toplevel is already the correct root.
  if [ "$(basename "$common_git_dir")" = ".git" ]; then
    dirname "$common_git_dir"
    return 0
  fi

  git -C "$path" rev-parse --show-toplevel 2>/dev/null
}

# Repository root before main-worktree normalisation, most authoritative source
# first.
resolve_repo_root_raw() {
  local file_path="$1"
  local anchor candidate resolved

  # 1. The repository the edited file belongs to. Anchoring here rather than on
  #    the payload cwd keeps a session that edits another repository from
  #    filing its log in this one.
  case "$file_path" in
    /*)
      if anchor=$(anchor_dir_for_file "$file_path"); then
        if resolved=$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null); then
          printf '%s\n' "$resolved"
          return 0
        fi
      fi
      ;;
  esac

  # 2. Whatever cwd the payload carries — reached only when the edited file sits
  #    outside any repository (or its path is relative).
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

# (raw root and pinned root are resolved separately at the call site — the
# worktree marker needs the raw root, the session store needs the pinned one)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Only mark for code files (not docs, config, etc.)
# Common extensions across multiple stacks — add more as needed
if [[ ! "$FILE_PATH" =~ \.(ts|tsx|vue|js|jsx|mjs|cjs|mts|cts|py|rb|go|java|php|rs|cs|swift|kt|sh|bash)$ ]]; then
  exit 0
fi

touch "/tmp/.myspec-code-changed-${SESSION_ID}"

# Auto-create per-session active log on first code edit.
# Multi-agent safe: each agent has a distinct session_id from the harness,
# so concurrent agents write to separate files and never race.
# RAW_ROOT is the repository root as seen from the edited file (a linked
# worktree resolves to itself); REPO_ROOT is pinned to the primary checkout,
# where the session store lives.
if ! RAW_ROOT="$(resolve_repo_root_raw "$FILE_PATH")"; then
  exit 0
fi

if ! REPO_ROOT="$(main_worktree_root "$RAW_ROOT")"; then
  REPO_ROOT="$RAW_ROOT"
fi

# aiDir from .myspec.json; strip a trailing slash so a configured ".ai/"
# cannot derive dead patterns like ".ai//*" downstream
AI_DIR=""
if [ -f "$REPO_ROOT/.myspec.json" ]; then
  AI_DIR=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null)
  AI_DIR="${AI_DIR%/}"
fi
# No configured value: read the tree that is actually on disk instead of
# guessing. The guess was ".ai" in memory-files.mjs, memory-claim-id.sh and
# verify-before-stop.sh, and "ai" here and in the sibling PostToolUse hook, so
# a keyless project had its session logs written to one tree while its
# memories were read from the other. ".ai" wins when both or neither exist;
# memory-doctor names the both case as second-ai-tree.
if [ -z "$AI_DIR" ]; then
  if [ -d "$REPO_ROOT/.ai" ] || [ ! -d "$REPO_ROOT/ai" ]; then AI_DIR=".ai"; else AI_DIR="ai"; fi
fi

# File logs only in a myspec-managed project. Now that the root follows the
# edited file, an edit in an unrelated repository would otherwise grow a stray
# sessions tree there.
if [ ! -f "$REPO_ROOT/.myspec.json" ] && [ ! -d "$REPO_ROOT/$AI_DIR/memory/sessions" ]; then
  exit 0
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

# Worktree marker: the edit resolved to a linked worktree when the raw root
# differs from the pinned primary checkout. The basename is portable (no
# absolute path) and lets session-clean's liveness gate match the session
# against `git worktree list`. Main checkout: empty (gate uses mtime).
WORKTREE=""
if [ "$RAW_ROOT" != "$REPO_ROOT" ]; then
  WORKTREE=$(basename "$RAW_ROOT")
fi

cat > "$ACTIVE_FILE" <<EOF
---
session_id: $SESSION_ID
topic: "auto:$TOPIC_SEED"
feature: ""
mode: implementation
started: $STARTED
status: active
auto_created: true
worktree: "$WORKTREE"
cwd: <repo_root>
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
