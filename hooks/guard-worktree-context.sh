#!/usr/bin/env bash
# guard-worktree-context.sh
# PreToolUse hook (Bash matcher) — the Bash half of work isolation. Two gates,
# both scoped to the MAIN checkout (inside a linked worktree everything is
# approved: worktrees have .git as a FILE, the main checkout as a DIRECTORY):
#
#   A. Branch mutations are blocked always. `git checkout`, `switch`, `merge`,
#      `rebase`, and `branch -d/-D/-m/-c` on the main checkout are how a
#      parallel agent knocks the user's working tree out from under them.
#      (`git checkout -- <file>` is blocked too; use `git restore <file>`.)
#   B. When the session has chosen WORKTREE isolation, tree-specific commands
#      are blocked as well: builds, installs, e2e runs, `lint:fix`, `git push`
#      and `git worktree prune` silently target the wrong tree and are noticed
#      only when the output looks wrong. `.myspec.json` `isolation.blockInMain`
#      adds project patterns (anchored extended regexes over a command segment).
#
# Until 2.0 gate A was its own hook, guard-git-branch.sh; folding the two keeps
# one root resolver, one scanner, one worktree lookup, one block message.
#
# MATCHING: the blocklists are applied at COMMAND POSITION only, over input
# whose quoted spans and heredoc bodies have been blanked (lib/command-scan.sh).
# A plain substring match fires on the verb wherever it appears — inside a
# commit message, a PR body, doc prose — and blocks a command that mutates
# nothing. Those false positives were the branch guard's dominant failure mode.
# Fixture: hooks/tests/guard-worktree-context.test.sh
#
# A command that explicitly names a linked worktree is worktree work whatever
# the cwd: `cd <worktree> && git checkout x` is the sanctioned path both block
# messages point at, so it is approved before either gate.
#
# Escape hatches:
#   MYSPEC_ALLOW_BRANCH_OPS=1    gate A. Deliberately NOT mentioned in the block
#                               reason: a hook cannot verify user confirmation,
#                               so advertising it would let any blocked agent
#                               wave itself through. Only flows whose skill
#                               documents it (feature-complete's merge) know it.
#   MYSPEC_ALLOW_MAIN_CHECKOUT=1 gate B. Advertised: refreshing the symlinked
#                               node_modules in the main checkout is a legitimate
#                               mid-worktree action, so this gate is a speed bump.
#
# Sanctioned branch cleanup needs no bypass: lib/branch-cleanup.sh makes its
# git calls in a child process this hook never sees.
#
# Output contract: {"decision": "block", "reason": "..."} or {"decision": "approve"}

set -euo pipefail

OWN_TTL=28800      # 8h — a session's own isolation decision stays valid this long
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
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

[ -n "$COMMAND" ] || approve

resolve_repo_root() {
  local candidate resolved

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

if ! REPO_ROOT="$(resolve_repo_root)"; then
  approve
fi

# .git as a FILE means we are already inside a worktree — nothing to guard.
if [ -f "$REPO_ROOT/.git" ]; then
  approve
fi

# Naming a linked worktree makes the command worktree work, whatever the cwd.
while IFS= read -r candidate_wt; do
  if [ -n "$candidate_wt" ] && [ "$candidate_wt" != "$REPO_ROOT" ]; then
    if printf '%s' "$COMMAND" | grep -qF "$candidate_wt"; then
      approve
    fi
  fi
done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')

# The hook + lib ship as a pair:
#   myspec repo:      hooks/guard-worktree-context.sh + lib/command-scan.sh
#   adopting project: .claude/hooks/...              + .claude/lib/...
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
# the hook already treats a missing jq or an unresolvable repo root.
[ -n "$LIB" ] || approve

# shellcheck source=/dev/null
. "$LIB"

# --- Gate A: branch mutations on the main checkout ---------------------------

if ! printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])MYSPEC_ALLOW_BRANCH_OPS=1[[:space:]]'; then
  BRANCH_PATTERNS=(
    '^git[[:space:]]+checkout([[:space:]]|$)'
    '^git[[:space:]]+switch([[:space:]]|$)'
    '^git[[:space:]]+merge([[:space:]]|$)'
    '^git[[:space:]]+rebase([[:space:]]|$)'
    '^git[[:space:]]+branch[[:space:]]+(-[mMdDcC]|--move|--delete|--copy|--set-upstream)'
  )

  BLOCKED_CMD=$(find_matching_segment "$COMMAND" "${BRANCH_PATTERNS[@]}")

  if [ -n "$BLOCKED_CMD" ]; then
    block "BLOCKED: Branch-mutating git commands are not allowed on the main checkout. Do the work in a linked worktree (see .claude/rules/work-isolation.md) or pass isolation: \"worktree\" in your Agent tool call. If you need to restore a file, use \`git restore <file>\` not \`git checkout\`. Blocked: $(printf '%s' "$BLOCKED_CMD" | head -c 200)"
  fi
