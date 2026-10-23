#!/usr/bin/env bash
# housekeep.sh
# The everyday sweep: removes what a rule proves is safe to remove, counts
# what needs judgement and names the skill that owns it. One run, no
# questions, seconds rather than minutes. /myspec:housekeep runs it.
#
# WHY A SCRIPT, AND WHY IT ACTS WITHOUT ASKING
# Each step deletes only under a rule that already lets an existing skill
# delete: branch-cleanup.sh's containment proofs, session-clean's 24h rule
# for .jsonl state, a brainstorm session nobody serves and nobody touched in
# a week. Anything a rule cannot settle (a substantive live log, a memory
# that may be stale, a branch with no proof) is counted, never touched, and
# left to the skill that asks the user. The judgement-heavy skills stay
# separate because they cannot be made fast.
#
# Steps (each prints one line, "<step>: <what happened>"):
#   branches    branch-cleanup.sh audit, then --apply on every provably
#               contained branch, in --unattended mode (worktrees that may
#               be in use or hold ignored files are kept); it fetches with
#               --prune first. The branch checked out where this runs is
#               never removed.
#   sessions    .claude/state/sessions/*.jsonl older than 24h, with their
#               .blobs/ and .bash/ directories; live logs (*.md) older than
#               6h are counted for /myspec:session-clean
#   brainstorm  .myspec/brainstorm/<session>/ with no file modified in
#               --stale-days days and no running server
#   memory      memory-doctor.mjs error and warning counts, read-only
#   stamp       <state dir>/housekeep-last-run, which hooks/housekeep-nudge.sh
#               reads at session start; written only when every step ran
#
# Usage:
#   housekeep.sh [--dry-run] [--no-fetch] [--stale-days <n>]
#
#   --dry-run      report what would be removed; remove nothing, write no stamp
#   --no-fetch     passed to branch-cleanup.sh (offline)
#   --stale-days   brainstorm age threshold, default 7
#
# Exit 0 when every step ran, 1 when a removal failed or a step could not
# run, 2 on bad usage or outside a repository.

set -uo pipefail

DRY=0
FETCH_ARG=()
STALE_DAYS=7

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY=1; shift ;;
    --no-fetch)   FETCH_ARG=(--no-fetch); shift ;;
    --stale-days) [ "$#" -ge 2 ] || { echo "housekeep: --stale-days needs a value" >&2; exit 2; }
                  STALE_DAYS="$2"; shift 2 ;;
    -h|--help)    sed -n '2,36p' "$0"; exit 0 ;;
    *)            echo "housekeep: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$STALE_DAYS" in
  ''|*[!0-9]*|0) echo "housekeep: --stale-days takes a positive integer" >&2; exit 2 ;;
esac

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/session-event.sh
. "$LIB/session-event.sh"

if ! HERE=$(hook_repo_root "") || ! checkout_facts "$HERE"; then
  echo "housekeep: not inside a git repository" >&2
  exit 2
fi
HERE_BRANCH=$(git -C "$HERE" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '')
MAIN="$CF_MAIN"
HOME_DIR=$(session_home "$HERE")
STATE_DIR=$(session_dir "$HOME_DIR")
STATE_ROOT=$(dirname "$STATE_DIR")
PROJECT="${MAIN:-$HERE}"

STATUS=0
NOW=$(date +%s)
VERB="removed"
[ "$DRY" -eq 1 ] && VERB="would remove"

# mtime_of <path> -> its mtime as epoch seconds, or 0 (GNU stat first: BSD's
# -f means --file-system to GNU and succeeds with text, see branch-cleanup.sh).
mtime_of() {
  local t
  t=$(stat -c %Y "$1" 2>/dev/null) || t=""
  case "$t" in ''|*[!0-9]*) t=$(stat -f %m "$1" 2>/dev/null) || t="" ;; esac
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  printf '%s' "$t"
}

