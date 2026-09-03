#!/usr/bin/env bash
# set-isolation.sh
# Records the work-isolation decision for a session so
# require-isolation-decision.sh stops gating source edits and
# guard-worktree-context.sh knows which tree the session works in.
#
# Usage:
#   .claude/lib/set-isolation.sh <session_id> <develop|worktree> [note] [--worktree-path <abs>]
#   .claude/lib/set-isolation.sh --reset <session_id>
#   .claude/lib/set-isolation.sh --show
#
# --worktree-path lets guard-worktree-context.sh name the right tree in its
# block message. It can be supplied later than the decision itself (the
# worktree usually does not exist yet at decision time) by re-running the same
# command with the path appended.
#
# Marker: .claude/state/isolation/<session_id>.json  (gitignored)

set -euo pipefail

resolve_repo_root() {
  local candidate resolved

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

if ! command -v jq >/dev/null 2>&1; then
  echo "set-isolation: jq is required" >&2
  exit 1
fi

if ! REPO_ROOT="$(resolve_repo_root)"; then
  echo "set-isolation: not inside a git repository" >&2
  exit 1
fi

# Markers live in the MAIN checkout: the hooks read them there, and a linked
# worktree may be gone by the time the decision would matter.
if [ -f "$REPO_ROOT/.git" ]; then
  COMMON=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '')
  if [ -n "$COMMON" ] && [ "$(basename "$COMMON")" = ".git" ]; then
    REPO_ROOT=$(dirname "$COMMON")
  fi
fi

STATE_DIR="$REPO_ROOT/.claude/state/isolation"

# Markers outlive their 8h TTL as dead files; without a sweep they accumulate
# indefinitely. Expired markers are also what `ls -t | head -1` inheritance
# would otherwise walk.
prune_expired() {
  local f age

  [ -d "$STATE_DIR" ] || return 0

  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    age=$(( $(date +%s) - $(jq -r '.decided_at // 0' "$f" 2>/dev/null || printf 0) ))
    if [ "$age" -gt 28800 ]; then
      rm -f "$f"
    fi
  done
}

if [ "${1:-}" = "--show" ]; then
  if [ ! -d "$STATE_DIR" ]; then
    echo "(no isolation decisions recorded)"
    exit 0
  fi

  NOW=$(date +%s)
  FOUND=0
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    FOUND=1
    MODE=$(jq -r '.mode // "?"' "$f")
    AT=$(jq -r '.decided_at // 0' "$f")
    NOTE=$(jq -r '.note // ""' "$f")
    WT_PATH=$(jq -r '.worktree_path // ""' "$f")
    printf '%s  mode=%-8s age=%dmin  %s%s\n' \
      "$(basename "$f" .json | head -c 8)" "$MODE" "$(( (NOW - AT) / 60 ))" "$NOTE" \
      "$([ -n "$WT_PATH" ] && printf ' [%s]' "$WT_PATH")"
  done

  if [ "$FOUND" -eq 0 ]; then
    echo "(no isolation decisions recorded)"
  fi
  exit 0
fi

if [ "${1:-}" = "--reset" ]; then
  SESSION_ID="${2:-}"
  if [ -z "$SESSION_ID" ]; then
    echo "set-isolation: --reset needs a session id" >&2
    exit 1
  fi

  rm -f "$STATE_DIR/${SESSION_ID}.json"
  echo "isolation decision cleared for ${SESSION_ID:0:8} — the next source edit will re-ask"
  exit 0
fi

SESSION_ID="${1:-}"
MODE="${2:-}"
shift 2 2>/dev/null || true

NOTE=""
WORKTREE_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree-path)
      WORKTREE_PATH="${2:-}"
      shift 2
      ;;
    *)
      NOTE="$1"
      shift
      ;;
  esac
done

if [ -z "$SESSION_ID" ] || [ -z "$MODE" ]; then
  echo "usage: set-isolation.sh <session_id> <develop|worktree> [note] [--worktree-path <abs>]" >&2
  exit 1
fi

if [ "$MODE" != "develop" ] && [ "$MODE" != "worktree" ]; then
  echo "set-isolation: mode must be 'develop' or 'worktree' (got '$MODE')" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
prune_expired

jq -n \
  --arg mode "$MODE" \
  --arg note "$NOTE" \
  --arg worktree_path "$WORKTREE_PATH" \
  --argjson at "$(date +%s)" \
  '{mode: $mode, decided_at: $at, note: $note, worktree_path: $worktree_path}' \
  > "$STATE_DIR/${SESSION_ID}.json"

if [ "$MODE" = "develop" ]; then
  echo "isolation: develop — edits land in the main checkout. Do NOT commit unless asked; end-of-work promotion moves an uncommitted diff."
else
  echo "isolation: worktree — create it now and do every edit inside it. Editing the main checkout stays blocked."
fi
