#!/usr/bin/env bash
# validate-frontmatter.sh
# PreToolUse hook (Write|Edit|MultiEdit|NotebookEdit matcher) — validates the
# frontmatter a Write or Edit of a ${aiDir}/**/*.md file would leave, and
# denies the call when it is wrong, so the agent fixes it before it lands.
# Reads aiDir from .myspec.json (required since 2.0; .ai when absent).
# Accepted fields mirror the framework's own templates: identity is any of
# title/name/topic/id/type; temporal is any of updated/last_updated/created/
# started/date. ${aiDir}/ideas/ is exempt (its seed docs ship frontmatter-less).
#
# What is judged (#263, lib/content-checks.sh): a Write that creates the doc
# by its whole content; any other Write, Edit or MultiEdit by the content it
# would leave, and only when that changes the frontmatter region (line 1
# through the closing `---`; a doc with no fence has none, so only adding one
# changes it). A body edit or a body rewrite of a doc whose frontmatter is
# already wrong is not blocked for it: the file is never rescanned for what
# was there before. A Bash write (a heredoc) never reaches this hook: the
# Stop gate validates a doc it created or whose frontmatter region it changed
# (lib/stop-gate/content.sh).
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
# hook-core.sh alone is not enough: the checks live in content-checks.sh,
# which sources markdown-section-check.sh. Name what is missing, as above,
# rather than approve in silence.
LIB_MISSING=""
for f in content-checks.sh markdown-section-check.sh; do
  [ -f "$(dirname "$HOOK_CORE")/$f" ] || LIB_MISSING="${LIB_MISSING:+$LIB_MISSING, }$f"
done
if [ -n "$LIB_MISSING" ]; then
  LIB_MISSING="myspec lib missing: $LIB_MISSING not found under \${CLAUDE_PLUGIN_ROOT}/lib (${CLAUDE_PLUGIN_ROOT}), so validate-frontmatter.sh checked nothing. The hook runs from the plugin's hooks.json since 3.0; a copy wired in .claude/settings.json is retired by /myspec:update."
  printf '%s\n' "$LIB_MISSING" >&2
  jq -nc --arg r "$LIB_MISSING" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, decision: "block", reason: $r}'
  exit 0
fi
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/content-checks.sh
. "$HOOK_LIB/content-checks.sh"

payload_parse "$(cat)" FILE_PATH=.tool_input.file_path TOOL_INPUT=.tool_input CWDS="$HOOK_CWDS"
[ -n "$FILE_PATH" ] || exit 0
REPO_ROOT=$(hook_repo_root "$CWDS" myspec) || exit 0

# Resolve to absolute path
if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$REPO_ROOT/$FILE_PATH"
fi

# Re-root on the FILE, not the cwd. A linked worktree lives inside the repo, so
# a doc written there arrives as <main>/.claude/worktrees/<slug>/<aiDir>/... and
# the aiDir prefix test below never matches — validation silently skipped every
# file written in a worktree, which for doc-heavy projects is most of them.
# Matches how mark-code-changed.sh and require-reuse-audit.sh already resolve.
if checkout_facts "$FILE_PATH"; then
  REPO_ROOT="$CF_ROOT"
fi

# aiDir from .myspec.json (ai_dir in lib/hook-core.sh). The trailing slash is
# stripped: the prefix test builds the glob ${AI_DIR}/*, and a configured
# ".ai/" would make that ".ai//*", which matches nothing and silently
# disables this hook — the same derived-pattern break the doctor flags as
# aidir-trailing-slash. No configured value: the documented default, never a
# guess from disk. aiDir is required since 2.0; the setup doctor reports its
# absence and `update` writes it. memory-files.mjs resolves the same way.
AI_DIR=$(ai_dir "$REPO_ROOT")

# Only markdown inside the AI documentation directory, ideas/ excepted (pure-
# shell prefix strip — no python3 dependency, no quote-injection via the path)
RELATIVE="${FILE_PATH#"$REPO_ROOT"/}"
frontmatter_scope "$AI_DIR" "$RELATIVE" || exit 0

TMP=$(mktemp "${TMPDIR:-/tmp}/.myspec-fm.XXXXXX")
trap 'rm -f "$TMP"' EXIT
proposed_content "$TOOL_INPUT" "$FILE_PATH" "$TMP" || exit 0

# A call to an existing doc, a Write included, is judged only when it changes
# the frontmatter region: a Write that keeps an already-broken header and
# rewrites the body adds no defect. A Write that creates the doc always is.
if [ -f "$FILE_PATH" ]; then
  [ "$(frontmatter_region "$FILE_PATH")" != "$(frontmatter_region "$TMP")" ] || exit 0
elif [ "$PROPOSED_KIND" != write ]; then
  exit 0
fi

ISSUES=$(frontmatter_issues "$TMP")
[ -n "$ISSUES" ] || exit 0

pretool_deny "$(frontmatter_reason "$RELATIVE" "$ISSUES" "$AI_DIR")"