fi

# --- Gate B: tree-specific commands while the session is in worktree mode ----

if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])MYSPEC_ALLOW_MAIN_CHECKOUT=1[[:space:]]'; then
  approve
fi

STATE_DIR="$REPO_ROOT/.claude/state/isolation"
[ -d "$STATE_DIR" ] || approve

NOW=$(date +%s)
MARKER_MODE=""
MARKER_PATH=""
MARKER_AGE=0

read_marker() {
  MARKER_MODE=$(jq -r '.mode // empty' "$1" 2>/dev/null || printf '')
  MARKER_PATH=$(jq -r '.worktree_path // empty' "$1" 2>/dev/null || printf '')
  MARKER_AGE=$(( NOW - $(jq -r '.decided_at // 0' "$1" 2>/dev/null || printf 0) ))
}

MODE=""

# 1. This session's own decision.
if [ -n "$SESSION_ID" ] && [ -f "$STATE_DIR/${SESSION_ID}.json" ]; then
  read_marker "$STATE_DIR/${SESSION_ID}.json"
  if [ "$MARKER_AGE" -lt "$OWN_TTL" ]; then
    MODE="$MARKER_MODE"
  fi
fi

# 2. Inherited decision — subagents cannot prompt, so they follow the newest
#    recent marker.
if [ -z "$MODE" ]; then
  NEWEST=$(ls -t "$STATE_DIR"/*.json 2>/dev/null | head -1 || printf '')
  if [ -n "$NEWEST" ] && [ -f "$NEWEST" ]; then
    read_marker "$NEWEST"
    if [ "$MARKER_AGE" -lt "$INHERIT_TTL" ]; then
      MODE="$MARKER_MODE"
    fi
  fi
fi

[ "$MODE" = "worktree" ] || approve

# Commands whose result depends on which tree they run in, or which write to it.
HEAVY_PATTERNS=(
  '^(yarn|npm|pnpm|bun)[[:space:]]+(run[[:space:]]+)?build([[:space:]]|$)'
  '^(yarn|pnpm|bun)[[:space:]]+(install|add|upgrade|remove|dedupe|up)([[:space:]]|$)'
  '^npm[[:space:]]+(install|ci|i|uninstall|update)([[:space:]]|$)'
  '^(yarn|npm|pnpm|bun)[[:space:]]+(run[[:space:]]+)?test:e2e'
  '^(yarn|npm|pnpm|bun)[[:space:]]+(run[[:space:]]+)?lint:fix([[:space:]]|$)'
  '^(pip|pip3|poetry|composer|bundle)[[:space:]]+install([[:space:]]|$)'
  '^(cargo|go)[[:space:]]+build([[:space:]]|$)'
  '^git[[:space:]]+push([[:space:]]|$)'
  '^git[[:space:]]+worktree[[:space:]]+prune([[:space:]]|$)'
)

if [ -f "$REPO_ROOT/.myspec.json" ]; then
  while IFS= read -r extra; do
    [ -n "$extra" ] && HEAVY_PATTERNS+=("$extra")
  done < <(jq -r '.isolation.blockInMain // [] | .[] | select(type == "string")' "$REPO_ROOT/.myspec.json" 2>/dev/null)
fi

OFFENDER=$(find_matching_segment "$COMMAND" "${HEAVY_PATTERNS[@]}")

[ -n "$OFFENDER" ] || approve

# Name the worktree if we can: recorded path first, then a lone linked worktree.
TARGET="$MARKER_PATH"
if [ -z "$TARGET" ]; then
  CANDIDATES=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2}' | grep -v "^${REPO_ROOT}$" || printf '')
  if [ "$(printf '%s\n' "$CANDIDATES" | grep -c .)" = "1" ]; then
    TARGET="$CANDIDATES"
  fi
fi

if [ -n "$TARGET" ]; then
  WHERE="Run it in the session's worktree instead:
  cd $TARGET"
else
  WHERE="Run it in the session's worktree instead (see \`git worktree list\`); no worktree path was recorded for this session."
fi

block "BLOCKED: this session chose WORKTREE isolation, but this command is about to run in the main checkout.

$WHERE

Blocked: $(printf '%s' "$OFFENDER" | head -c 160)

If the main checkout really is the right place (refreshing the symlinked node_modules, for example), re-run it prefixed with MYSPEC_ALLOW_MAIN_CHECKOUT=1."
