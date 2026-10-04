#!/usr/bin/env bash
# session-event.sh
# The session-state file: one append-only JSONL file per session,
# .claude/state/sessions/<session_id>.jsonl in the main checkout, beside the
# session's live log (<session_id>.md). The only writer and reader of it.
# Sourced by the hooks (after lib/hook-core.sh), run by skills and libs.
#
# One event per line, each with "at" (epoch seconds), added on append:
#   {"t":"write","root":<checkout>,"rel":<repo-relative path>,"kind":"code|file","agent":<agent_id>}
#       mark-code-changed.sh, per written file; "agent" only from a subagent
#   {"t":"verified","root":<checkout>}
#       verify-before-stop.sh, per checkout it ran the checks in
#   {"t":"isolation","mode":"develop|worktree|","path":<worktree>,"note":<text>}
#       set-isolation.sh; an empty mode is a --reset
#   {"t":"implement","state":"start|stop"}
#       mark-code-changed.sh, when a Bash command runs `session-event.sh
#       implement start|stop` (the model never sees its session id; the
#       hook's payload carries it)
#
# Subagents share their parent's session_id (#225), so a subagent's events
# land in, and its reads come from, the parent's file. There is no
# cross-session lookup: a decision is never inherited from another session.
#
# Appends are one `printf '%s\n'` of one short line to a file opened with
# O_APPEND (`>>`), so concurrent subagents' lines do not interleave. Readers
# skip a line that does not parse (a truncated last line).
#
# Usage (run):
#   session-event.sh [--root <dir>] append <session_id> <json object>
#   session-event.sh [--root <dir>] events <session_id>
#   session-event.sh implement start|stop
# --root names a directory in the checkout (default: the cwd's); the file
# lives in that checkout's main checkout. `implement` prints a note and
# records nothing itself: mark-code-changed.sh records it with the session id.
#
# bash 3.2 compatible (macOS /bin/bash).
# SC2034: the globals (ISO_*) are read by the sourcing scripts. SC2016: the
# single-quoted programs are jq, whose $names are jq variables.
# shellcheck disable=SC2034,SC2016

if ! declare -F checkout_facts >/dev/null 2>&1; then
  # shellcheck source=lib/hook-core.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-core.sh"
fi

# The /tmp ledger mark-code-changed.sh kept until this file replaced it:
# imported once per session, for one minor release (docs/stop-gate.md).
SESSION_LEGACY_LEDGER_DIR=/tmp

# jq: the events of a file, read with -R. A line that is not a JSON object
# (a truncated last line, garbage) is skipped.
SESSION_EVENTS_JQ='inputs | try fromjson catch empty | select(type == "object" and (.t | type) == "string")'

