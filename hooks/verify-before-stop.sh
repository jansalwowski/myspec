#!/usr/bin/env bash
# verify-before-stop.sh
# Stop hook — runs verification checks before agent completes.
# Reads commands from .claude/verification.json (requires jq).
# Outputs {"decision": "block", "reason": "..."} on failure or {"decision": "approve"} on success.
# During feature-implement (.claude/state/implement-in-progress.json, at most
# 8h old) check failures become a non-blocking systemMessage warning instead.

set -euo pipefail

# Read stdin JSON (Stop hook receives session context)
INPUT=$(cat)

# Prevent infinite loop on re-entry. The harness signals this via
# stop_hook_active in the stdin JSON (the continuation after a prior block);
# env vars kept as a fallback for hosts that set them instead.
if command -v jq >/dev/null 2>&1; then
  if [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    echo '{"decision": "approve"}'
    exit 0
  fi
fi
if [ "${CLAUDE_STOP_HOOK_ACTIVE:-}" = "1" ] || [ "${MYSPEC_STOP_HOOK_ACTIVE:-}" = "1" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

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

if ! REPO_ROOT="$(resolve_repo_root)"; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Memory conformance. The index tables are generated and the ID allocator
# refuses on drift, so drift a session leaves behind (an unregenerated index, a
# memory without hook:, a duplicate ID) should surface here, in the session that
# caused it, not in the next session's claim. Gated on uncommitted changes under
# the memory tree: pre-existing drift the agent never touched is bootstrap's to
# report, not a reason to block a stop.
DOCTOR="$REPO_ROOT/.claude/lib/memory-doctor.mjs"
if [ -f "$DOCTOR" ] && [ -f "$REPO_ROOT/.myspec.json" ] && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # aiDir is required since 2.0; .ai is the documented default when absent,
  # the same resolution memory-files.mjs uses.
  MEMORY_AI_DIR=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null | sed 's#/*$##')
  MEMORY_AI_DIR="${MEMORY_AI_DIR:-.ai}"
  if [ -n "$MEMORY_AI_DIR" ] && git -C "$REPO_ROOT" status --porcelain -- "$MEMORY_AI_DIR/memory" 2>/dev/null | grep -q .; then
    if ! DOCTOR_OUT=$(cd "$REPO_ROOT" && node "$DOCTOR" --quiet 2>&1); then
      REASON=$(printf 'Memory conformance check failed for changes under %s/memory. Fix these before stopping (node .claude/lib/memory-index.mjs regenerates the tables; the doctor names the rest):\n\n%s' "$MEMORY_AI_DIR" "$(printf '%s' "$DOCTOR_OUT" | tail -30)" | jq -Rs .)
      echo "{\"decision\": \"block\", \"reason\": $REASON}"
      exit 0
    fi
  fi
fi

# Setup conformance. Only the wiring and schema groups: a hook that is
# registered but missing, not executable, or fails bash -n is silently inert,
# and an unparseable .myspec.json or verification.json degrades this very gate
# to approve — all of them are damage the session just did and can undo now.
# Framework drift is deliberately excluded: its usual cause is a pending
# /myspec:update, and blocking on that would halt every commit made between a
# plugin release and the next update run. The features group is excluded too —
# it reads a file under the aiDir, outside the trigger below, so including it
# would block a stop over something this session never touched. Gated on
# uncommitted changes to the harness config, for the same reason the memory
# check above is gated.
SETUP_DOCTOR="$REPO_ROOT/.claude/lib/setup-doctor.mjs"
if [ -f "$SETUP_DOCTOR" ] && [ -f "$REPO_ROOT/.myspec.json" ] && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" status --porcelain -- .claude .myspec.json 2>/dev/null | grep -q .; then
    if ! SETUP_OUT=$(cd "$REPO_ROOT" && node "$SETUP_DOCTOR" --quiet wiring schema 2>&1); then
      REASON=$(printf 'Setup conformance check failed for changes under .claude/ or .myspec.json. Each of these makes a hook or a gate silently stop working, so fix them before stopping:\n\n%s' "$(printf '%s' "$SETUP_OUT" | tail -30)" | jq -Rs .)
      echo "{\"decision\": \"block\", \"reason\": $REASON}"
      exit 0
    fi
  fi
fi

CONFIG_FILE="$REPO_ROOT/.claude/verification.json"

# If no config file, skip (graceful degradation)
if [ ! -f "$CONFIG_FILE" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check if jq is available
if ! command -v jq &>/dev/null; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check if this session actually changed code files.
# mark-code-changed.sh (PostToolUse) touches a marker file when the agent edits code.
# This avoids running verification for brainstorming/planning sessions with pre-existing changes.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
MARKER_FILE="/tmp/.myspec-code-changed-${SESSION_ID}"

if [ -z "$SESSION_ID" ] || [ ! -f "$MARKER_FILE" ]; then
  # No code files changed by Claude this session — skip verification
  echo '{"decision": "approve"}'
  exit 0
fi

# A symlinked node_modules makes every check below run against ANOTHER
# checkout dependency tree, so the gate reports a green that describes the
# wrong tree. That silent false pass is worse than no gate at all, so block.
# The marker is deliberately left in place (the EXIT trap is registered below)
# so the block persists until a real install exists.
# Accepted without config when the link points into a checkout whose root
# lockfiles are byte-identical to this tree (committed and uncommitted state
# alike): both trees then resolve the same dependencies, which is exactly the
# case worktree-provision.sh links (it skips the link when the branch changes
# a lockfile against --base). Comparing contents rather than re-running the
# ref diff also holds when the main checkout is not at the base ref. At least
# one lockfile must exist; without one there is no evidence the trees match.
# Keep this lockfile list in step with lib/worktree-provision.sh.
# Deliberate link otherwise: isolation.allowLinkedModules: true in .myspec.json
# (project-wide, for repos whose worktrees share the main checkout
# dependencies by construction) or MYSPEC_ALLOW_LINKED_MODULES=1.
linked_lockfiles_match() {
  local target src lock seen=0
  target=$(cd "$REPO_ROOT/node_modules" 2>/dev/null && pwd -P) || return 1
  src=$(dirname "$target")
  [ "$src" != "$REPO_ROOT" ] || return 1
  for lock in package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock \
      composer.lock poetry.lock Pipfile.lock Cargo.lock Gemfile.lock go.sum; do
    if [ -e "$REPO_ROOT/$lock" ] || [ -e "$src/$lock" ]; then
      cmp -s "$REPO_ROOT/$lock" "$src/$lock" || return 1
      seen=1
    fi
  done
  [ "$seen" -eq 1 ]
}
ALLOW_LINKED=$(jq -r '.isolation.allowLinkedModules // false' "$REPO_ROOT/.myspec.json" 2>/dev/null || printf 'false')
if [ -L "$REPO_ROOT/node_modules" ] && [ "$ALLOW_LINKED" != "true" ] && [ "${MYSPEC_ALLOW_LINKED_MODULES:-}" != "1" ] \
    && ! linked_lockfiles_match; then
  REASON=$(printf 'node_modules in %s is a symlink and the lockfiles here differ from the checkout it points into (or none exists), so lint, type-check and test results here describe a different dependency tree. Run a real install in this worktree before reporting any result as verified (or, if this repo shares one tree by design, set isolation.allowLinkedModules: true in .myspec.json).' "$REPO_ROOT" | jq -Rs .)
  echo "{\"decision\": \"block\", \"reason\": $REASON}"
  exit 0
fi

# Clean up marker after verification runs (success or failure)
trap 'rm -f "$MARKER_FILE"' EXIT

# 120s cap per check. Stock macOS has neither `timeout` nor `gtimeout` (the
# latter needs coreutils), and the previous prefix-string form degraded to no
# cap at all on exactly that machine — the gate then hangs on a stuck check
# instead of failing it, which reads as a frozen agent. perl is in the macOS
# base system; alarm(2) survives exec, so SIGALRM terminates the bash -c child
# at the deadline (exit 142). A function, not a command prefix: the perl form
# cannot survive the word-splitting an unquoted $TIMEOUT_CMD relies on.
run_with_cap() {
  if command -v gtimeout &>/dev/null; then
    gtimeout 120 bash -c "$1"
  elif command -v timeout &>/dev/null; then
    timeout 120 bash -c "$1"
  else
    perl -e 'alarm 120; exec @ARGV' bash -c "$1"
  fi
}

# Base ref for diff-scoped checks. A repo whose lint or type-check is already
# red on the default branch cannot use a whole-repo command as a gate — it
# blocks every stop over debt this session did not create, and the block is
# indistinguishable from a real regression. Such a check declares a
# `diffCommand` instead, and this is the ref it measures against: the merge
# base with the default branch, so the range is "what this branch changed"
# on a feature branch and "what is uncommitted" when HEAD is that branch.
# Left empty when no default branch resolves (a repo with no remote and no
# main/master); the loop below then falls back to the whole-repo command
# rather than skipping the check.
MYSPEC_BASE_REF=""
DEFAULT_REF=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
if [ -z "$DEFAULT_REF" ]; then
  for CANDIDATE in origin/main origin/master main master; do
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "$CANDIDATE" >/dev/null 2>&1; then
      DEFAULT_REF="$CANDIDATE"
      break
    fi
  done
fi
if [ -n "$DEFAULT_REF" ]; then
  MYSPEC_BASE_REF=$(git -C "$REPO_ROOT" merge-base HEAD "$DEFAULT_REF" 2>/dev/null || printf '')
fi
export MYSPEC_BASE_REF

# Orchestration marker. While /myspec:feature-implement runs, the controller
# ends many turns on a tree that is red by design: a barrier accepted with a
# recorded failure, a fix round in flight in a subagent, a failing test owned
# by the next phase. Blocking there forces a turn the controller cannot use
# (it may not fix code itself), so failures downgrade to a non-blocking
# warning. The skill writes the marker at setup and removes it before its
# final verification; feature-complete removes it too. It lives in the
# checkout the session works in, not the primary one: it describes this tree,
# and a concurrent run in another worktree must keep its own gate. A marker
# older than IMPLEMENT_MARKER_TTL (8h, the isolation-decision TTL) or without
# a readable started_at is a crashed run: it is deleted and the gate blocks.
# Only the verification.json checks are downgraded; the conformance and
# symlink blocks above are session damage, not expected red.
IMPLEMENT_MARKER="$REPO_ROOT/.claude/state/implement-in-progress.json"
IMPLEMENT_MARKER_TTL=28800
IMPLEMENT_ACTIVE=0
if [ -f "$IMPLEMENT_MARKER" ]; then
  STARTED_AT=$(jq -r '.started_at // empty' "$IMPLEMENT_MARKER" 2>/dev/null || printf '')
  case "$STARTED_AT" in
    ''|*[!0-9]*) STARTED_AT="" ;;
  esac
  if [ -n "$STARTED_AT" ]; then
    MARKER_AGE=$(( $(date +%s) - STARTED_AT ))
    if [ "$MARKER_AGE" -ge 0 ] && [ "$MARKER_AGE" -le "$IMPLEMENT_MARKER_TTL" ]; then
      IMPLEMENT_ACTIVE=1
    fi
  fi
  if [ "$IMPLEMENT_ACTIVE" -eq 0 ]; then
    rm -f "$IMPLEMENT_MARKER"
  fi
fi

# Run each required check
FAILED_CHECKS=()
FAILED_OUTPUT=()

CHECKS_COUNT=$(jq '.checks | length' "$CONFIG_FILE")

for i in $(seq 0 $((CHECKS_COUNT - 1))); do
  REQUIRED=$(jq -r ".checks[$i].required" "$CONFIG_FILE")
  if [ "$REQUIRED" != "true" ]; then
    continue
  fi

  NAME=$(jq -r ".checks[$i].name" "$CONFIG_FILE")
  COMMAND=$(jq -r ".checks[$i].command" "$CONFIG_FILE")
  DIFF_COMMAND=$(jq -r ".checks[$i].diffCommand // \"\"" "$CONFIG_FILE")

  if [ -n "${DIFF_COMMAND// /}" ] && [ -n "$MYSPEC_BASE_REF" ]; then
    COMMAND="$DIFF_COMMAND"
  fi

  OUTPUT=$(cd "$REPO_ROOT" && MYSPEC_STOP_HOOK_ACTIVE=1 run_with_cap "$COMMAND" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?

  if [ "$EXIT_CODE" -ne 0 ]; then
    FAILED_CHECKS+=("$NAME")
    # Truncate output to avoid giant JSON
    TRUNCATED=$(echo "$OUTPUT" | tail -50 | head -c 2000)
    FAILED_OUTPUT+=("[$NAME] $COMMAND failed:"$'\n'"$TRUNCATED")
  fi
done

if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
  NAMES=$(printf '%s, ' "${FAILED_CHECKS[@]}"); NAMES=${NAMES%, }
  # Join with real newline-delimited separators (multi-char IFS joins only
  # use the first character, so the old IFS="\n---\n" emitted literal '\')
  DETAILS=""
  for ENTRY in "${FAILED_OUTPUT[@]}"; do
    DETAILS+="${ENTRY}"$'\n---\n'
  done
  DETAILS=${DETAILS%$'\n---\n'}
  if [ "$IMPLEMENT_ACTIVE" -eq 1 ]; then
    # Non-blocking: no decision block, so the stop proceeds; systemMessage
    # surfaces the failure to the user.
    MESSAGE=$(printf "Verification failing (%s) during feature-implement orchestration; not blocking (marker %s). The final verification step still gates.\n\n%s" "$NAMES" ".claude/state/implement-in-progress.json" "$DETAILS" | jq -Rs .)
    echo "{\"decision\": \"approve\", \"systemMessage\": $MESSAGE}"
    exit 0
  fi
  # Escape for JSON
  REASON=$(printf "Verification failed (%s). Fix errors before completing.\n\n%s" "$NAMES" "$DETAILS" | jq -Rs .)
  echo "{\"decision\": \"block\", \"reason\": $REASON}"
  exit 0
fi

echo '{"decision": "approve"}'
