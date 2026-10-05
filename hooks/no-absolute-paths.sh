#!/usr/bin/env bash
# no-absolute-paths.sh
# PreToolUse hook (Write|Edit|MultiEdit|NotebookEdit matcher). It denies a
# call whose PROPOSED content contains an absolute homedir path (/Users/<name>,
# /home/<name>) or the encoded-cwd literal derived from one, before the file
# is touched.
#
# Policy (framework-files/rules/paths.md): committed docs and framework files
# must be portable across machines and users. Use the placeholders
# `<repo_root>` and `<encoded_cwd>` (and the harness-fixed
# `~/.claude-personal/...` prefix). The plugin's `lib/path-normalize.sh`
# exposes `normalize_path` and `encode_cwd`, which produce these forms.
#
# Scope (#163, lib/content-checks.sh): only what can leak into a shared
# artifact, that is a file inside a git work tree that is not gitignored
# there, of a doc kind anywhere or under .claude/, docs/ or the project aiDir.
# Only the content the call adds is read (Write content, Edit new_string,
# MultiEdit edits[].new_string, NotebookEdit new_source): the file on disk is
# never rescanned, so a leak already in it blocks no edit that leaves it
# alone (#263). A call carrying none of these is approved. A Bash write (a
# heredoc, sed -i) never reaches this hook: the Stop gate checks the lines it
# added (lib/stop-gate/content.sh).
#
# Output contract: a block prints the PreToolUse deny form (pretool_deny in
# lib/hook-core.sh). An allowed call prints NOTHING.

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
[ -f "$HOOK_CORE" ] && [ -f "$(dirname "$HOOK_CORE")/content-checks.sh" ] || exit 0
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/content-checks.sh
. "$HOOK_LIB/content-checks.sh"

# NEW_CONTENT is the content this call adds; HAS_NEW says whether the call
# carries any, HAS_CONTENT whether it is a whole-file Write.
payload_parse "$(cat)" FILE_PATH='.tool_input.file_path // .tool_input.notebook_path' \
  HAS_NEW='.tool_input | has("content") or has("new_string") or has("new_source") or has("edits")' \
  HAS_CONTENT='.tool_input | has("content")' \
  NEW_CONTENT='.tool_input | [.content, .new_string, .new_source, ((.edits // [])[] | .new_string)] | map(select(type == "string")) | join("\n")' \
  CWDS="$HOOK_CWDS"

[ -n "$FILE_PATH" ] || exit 0
[ "$HAS_NEW" = "true" ] || exit 0
[ -n "$NEW_CONTENT" ] || exit 0

# Resolve the file and its work tree physically, so a symlinked prefix
# (macOS /var -> /private/var) compares equal to what git reports. The file
# need not exist yet: a Write creates it.
BASE_DIR=$(first_dir "$CWDS") || BASE_DIR="$PWD"
REAL_PATH=$(physical_path "$FILE_PATH" "$BASE_DIR") || exit 0

# Outside any work tree (a scratchpad, $TMPDIR): nothing there is committed.
checkout_facts "$REAL_PATH" || exit 0
REPO_ROOT="$CF_ROOT"

case "$REAL_PATH" in
  "$REPO_ROOT"/*) REL_PATH="${REAL_PATH#"$REPO_ROOT"/}" ;;
  *) exit 0 ;;
esac

absolute_paths_scope "$REPO_ROOT" "$REL_PATH" || exit 0

TMP=$(mktemp "${TMPDIR:-/tmp}/.myspec-nap.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$NEW_CONTENT" > "$TMP"

MATCHES=$(absolute_path_findings "$TMP")
[ -n "$MATCHES" ] || exit 0

# A Write's content maps line for line onto the file; an edit's new text
# has lines of its own.
LABEL="line"
[ "$HAS_CONTENT" = "true" ] || LABEL="new text line"
FINDINGS=""
while IFS=$'\t' read -r n m; do
  [ -n "$m" ] || continue
  FINDINGS="${FINDINGS}${LABEL} ${n}"$'\t'"${m}"$'\n'
done <<< "$MATCHES"

pretool_deny "$(absolute_paths_reason "the content proposed for" "$REL_PATH" "$REPO_ROOT" "$FINDINGS")"