# session_home <path> -> the checkout whose state directory holds the session
# file for <path>: the main checkout of the checkout holding it (CF_MAIN, or
# the checkout itself when git names none), after climbing out of any
# submodule into its superproject, so a submodule write is filed with the
# checkout that verifies it. Without git, the nearest directory holding a
# .myspec.json.
session_home() {
  local dir root main
  if checkout_facts "$1"; then
    root="$CF_ROOT" main="${CF_MAIN:-$CF_ROOT}"
    while [ "$CF_SUBMODULE" = 1 ] && [ -n "$CF_SUPER" ] && checkout_facts "$CF_SUPER"; do
      root="$CF_ROOT" main="${CF_MAIN:-$CF_ROOT}"
    done
    printf '%s\n' "${main:-$root}"
    return 0
  fi
  dir=$(existing_dir "$1") || return 1
  dir=$(physical_dir "$dir") || return 1
  while :; do
    if [ -f "$dir/.myspec.json" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" != "/" ] || return 1
    dir=$(dirname "$dir")
  done
}

# session_tracked <home> -> 0 when the checkout uses the state file: a myspec
# project or one with a stop gate. A write in an unrelated repository leaves
# no state tree there.
session_tracked() {
  [ -f "$1/.myspec.json" ] || [ -f "$1/.claude/verification.json" ]
}

# session_file <home> <session id> -> the file's path. Fails on an id that
# cannot be a file name.
session_file() {
  case "$2" in
    ''|.*|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  printf '%s/.claude/state/sessions/%s.jsonl\n' "$1" "$2"
}

# _session_import <file> <session id>: when the legacy ledger
# (/tmp/.myspec-session-writes-<id>) exists and <file> does not, converts it
# into <file> once and renames it to .imported. Lines: `<kind>\t<root>\t<rel>`
# with an optional agent_id field, and `verified\t<root>\t-`.
_session_import() {
  local legacy="$SESSION_LEGACY_LEDGER_DIR/.myspec-session-writes-$2" out
  if [ ! -f "$legacy" ] || [ -e "$1" ]; then
    return 0
  fi
  out=$(jq -c -R -n --argjson at "$(date +%s)" '
    inputs | split("\t") | select(length >= 3)
    | if .[0] == "verified" then {t: "verified", root: .[1], at: $at}
      elif .[0] == "code" or .[0] == "file" then
        {t: "write", root: .[1], rel: .[2], kind: .[0]}
        + (if (.[3] // "") != "" then {agent: .[3]} else {} end) + {at: $at}
      else empty end' "$legacy" 2>/dev/null) || return 0
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 0
  [ -z "$out" ] || printf '%s\n' "$out" >> "$1"
  mv -f "$legacy" "$legacy.imported" 2>/dev/null || true
}

# session_path <home> <session id> -> the file's path, after the one-time
# legacy import. Every reader and writer goes through it.
session_path() {
  local f
  f=$(session_file "$1" "$2") || return 1
  _session_import "$f" "$2"
  printf '%s\n' "$f"
}

# session_append <home> <session id> <json object>: appends the object with
# "at" set to now, as one line. Fails on anything but an object with a
# string "t".
session_append() {
  local f line
  f=$(session_path "$1" "$2") || return 1
  line=$(printf '%s' "$3" | jq -c --argjson at "$(date +%s)" \
    'if type == "object" and (.t | type) == "string" then . + {at: $at} else error("not an event") end' 2>/dev/null) || return 1
  case "$line" in *$'\n'*) return 1 ;; esac
  mkdir -p "$(dirname "$f")" || return 1
  # A truncated last line (a writer killed mid-write) would swallow this
  # event too: start on a fresh line.
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then
    line=$'\n'"$line"
  fi
  printf '%s\n' "$line" >> "$f"
}

# session_query <home> <session id> <jq program over $ev, the event array>
# [jq args...] -> the program's raw output; nothing when the file is absent.
session_query() {
  local f prog="$3"
  f=$(session_path "$1" "$2") || return 0
  [ -f "$f" ] || return 0
  shift 3
  jq -r -R -n "$@" "[$SESSION_EVENTS_JQ] as \$ev | $prog" "$f" 2>/dev/null || true
}

# session_events <home> <session id> -> the parsed events, one per line.
session_events() {
  session_query "$1" "$2" '$ev[] | tojson'
}

# session_armed_roots <home> <session id> -> each checkout with a code write
# after its last verified event, in first-written order.
session_armed_roots() {
  session_query "$1" "$2" '
    reduce $ev[] as $e ({order: [], armed: {}};
      if ($e.root | type) != "string" then .
      elif $e.t == "verified" then .armed[$e.root] = false
      elif $e.t == "write" and $e.kind == "code" then
        (if .armed | has($e.root) then . else .order += [$e.root] end)
        | .armed[$e.root] = true
      else . end)
    | . as $s | $s.order[] | select($s.armed[.])'
}

# session_written <home> <session id> <root> -> the repo-relative paths the
# session wrote in <root>, code or not, those in a checkout nested inside it
# (a submodule) included, sorted and unique.
session_written() {
  session_query "$1" "$2" '
    $ev[] | select(.t == "write" and (.root | type) == "string" and (.rel | type) == "string")
    | if .root == $r then .rel
      elif (.root | startswith($r + "/")) then .root[($r | length) + 1:] + "/" + .rel
      else empty end' --arg r "$3" | LC_ALL=C sort -u
}

# session_seen <home> <session id> <kind> <root> <rel> <agent> -> 0 when the
# same write is already recorded since <root>'s last verified event.
session_seen() {
  [ "$(session_query "$1" "$2" '
    reduce ($ev[] | select(.root == $r)) as $e (false;
      if $e.t == "verified" then false
      elif $e.t == "write" and $e.rel == $p and $e.kind == $k and ($e.agent // "") == $a then true
      else . end)' --arg k "$3" --arg r "$4" --arg p "$5" --arg a "$6")" = true ]
}

# session_isolation <home> <session id> -> sets ISO_MODE (develop, worktree,
# or empty) and ISO_PATH from the session's last isolation event, while it is
# younger than HOOK_DECISION_TTL. A subagent reads its parent's, by the
# shared session id.
session_isolation() {
  local out mode path at
  ISO_MODE="" ISO_PATH=""
  # \037, not a tab: IFS whitespace collapses, so an empty mode would shift
  # the fields.
  out=$(session_query "$1" "$2" '
    [$ev[] | select(.t == "isolation")] | last // empty
    | [(.mode // "" | tostring), (.path // "" | tostring), (.at // 0 | tostring)] | join("\u001f")')
  [ -n "$out" ] || return 0
  IFS=$'\037' read -r mode path at <<< "$out"
  case "$at" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $(date +%s) - at )) -lt "$HOOK_DECISION_TTL" ] || return 0
  ISO_MODE="$mode" ISO_PATH="$path"
}

# session_implement_active <home> <session id> -> 0 while the session's last
# implement event is a start no older than HOOK_DECISION_TTL (and not dated
# in the future). An older start is a crashed run and counts for nothing.
session_implement_active() {
  local at age
  at=$(session_query "$1" "$2" '
    [$ev[] | select(.t == "implement")] | last // empty
    | select(.state == "start") | .at | numbers | floor')
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - at ))
  [ "$age" -ge 0 ] && [ "$age" -le "$HOOK_DECISION_TTL" ]
}

# Run as a script: the CLI above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  command -v jq >/dev/null 2>&1 || { echo "session-event: jq is required" >&2; exit 1; }
  SE_ROOT="$PWD"
  if [ "${1:-}" = "--root" ]; then
    SE_ROOT="${2:-}"
    shift 2 || { echo "session-event: --root needs a directory" >&2; exit 1; }
  fi
  case "${1:-}" in
    implement)
      case "${2:-}" in
        start|stop) ;;
        *) echo "usage: session-event.sh implement start|stop" >&2; exit 1 ;;
      esac
      echo "implement $2: recorded for this session by the mark-code-changed hook"
      exit 0
      ;;
    append|events)
      [ -n "${2:-}" ] || { echo "usage: session-event.sh [--root <dir>] append <session_id> <json> | events <session_id>" >&2; exit 1; }
      SE_HOME=$(session_home "$SE_ROOT") || { echo "session-event: $SE_ROOT is in no checkout" >&2; exit 1; }
      session_file "$SE_HOME" "$2" >/dev/null || { echo "session-event: bad session id '$2'" >&2; exit 1; }
      if [ "$1" = events ]; then
        session_events "$SE_HOME" "$2"
      else
        session_append "$SE_HOME" "$2" "${3:-}" || { echo "session-event: not an event: ${3:-}" >&2; exit 1; }
      fi
      ;;
    *)
      echo "usage: session-event.sh [--root <dir>] append|events <session_id> [json] | implement start|stop" >&2
      exit 1
      ;;
  esac
fi
