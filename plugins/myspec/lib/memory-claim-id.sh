#!/usr/bin/env bash
# memory-claim-id.sh
# Hands out the next free memory ID for a type, atomically across every
# checkout of this repo on this machine.
#
# THE RACE IT CLOSES
# Memory IDs are sequential (P001…). Allocation used to mean "read the index,
# take the next number" — so two sessions branched from the same base both
# pick P053, both write it, and the tables auto-merge without a conflict
# because the rows land on different lines. tests/unit/memoryIndexIntegrity.spec.js
# catches it after the fact; this closes it at the source.
#
# HOW
#   1. Take a lock in the MAIN checkout (mkdir is atomic even over NFS).
#   2. High-water = max(IDs on disk in the main checkout AND every linked
#      worktree, registry high-water).
#   3. Record high-water+1 in the registry, release, print the ID.
#
# The registry makes a claim durable BEFORE the file exists, which is the gap a
# pure filesystem scan leaves open. The scan makes the registry self-healing: a
# fresh clone, a deleted registry, or hand-added files all recover, because the
# registry is only ever a floor, never the sole authority. Unused claims leave
# harmless gaps in the sequence.
#
# Scope: this machine. The registry is per-checkout state, so it does not
# serialise against a session running elsewhere.
#
# Usage: memory-claim-id.sh <procedural|semantic|episodic>

set -euo pipefail

TYPE="${1:-}"

case "$TYPE" in
  procedural) PREFIX=P ;;
  semantic)   PREFIX=S ;;
  episodic)   PREFIX=E ;;
  *)
    echo "usage: memory-claim-id.sh <procedural|semantic|episodic>" >&2
    exit 2
    ;;
esac

# The main checkout owns the lock and the registry: worktrees each have their
# own .ai/memory, so per-worktree state would not serialise anything.
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "memory-claim-id: not inside a git repository" >&2
  exit 2
}
MAIN_ROOT=$(dirname "$COMMON_DIR")

AI_DIR=".ai"
if [ -f "$MAIN_ROOT/.myspec.json" ] && command -v jq >/dev/null 2>&1; then
  AI_DIR=$(jq -r '.aiDir // ".ai"' "$MAIN_ROOT/.myspec.json" 2>/dev/null || printf '.ai')
fi

STATE_DIR="$MAIN_ROOT/.claude/state"
REGISTRY="$STATE_DIR/memory-ids.json"
LOCK="$STATE_DIR/memory-id-${PREFIX}.lock"

mkdir -p "$STATE_DIR"

# Acquire — with stale-lock breaking, so a crashed claim cannot wedge the repo.
ATTEMPTS=0
while ! mkdir "$LOCK" 2>/dev/null; do
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))

  if [ "$LOCK_AGE" -gt 60 ]; then
    rmdir "$LOCK" 2>/dev/null || true
    continue
  fi

  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -gt 100 ]; then
    echo "memory-claim-id: could not acquire $LOCK after 10s" >&2
    exit 1
  fi

  sleep 0.1
done

trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Every checkout of this repo: the main one plus each linked worktree.
HIGH=0

scan_root() {
  local dir="$1/$AI_DIR/memory/$TYPE"
  local name num

  [ -d "$dir" ] || return 0

  for f in "$dir/$PREFIX"*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    num=$(printf '%s' "$name" | sed -E "s/^${PREFIX}0*([0-9]+).*/\1/")
    case "$num" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$num" -gt "$HIGH" ]; then
      HIGH="$num"
    fi
  done
}

scan_root "$MAIN_ROOT"

while IFS= read -r wt; do
  [ -n "$wt" ] && scan_root "$wt"
done < <(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')

if [ -f "$REGISTRY" ] && command -v jq >/dev/null 2>&1; then
  RECORDED=$(jq -r --arg p "$PREFIX" '.[$p] // 0' "$REGISTRY" 2>/dev/null || printf 0)
  case "$RECORDED" in
    ''|*[!0-9]*) RECORDED=0 ;;
  esac
  if [ "$RECORDED" -gt "$HIGH" ]; then
    HIGH="$RECORDED"
  fi
fi

NEXT=$((HIGH + 1))

if command -v jq >/dev/null 2>&1; then
  if [ -f "$REGISTRY" ]; then
    TMP=$(mktemp)
    jq --arg p "$PREFIX" --argjson n "$NEXT" '.[$p] = $n' "$REGISTRY" > "$TMP" && mv "$TMP" "$REGISTRY"
  else
    jq -n --arg p "$PREFIX" --argjson n "$NEXT" '{($p): $n}' > "$REGISTRY"
  fi
fi

printf '%s%03d\n' "$PREFIX" "$NEXT"
