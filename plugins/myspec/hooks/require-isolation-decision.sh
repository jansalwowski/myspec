#!/usr/bin/env bash
# require-isolation-decision.sh
# PreToolUse hook (Write|Edit matcher) — gates the first SOURCE edit in the main
# checkout until an isolation decision (develop vs worktree) is recorded for the
# session. Contract: .claude/rules/work-isolation.md; the procedure the block
# messages cite: <aiDir>/work-isolation.md.
#
# Worktree detection: checkout_facts (lib/hook-core.sh). Inside a linked
# worktree the decision is already made, so its own files are approved.
#
# Marker: .claude/state/isolation/<session_id>.json  (gitignored), written by
# .claude/lib/set-isolation.sh.
#
# Subagents cannot call AskUserQuestion. Rather than prompting, a subagent with
# no marker of its own inherits the newest marker written within
# MYSPEC_INHERIT_TTL.
# Only a subagent does: inside one the hook input carries `agent_id` or
# `agent_type`. A top-level session (neither field) with no marker of its own
# is asked, never handed another session's answer (issue #146). Whether a
# subagent shares its parent's session_id is unsettled (issue #225); either way
# it lands on the parent's decision, through branch 1 if the id is shared and
# branch 2 if it is not.
#
# Configuration (all optional, .myspec.json):
#   aiDir                       doc tree; edits there never trigger the prompt
#   isolation.worktreeRoot      where worktrees live (default .claude/worktrees)
#
# Output contract: a block prints the PreToolUse deny form (pretool_deny in
# lib/hook-core.sh). An allowed edit prints NOTHING.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/hook-core.sh"
[ -f "$HOOK_CORE" ] || HOOK_CORE="${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"
[ -f "$HOOK_CORE" ] || exit 0
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"

# SUBAGENT is non-empty only inside a subagent; it gates inheritance (branch 2).
payload_parse "$(cat)" FILE_PATH=.tool_input.file_path SESSION_ID=.session_id \
  SUBAGENT="$HOOK_SUBAGENT" CWDS="$HOOK_CWDS"
[ -n "$FILE_PATH" ] || exit 0
REPO_ROOT=$(hook_repo_root "$CWDS") || exit 0

# The cwd is a linked worktree. That says nothing about the edited file: an
# absolute path can still point into the main checkout, which is the edit a
# worktree answer forbids (issue #224). Judge it against the main checkout the
# worktree belongs to; a file inside the worktree is approved below by its own
# root. A submodule, or a worktree whose main checkout git cannot name (a bare
# repository), keeps the approve.
CWD_ROOT="$REPO_ROOT"
checkout_facts "$REPO_ROOT" || exit 0
if [ "$CF_SUBMODULE" = 1 ] || [ -z "$CF_MAIN" ]; then
  exit 0
fi
REPO_ROOT="$CF_MAIN"

# Only a myspec project carries the isolation contract.
[ -f "$REPO_ROOT/.myspec.json" ] || exit 0

AI_DIR=$(ai_dir "$REPO_ROOT")
WORKTREE_ROOT=$(jq -r '.isolation.worktreeRoot // ".claude/worktrees"' "$REPO_ROOT/.myspec.json" 2>/dev/null)
WORKTREE_ROOT="${WORKTREE_ROOT%/}"
# Installed by init/update from the manifest `files` entry work-isolation.md.
PROCEDURE="$AI_DIR/work-isolation.md"

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
  *)  ABS_PATH="$CWD_ROOT/$FILE_PATH" ;;
esac

# Compare physical paths. The tool's file_path is the path as the session
# spelled it, which can run through a symlink (a linked home directory,
# macOS /tmp), while git reports the physical toplevel: the prefix strip
# below then failed and the edit was approved as outside the repo.
ABS_PATH=$(physical_path "$ABS_PATH")

# A linked worktree lives INSIDE the repo (<worktreeRoot>/<slug>/), so a file
# there is reached by a main-checkout-relative path and would otherwise be
# judged a main-checkout edit. Resolve the checkout from the FILE's own
# directory: a linked worktree there is the whole point of the session's
# isolation choice — approve it. So is a submodule.
if checkout_facts "$ABS_PATH" && { [ "$CF_LINKED" = 1 ] || [ "$CF_SUBMODULE" = 1 ]; }; then
  exit 0
fi

REL_PATH="${ABS_PATH#"$REPO_ROOT"/}"

# Prefix strip was a no-op → the file lives outside the repo (scratchpad, /tmp).
[ "$REL_PATH" != "$ABS_PATH" ] || exit 0

# Checked BEFORE any mode logic: these paths have exactly one correct location,
# so no isolation answer can redirect them. See the list's comment above.
for PREFIX in "${MAIN_CHECKOUT_ONLY_PREFIXES[@]}"; do
  case "$REL_PATH" in
    "$PREFIX"*) exit 0 ;;
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

DEFAULT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

WORKTREE_REASON="BLOCKED: this session chose WORKTREE isolation, but the edit targets the main checkout.

Create the worktree if you have not already, then make every edit inside it:
  git worktree add -b <type>/<slug> \"\$(git rev-parse --show-toplevel)/$WORKTREE_ROOT/<slug>\" origin/$DEFAULT_BRANCH
  .claude/lib/worktree-provision.sh \"\$(git rev-parse --show-toplevel)/$WORKTREE_ROOT/<slug>\" --base origin/$DEFAULT_BRANCH

Use absolute paths and \`git -C <worktree>\` for all git operations. Full procedure: $PROCEDURE

Blocked edit: $REL_PATH"

# 1. This session's own decision; 2. in a subagent, the inherited one
#    (subagents cannot prompt, so they follow the parent). A top-level
#    session never inherits; it falls through to the ask.
isolation_decision "$REPO_ROOT" "$SESSION_ID" "$SUBAGENT"
case "$ISO_MODE" in
  develop) exit 0 ;;
  worktree) pretool_deny "$WORKTREE_REASON" ;;
esac

# 3. No decision anywhere — ask, unless the file is exempt from prompting.
[ "$IS_EXEMPT" -eq 0 ] || exit 0

pretool_deny "BLOCKED: no work-isolation decision recorded for this session.

Before editing source files in the main checkout, ask where the work should happen. Call AskUserQuestion with ONE question:

  header:   \"Isolation\"
  question: \"This task edits source files. Where should the work happen?\"
  options:
    - \"develop\"  — \"Edits land in your checkout; test immediately. No branch yet.\"
    - \"Worktree\" — \"Isolated branch in $WORKTREE_ROOT/; PR opened when done.\"

Mark ONE option \"(Recommended)\" using the task-shape heuristic in $PROCEDURE, which holds the full procedure — do not present them as equals.

Then record the answer (session id is already filled in):
  .claude/lib/set-isolation.sh $SESSION_ID develop
  .claude/lib/set-isolation.sh $SESSION_ID worktree

Do NOT ask about a PR now — that question belongs at the end of the work.

If you are a SUBAGENT: do not prompt. Stop and report to your parent that no isolation decision exists.

Blocked edit: $REL_PATH"
