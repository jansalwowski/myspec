#!/usr/bin/env bash
# housekeep-nudge.sh
# SessionStart hook — prints one line when /myspec:housekeep last ran more
# than 7 days ago, read from <state dir>/housekeep-last-run, which
# lib/housekeep.sh writes. The first session in a project with no stamp
# writes one and stays quiet, so the clock starts at install rather than
# nagging on day one.
#
# Reads one file and never runs the sweep itself: cleanup that happens
# unseen at session start could race a session still using a worktree.
# Prints nothing outside a myspec project, and always exits 0.

INPUT=$(cat 2>/dev/null)

# Same preamble as every non-Stop hook (lib-missing.test.sh): without the
# plugin's lib, say so on stderr instead of staying silent.
HOOK_CORE="${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"
if [ ! -f "$HOOK_CORE" ]; then
  LIB_MISSING="myspec lib missing: hook-core.sh not found under \${CLAUDE_PLUGIN_ROOT}/lib (CLAUDE_PLUGIN_ROOT is ${CLAUDE_PLUGIN_ROOT:-unset}). The hook did not run from the plugin's hooks.json; a copy wired in .claude/settings.json is retired by /myspec:update."
  printf '%s\n' "$LIB_MISSING" >&2
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/session-event.sh
. "$HOOK_LIB/session-event.sh"

payload_parse "$INPUT" SESSION_CWD=.cwd

# shellcheck disable=SC2153 # payload_parse assigned it
ROOT=$(hook_repo_root "$SESSION_CWD" myspec) || exit 0
HOME_DIR=$(session_home "$ROOT") || exit 0
session_tracked_at "$HOME_DIR" "$ROOT" || exit 0
STAMP="$(dirname "$(session_dir "$HOME_DIR")")/housekeep-last-run"
NOW=$(date +%s)

if [ ! -f "$STAMP" ]; then
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null && printf '%s\n' "$NOW" > "$STAMP" 2>/dev/null
  exit 0
fi

LAST=$(tr -cd '0-9' < "$STAMP" 2>/dev/null)
[ -n "$LAST" ] || LAST=0
DAYS=$(( (NOW - LAST) / 86400 ))
[ "$DAYS" -ge 7 ] || exit 0

jq -cn --arg m "myspec: housekeep last ran $DAYS days ago. Run /myspec:housekeep to clear merged branches, stale session state and idle brainstorm sessions." \
  '{systemMessage: $m}'
exit 0
