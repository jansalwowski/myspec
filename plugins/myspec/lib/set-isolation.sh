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

# shellcheck source=lib/hook-core.sh
. "$(dirname "${BASH_SOURCE[0]}")/hook-core.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "set-isolation: jq is required" >&2
  exit 1
fi

# The checkout of the cwd, else of the project this lib is installed in.
if ! REPO_ROOT=$(hook_repo_root "") || ! checkout_facts "$REPO_ROOT"; then
  echo "set-isolation: not inside a git repository" >&2
  exit 1
fi

# Markers live in the MAIN checkout (checkout_facts): the hooks read them
# there, and a linked worktree may be gone by the time the decision would
# matter. A worktree whose main checkout git cannot name (a bare repository)
# keeps its own.
REPO_ROOT="${CF_MAIN:-$CF_ROOT}"

STATE_DIR="$REPO_ROOT/.claude/state/isolation"

# Markers outlive their TTL (HOOK_DECISION_TTL, 8h) as dead files; without a sweep they accumulate
# indefinitely. Expired markers are also what `ls -t | head -1` inheritance
# would otherwise walk.
prune_expired() {
  local f age

  [ -d "$STATE_DIR" ] || return 0

  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    age=$(( $(date +%s) - $(jq -r '.decided_at // 0' "$f" 2>/dev/null || printf 0) ))
    if [ "$age" -gt "$HOOK_DECISION_TTL" ]; then
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
    ID=$(basename "$f" .json)
    printf '%s  mode=%-8s age=%dmin  %s%s\n' \
      "${ID:0:8}" "$MODE" "$(( (NOW - AT) / 60 ))" "$NOTE" \
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

# A live marker for this id is a decision already made — usually by another
# session whose id was guessed from .claude/state/sessions/ (issue #146). The
# model never sees its own session id; the only reliable source is the block
# message of require-isolation-decision.sh. So a re-run may add a worktree path
# to the same answer, but never flip the mode or repoint the path: that takes
# an explicit --reset first.
EXISTING="$STATE_DIR/${SESSION_ID}.json"
if [ -f "$EXISTING" ]; then
  OLD_MODE=$(jq -r '.mode // empty' "$EXISTING" 2>/dev/null || printf '')
  OLD_PATH=$(jq -r '.worktree_path // empty' "$EXISTING" 2>/dev/null || printf '')
  if [ "$OLD_MODE" != "$MODE" ] \
      || { [ -n "$OLD_PATH" ] && [ -n "$WORKTREE_PATH" ] && [ "$OLD_PATH" != "$WORKTREE_PATH" ]; }; then
    {
      echo "set-isolation: a decision is already recorded for ${SESSION_ID:0:8} (mode=${OLD_MODE:-?}${OLD_PATH:+, worktree $OLD_PATH}); refusing to overwrite it."
      echo "  Use the session id from the isolation hook's block message, never one read from .claude/state/sessions/."
      echo "  If this really is your own session and the user changed the answer, run --reset $SESSION_ID first."
    } >&2
    exit 1
  fi
  [ -n "$WORKTREE_PATH" ] || WORKTREE_PATH="$OLD_PATH"
fi

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
