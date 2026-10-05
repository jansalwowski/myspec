#!/usr/bin/env bash
# record-session-metrics.sh
# SessionEnd hook — records the finished session's field metrics (one JSON
# line per skill run and one per session) into the main checkout's
# .claude/state/metrics/runs.jsonl by running friction-scan with --emit.
# Local only: nothing is sent anywhere. Summarise with lib/friction-scan/stats.mjs.
#
# Never affects the session. SessionEnd cannot block, and Claude Code gives
# all SessionEnd hooks a shared 1.5 s budget, so this hook only starts the
# scan and returns: the scan runs detached (its own session, so closing the
# terminal does not kill it) under a hard time cap, with every stream sent to
# /dev/null. The hook itself prints nothing and always exits 0. A scan that
# fails or is killed at the cap records nothing; the scan writes all of its
# lines in one append, so it never leaves half a record.
#
# Off when any of these holds (the scan also checks .myspec.json
# "feedback": { "metrics": false }):
#   MYSPEC_DISABLE_METRICS=1, DO_NOT_TRACK set to anything but empty, 0,
#   false or FALSE (lib/myspec-config.schema.json matches the same values),
#   node, jq or lib/hook-core.sh missing, no transcript in the payload.
#
# MYSPEC_METRICS_CAP_SECONDS may lower the cap (the tests use it); a value
# above the default is ignored, so it can never raise it.

INPUT=$(cat 2>/dev/null)
exec >/dev/null 2>&1

[ "${MYSPEC_DISABLE_METRICS:-}" = "1" ] && exit 0
case "${DO_NOT_TRACK:-}" in ''|0|false|FALSE) ;; *) exit 0 ;; esac
command -v node || exit 0
command -v jq || exit 0

# The scan and hook-core are the plugin's lib/: the hook runs from the
# plugin's hooks.json, which exports CLAUDE_PLUGIN_ROOT.
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
  exit 0
fi
[ -f "$HOOK_CORE" ] || exit 0
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"

payload_parse "$INPUT" SESSION_ID=.session_id TRANSCRIPT=.transcript_path \
  SESSION_CWD=.cwd REASON=.reason

# shellcheck disable=SC2153 # payload_parse assigned it
[[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0
[ -f "$TRANSCRIPT" ] || exit 0
[ -d "$SESSION_CWD" ] || SESSION_CWD=$PWD
[[ "$REASON" =~ ^[a-z_]{1,32}$ ]] || REASON=""

SCAN="$HOOK_LIB/friction-scan/scan.mjs"
[ -f "$SCAN" ] || exit 0

CAP_SECONDS=30
if [[ "${MYSPEC_METRICS_CAP_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] && [ "$MYSPEC_METRICS_CAP_SECONDS" -lt "$CAP_SECONDS" ]; then
  CAP_SECONDS=$MYSPEC_METRICS_CAP_SECONDS
fi

ARGS=(--emit "--session=$SESSION_ID" "--transcript=$TRANSCRIPT")
[ -n "$REASON" ] && ARGS+=("--reason=$REASON")

# perl: setsid detaches from the terminal, and alarm survives exec, so SIGALRM
# ends node at the cap. GNU timeout is the fallback. With neither, skip: an
# uncapped background process is not something a hook should leave behind.
cd "$SESSION_CWD" || exit 0
if command -v perl; then
  perl -e 'use POSIX (); POSIX::setsid(); alarm shift; exec @ARGV or exit 0' \
    "$CAP_SECONDS" node "$SCAN" "${ARGS[@]}" </dev/null >/dev/null 2>&1 &
elif command -v timeout; then
  nohup timeout -s KILL "$CAP_SECONDS" node "$SCAN" "${ARGS[@]}" </dev/null >/dev/null 2>&1 &
fi
exit 0
