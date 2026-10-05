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
# Decision: the session's last `isolation` event in
# .claude/state/sessions/<session_id>.jsonl (gitignored), written by
# lib/set-isolation.sh and read through lib/session-event.sh. The block
# messages print the lib's resolved path: the model runs them through Bash,
# where CLAUDE_PLUGIN_ROOT is not set.
#
# Subagents cannot call AskUserQuestion. They share their parent's session_id
# (issue #225), so a subagent reads its parent's decision from the same file.
# No session is handed another session's answer (issue #146): there is no
# lookup across session files.
#
# Configuration (all optional, .myspec.json, read through lib/myspec-config.sh;
# the defaults are its schema's):
#   aiDir                       doc tree; edits there never trigger the prompt
#   isolation.worktreeRoot      where worktrees live
#
# Output contract: a block prints the PreToolUse deny form (pretool_deny in
# lib/hook-core.sh). An allowed edit prints NOTHING.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
# The lib is the plugin's lib/, under CLAUDE_PLUGIN_ROOT, which the harness
# exports to a hook the plugin's hooks.json declares. Without it the hook
# cannot load hook-core.sh, and approving in silence would hide a gate that
# is not running (a stale copy wired in .claude/settings.json, a harness that
# did not export the variable). Say so, naming the variable and the repair.
# The same preamble sits in every non-Stop hook: hook-core is what is missing.
HOOK_CORE="${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"
if [ ! -f "$HOOK_CORE" ]; then
  LIB_MISSING="myspec lib missing: hook-core.sh not found under \${CLAUDE_PLUGIN_ROOT}/lib (CLAUDE_PLUGIN_ROOT is ${CLAUDE_PLUGIN_ROOT:-unset}). The hook did not run from the plugin's hooks.json; a copy wired in .claude/settings.json is retired by /myspec:update."
  printf '%s\n' "$LIB_MISSING" >&2
  jq -nc --arg r "$LIB_MISSING" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, decision: "block", reason: $r}'
  exit 0
fi
[ -f "$HOOK_CORE" ] && [ -f "$(dirname "$HOOK_CORE")/session-event.sh" ] || exit 0
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/session-event.sh
. "$HOOK_LIB/session-event.sh"

payload_parse "$(cat)" FILE_PATH=.tool_input.file_path SESSION_ID=.session_id \
  CWDS="$HOOK_CWDS"
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

# Both through the one settings reader (lib/myspec-config.sh), whose schema
# holds the defaults.
AI_DIR=$(ai_dir "$REPO_ROOT")
WORKTREE_ROOT=""
if read_setting isolation.worktreeRoot "$REPO_ROOT"; then
  WORKTREE_ROOT=$(printf '%s' "$SETTING" | jq -r 'if type == "string" then . else empty end' 2>/dev/null || printf '')
  [ -z "$SETTING_NOTES" ] || printf '%s\n' "$SETTING_NOTES" | sed 's/^/myspec-config: /' >&2
fi
WORKTREE_ROOT="${WORKTREE_ROOT%/}"
# An empty value, or a reader that failed, never opens the gate: the value
# only names where worktrees go, so the schema default stands in for it.
if [ -z "$WORKTREE_ROOT" ]; then
  WORKTREE_ROOT=$(jq -r '.keys["isolation.worktreeRoot"].default // empty' "$HOOK_LIB/myspec-config.schema.json" 2>/dev/null || printf '')
  WORKTREE_ROOT="${WORKTREE_ROOT:-.claude/worktrees}"
fi
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
# Distinct from EXEMPT_PREFIXES, which only suppress the prompt (branch 2) and
# are still subject to a worktree answer. These bypass the worktree block
# itself, so the list stays narrow: per-checkout state that another rule pins
# to the main checkout.
#
#   .claude/state/           gitignored harness state — live session logs,
#                            session-state files, the memory ID registry
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
# below then failed and the edit was approved as outside the repo. An
# ancestor that cannot be entered keeps the path as spelled: under set -e an
# unguarded failure would exit 1, which the harness reads as allow.
if P=$(physical_path "$ABS_PATH"); then
  ABS_PATH="$P"
fi

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
# the isolation question (branch 2 below), but once a session has answered
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
  \"$HOOK_LIB/worktree-provision.sh\" \"\$(git rev-parse --show-toplevel)/$WORKTREE_ROOT/<slug>\" --base origin/$DEFAULT_BRANCH

Use absolute paths and \`git -C <worktree>\` for all git operations. Full procedure: $PROCEDURE

Blocked edit: $REL_PATH"

# 1. This session's decision; a subagent's is its parent's, by the shared
#    session id (subagents cannot prompt, so they follow the parent).
session_isolation "$REPO_ROOT" "$SESSION_ID"
case "$ISO_MODE" in
  develop) exit 0 ;;
  worktree) pretool_deny "$WORKTREE_REASON" ;;
esac

# 2. No decision — ask, unless the file is exempt from prompting.
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
  \"$HOOK_LIB/set-isolation.sh\" $SESSION_ID develop
  \"$HOOK_LIB/set-isolation.sh\" $SESSION_ID worktree
To see the recorded decisions, or force a re-ask after the user changed the answer:
  \"$HOOK_LIB/set-isolation.sh\" --show
  \"$HOOK_LIB/set-isolation.sh\" --reset $SESSION_ID

Do NOT ask about a PR now — that question belongs at the end of the work. In develop mode the answer yes runs \"$HOOK_LIB/promote-to-worktree.sh\" --branch <type>/<slug> --title <subject> --only <path>... (procedure in $PROCEDURE).

If you are a SUBAGENT: do not prompt. Stop and report to your parent that no isolation decision exists.

Blocked edit: $REL_PATH"