# --- branches ---------------------------------------------------------------
step_branches() {
  local audit names=() kept held tail n out
  if [ -z "$MAIN" ]; then
    echo "branches: skipped (no main checkout to run branch-cleanup.sh from)"
    return
  fi
  if ! audit=$(cd "$MAIN" && "$LIB/branch-cleanup.sh" --json --unattended "${FETCH_ARG[@]}" 2>/dev/null); then
    echo "branches: FAILED (branch-cleanup.sh audit did not run; try /myspec:worktree-clean)"
    STATUS=1
    return
  fi
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" != "$HERE_BRANCH" ] && names+=("$n")
  done < <(printf '%s' "$audit" | jq -r '.[] | select(.verdict == "DELETE") | .branch')
  kept=$(printf '%s' "$audit" | jq '[.[] | select(.verdict != "DELETE")] | length')
  held=$(printf '%s' "$audit" | jq '[.[] | select(.detail | test("^(may be in use|holds ignored files)"))] | length')
  tail=""
  [ "$held" -gt 0 ] && tail=" ($held with a worktree that may be in use, run /myspec:worktree-clean)"

  if [ "${#names[@]}" -eq 0 ]; then
    echo "branches: nothing provably merged; $kept kept$tail"
    return
  fi
  if [ "$DRY" -eq 0 ]; then
    local args=()
    for n in "${names[@]}"; do args+=(--branch "$n"); done
    # --no-fetch: the audit above just fetched.
    if ! out=$(cd "$MAIN" && "$LIB/branch-cleanup.sh" --apply --unattended --no-fetch "${args[@]}" 2>&1); then
      STATUS=1
    fi
    printf '%s\n' "$out" | grep -E '^(SKIP|FAILED)' | sed 's/^/  /'
  fi
  echo "branches: $VERB ${#names[@]} merged ($(IFS=,; printf '%s' "${names[*]}" | sed 's/,/, /g')); $kept kept$tail"
}

# --- sessions ---------------------------------------------------------------
step_sessions() {
  local f id gone=0 logs=0
  if [ ! -d "$STATE_DIR" ]; then
    echo "sessions: none"
    return
  fi
  for f in "$STATE_DIR"/*.jsonl; do
    [ -f "$f" ] || continue
    [ $(( NOW - $(mtime_of "$f") )) -gt 86400 ] || continue
    id="${f%.jsonl}"
    if [ "$DRY" -eq 0 ]; then
      rm -f -- "$f" && rm -rf -- "$id.blobs" "$id.bash" || STATUS=1
    fi
    gone=$((gone + 1))
  done
  for f in "$STATE_DIR"/*.md; do
    [ -f "$f" ] || continue
    [ $(( NOW - $(mtime_of "$f") )) -gt 21600 ] && logs=$((logs + 1))
  done
  local line="sessions: $VERB $gone state file(s) older than 24h"
  [ "$logs" -gt 0 ] && line="$line; $logs live log(s) older than 6h, run /myspec:session-clean"
  echo "$line"
}

# --- brainstorm -------------------------------------------------------------
# A session is live while its server.pid names a running process: a reused
# pid keeps it too, which errs toward keeping.
step_brainstorm() {
  local root="$PROJECT/.myspec/brainstorm" d pid gone=0 kept=0
  if [ ! -d "$root" ]; then
    echo "brainstorm: none"
    return
  fi
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    pid=$(tr -cd '0-9' < "$d/state/server.pid" 2>/dev/null || printf '')
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kept=$((kept + 1))
      continue
    fi
    if [ -n "$(find "$d" -mtime "-$STALE_DAYS" -print -quit 2>/dev/null)" ]; then
      kept=$((kept + 1))
      continue
    fi
    if [ "$DRY" -eq 0 ]; then
      rm -rf -- "$d" || STATUS=1
    fi
    gone=$((gone + 1))
  done
  echo "brainstorm: $VERB $gone session(s) idle over ${STALE_DAYS}d; $kept kept"
}

# --- memory -----------------------------------------------------------------
step_memory() {
  local out errs warns
  if ! command -v node >/dev/null 2>&1; then
    echo "memory: skipped (node not found)"
    return
  fi
  if [ ! -f "$PROJECT/.myspec.json" ]; then
    echo "memory: skipped (not a myspec project)"
    return
  fi
  # Exit 1 means errors were found, which is a result, not a failure.
  out=$(node "$LIB/memory-doctor.mjs" --root "$PROJECT" --json 2>/dev/null)
  if ! errs=$(printf '%s' "$out" | jq -e '.errors | length' 2>/dev/null) \
      || ! warns=$(printf '%s' "$out" | jq -e '.warnings | length' 2>/dev/null); then
    echo "memory: FAILED (memory-doctor.mjs gave no report)"
    STATUS=1
    return
  fi
  if [ "$errs" -eq 0 ] && [ "$warns" -eq 0 ]; then
    echo "memory: clean"
  else
    echo "memory: $errs error(s), $warns warning(s), run /myspec:memory-optimize"
  fi
}

# --- stamp ------------------------------------------------------------------
# Only after a clean run: a stamp after a FAILED step would silence the
# nudge for a sweep that did not happen.
step_stamp() {
  [ "$DRY" -eq 1 ] && return
  [ "$STATUS" -eq 0 ] || return
  if mkdir -p "$STATE_ROOT" 2>/dev/null && printf '%s\n' "$NOW" > "$STATE_ROOT/housekeep-last-run"; then
    return
  fi
  echo "stamp: FAILED (could not write $STATE_ROOT/housekeep-last-run)"
  STATUS=1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "housekeep: jq is required" >&2
  exit 2
fi

step_branches
step_sessions
step_brainstorm
step_memory
step_stamp
exit "$STATUS"
