#!/usr/bin/env bash
# require-reuse-audit.sh
# PreToolUse hook (Write|Edit|MultiEdit|NotebookEdit matcher) — denies a
# write that would leave a `.../features/*/tech-spec.md` without a valid
# `## Reuse audit` (or `### Reuse audit`) section, at the two moments the
# section is the call's own doing (#263):
#   - the tech-spec is created (a Write to a path that does not exist);
#   - a Write or Edit changes the section, or the opt-out marker, from what
#     the file holds now (a deleted heading, a rewritten table, an added row).
# An edit elsewhere in a tech-spec is never judged for the section, so a
# tech-spec written before this gate is not retro-blocked.
#
# Policy: every tech-spec must enumerate reuse candidates from the project's
# shared surfaces before introducing new code (prevents reinvention). The
# `feature-tech-spec` skill produces the section; this hook is the mechanical
# gate. `feature-tech-spec-review` is the second pass.
#
# Validation (lib/content-checks.sh, reuse_audit_issues; all must hold):
#   - a `## Reuse audit` / `### Reuse audit` heading exists
#   - a markdown table follows it with >= 1 data row
#   - every row has 4 cells; Decision in {reuse, skip}; skip rows have a Reason
# Opt-out, per file: `<!-- myspec:reuse-audit skip: <reason> -->` anywhere in
# the tech-spec counts as a skip decision for the document. The 2.x
# repo-global `reuseAudit.enabled` setting is gone (the 3.0.0-reuse-audit
# migration drops it).
#
# A Bash write (a heredoc) never reaches this hook: the Stop gate validates a
# tech-spec the session created (lib/stop-gate/content.sh).
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
  jq -nc --arg r "$LIB_MISSING" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi
# hook-core.sh alone is not enough: the checks live in content-checks.sh,
# which sources markdown-section-check.sh. Name what is missing, as above,
# rather than approve in silence.
LIB_MISSING=""
for f in content-checks.sh markdown-section-check.sh; do
  [ -f "$(dirname "$HOOK_CORE")/$f" ] || LIB_MISSING="${LIB_MISSING:+$LIB_MISSING, }$f"
done
if [ -n "$LIB_MISSING" ]; then
  LIB_MISSING="myspec lib missing: $LIB_MISSING not found under \${CLAUDE_PLUGIN_ROOT}/lib (${CLAUDE_PLUGIN_ROOT}), so require-reuse-audit.sh checked nothing. The hook runs from the plugin's hooks.json since 3.0; a copy wired in .claude/settings.json is retired by /myspec:update."
  printf '%s\n' "$LIB_MISSING" >&2
  jq -nc --arg r "$LIB_MISSING" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
fi
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/content-checks.sh
. "$HOOK_LIB/content-checks.sh"

payload_parse "$(cat)" FILE_PATH=.tool_input.file_path TOOL_INPUT=.tool_input CWDS="$HOOK_CWDS"
[ -n "$FILE_PATH" ] || exit 0

reuse_audit_scope "$FILE_PATH" || exit 0

if [[ "$FILE_PATH" != /* ]]; then
  BASE_DIR=$(first_dir "$CWDS") || BASE_DIR="$PWD"
  FILE_PATH="$BASE_DIR/$FILE_PATH"
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/.myspec-ra.XXXXXX")
trap 'rm -f "$TMP"' EXIT
proposed_content "$TOOL_INPUT" "$FILE_PATH" "$TMP" || exit 0

# An existing tech-spec is judged only when the call changes the section or
# the marker; a new one always is.
if [ -f "$FILE_PATH" ]; then
  [ "$(reuse_audit_state "$FILE_PATH")" != "$(reuse_audit_state "$TMP")" ] || exit 0
elif [ "$PROPOSED_KIND" != write ] && [ ! -s "$TMP" ]; then
  # An edit to a path that does not exist (a typo) creates nothing: the
  # tool reports the missing file, which is the right message.
  exit 0
fi

DIAG=$(reuse_audit_issues "$TMP")
[ -n "$DIAG" ] || exit 0

pretool_deny "$(reuse_audit_reason "$FILE_PATH" "$DIAG")"
