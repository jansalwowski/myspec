#!/usr/bin/env bash
# session-event.sh
# The session-state file: one append-only JSONL file per session,
# .claude/state/sessions/<session_id>.jsonl in the main checkout, beside the
# session's live log (<session_id>.md); myspec-state/sessions/ in the git
# common dir for a repository with no main checkout (session_home,
# session_dir). The only writer and reader of it.
# Sourced by the hooks (after lib/hook-core.sh), run by skills and libs.
#
# One event per line, each with "at" (epoch seconds), added on append:
#   {"t":"write","root":<checkout>,"rel":<repo-relative path>,"kind":"code|file","via":"bash|tool","blob":<id>,"agent":<agent_id>}
#       mark-code-changed.sh, per written file; "agent" only from a subagent;
#       "blob" (the file after the write) only for a Bash write to a file the
#       content checks cover
#   {"t":"pre","root":<checkout>,"rel":<repo-relative path>,"blob":<id or "">}
#       mark-code-changed.sh at PreToolUse, the file before a Bash write
#   {"t":"verified","root":<checkout>}
#       verify-before-stop.sh, per checkout it ran the checks in
#   {"t":"isolation","mode":"develop|worktree|","path":<worktree>,"note":<text>}
#       set-isolation.sh; an empty mode is a --reset
#   {"t":"implement","state":"start|stop"}
#       mark-code-changed.sh, when a Bash command runs `session-event.sh
#       implement start|stop` (the model never sees its session id; the
#       hook's payload carries it)
#   {"t":"notice","what":<key>}
#       a one-time step was taken: "guard-settings" (guard-worktree-context.sh
#       denied once because the settings reader failed)
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

# The 2.x state this file replaced — the /tmp write ledger, the isolation
# marker, the implement marker — is not read: 3.0 ships without the one-
# release import shim (#266), and update tells the user to finish open
# sessions first.

# jq: the events of a file, read with -R. A line that is not a JSON object
# (a truncated last line, garbage) is skipped.
SESSION_EVENTS_JQ='inputs | try fromjson catch empty | select(type == "object" and (.t | type) == "string")'

# session_home <path> -> where the session file for <path> lives: the main
# checkout of the checkout holding it (CF_MAIN), after climbing out of any
# submodule into its superproject, so a submodule write is filed with the
# checkout that verifies it. A repository with no main checkout git can name
# from every worktree (a bare clone with worktrees, a --separate-git-dir
# checkout) gets its common dir instead, so all its worktrees share one file
# (session_dir). Without git, the nearest directory holding a .myspec.json.
session_home() {
  local dir
  if checkout_facts "$1"; then
    while [ "$CF_SUBMODULE" = 1 ] && [ -n "$CF_SUPER" ] && checkout_facts "$CF_SUPER"; do :; done
    if [ -n "$CF_MAIN" ] && [ "$CF_COMMON_DIR" = "$CF_MAIN/.git" ]; then
      printf '%s\n' "$CF_MAIN"
    else
      printf '%s\n' "$CF_COMMON_DIR"
    fi
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

# session_tracked_at <home> <checkout> -> 0 when the session home or the
# checkout written to is tracked: a linked worktree's branch can add the stop
# gate, or .myspec.json, that its main checkout does not have yet. The
# events still go to <home>.
session_tracked_at() {
  session_tracked "$1" || { [ -n "${2:-}" ] && session_tracked "$2"; }
}

# session_dir <home> -> the directory holding the session files of <home>:
# .claude/state/sessions/ in a checkout, myspec-state/sessions/ in a git
# common dir (session_home). A checkout passed directly whose repository
# files under its common dir (a --separate-git-dir main checkout) maps there
# too, so a reader given the checkout finds the writers' file.
session_dir() {
  if [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ ! -e "$1/.git" ]; then
    printf '%s/myspec-state/sessions\n' "$1"
    return 0
  fi
  if [ -e "$1/.git" ] && [ ! -d "$1/.git" ] && checkout_facts "$1" && [ "$CF_ROOT" = "$1" ] \
      && [ "$CF_SUBMODULE" = 0 ] && [ "$CF_LINKED" = 0 ] && [ "$CF_COMMON_DIR" != "$1/.git" ]; then
    printf '%s/myspec-state/sessions\n' "$CF_COMMON_DIR"
    return 0
  fi
  printf '%s/.claude/state/sessions\n' "$1"
}

# session_file <home> <session id> -> the file's path. Fails on an id that
# cannot be a file name.
session_file() {
  local dir
  case "$2" in
    ''|.*|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  dir=$(session_dir "$1")
  printf '%s/%s.jsonl\n' "$dir" "$2"
}

# session_keep <home> <session id> <root> <rel> -> "kept:<id>": copies the
# file as it is now to <session file without .jsonl>.blobs/<id>, <id> being
# the blob id of its bytes (computed, not written to the object store). The
# Bash-write snapshot when the object store is read-only (mark-code-changed.sh
# snapshot_blob); session-clean removes the directory with the file. Fails
# when the copy cannot be written.
session_keep() {
  local f dir id
  f=$(session_file "$1" "$2") || return 1
  dir="${f%.jsonl}.blobs"
  id=$(git -C "$3" hash-object --no-filters -- "$4" 2>/dev/null) || return 1
  case "$id" in ''|*[!0-9a-f]*) return 1 ;; esac
  if [ ! -f "$dir/$id" ]; then
    mkdir -p "$dir" 2>/dev/null || return 1
    if ! { cp -- "$3/$4" "$dir/$id.$$" 2>/dev/null && mv -f -- "$dir/$id.$$" "$dir/$id"; }; then
      rm -f -- "$dir/$id.$$"
      return 1
    fi
  fi
  printf 'kept:%s\n' "$id"
}

# session_kept <home> <session id> <id> -> the path of the copy session_keep
# made; fails when <id> is not one or the copy is gone.
session_kept() {
  local f
  case "$3" in ''|*[!0-9a-f]*) return 1 ;; esac
  f=$(session_file "$1" "$2") || return 1
  [ -f "${f%.jsonl}.blobs/$3" ] || return 1
  printf '%s\n' "${f%.jsonl}.blobs/$3"
}

# _session_write <file> <line>: appends one line, starting on a fresh line
# when the file ends in a truncated one (a writer killed mid-write), which
# would otherwise swallow this line too. Every append goes through it.
_session_write() {
  local line="$2"
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
    line=$'\n'"$line"
  fi
  printf '%s\n' "$line" >> "$1"
}

# session_append <home> <session id> <json object>: appends the object with
# "at" set to now, as one line. Fails on anything but an object with a
# string "t".
session_append() {
  local f line
  f=$(session_file "$1" "$2") || return 1
  line=$(printf '%s' "$3" | jq -c --argjson at "$(date +%s)" \
    'if type == "object" and (.t | type) == "string" then . + {at: $at} else error("not an event") end' 2>/dev/null) || return 1
  case "$line" in *$'\n'*) return 1 ;; esac
  _session_write "$f" "$line"
}

# session_query <home> <session id> <jq program over $ev, the event array>
# [jq args...] -> the program's raw output; nothing when the file is absent.
session_query() {
  local f prog="$3"
  f=$(session_file "$1" "$2") || return 0
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

# jq: the session's write events, from $ev: a `write` with a string root and
# rel. Every query over the files a session wrote starts from it.
SESSION_WRITES_JQ='$ev[] | select(.t == "write" and (.root | type) == "string" and (.rel | type) == "string")'

# session_written <home> <session id> [root] -> the files the session wrote,
# code or not, sorted and unique. With <root>: the repo-relative paths in
# <root>, those in a checkout nested inside it (a submodule) included.
# Without: every file, as `<root>\t<rel>` lines.
session_written() {
  session_query "$1" "$2" "$SESSION_WRITES_JQ"'
    | if $r == "" then .root + "\t" + .rel
      elif .root == $r then .rel
      elif (.root | startswith($r + "/")) then .root[($r | length) + 1:] + "/" + .rel
      else empty end' --arg r "${3:-}" | LC_ALL=C sort -u
}

# session_bash_writes <home> <session id> -> one `<root>\t<rel>\t<before>\t<after>`
# line per Bash write that carries an after-blob (mark-code-changed.sh), in
# order: the input of the Stop gate's content checks (lib/stop-gate/content.sh).
# <before> is the blob of the `pre` event recorded for the file since its
# last write event, "-" when that event found no file, else the after-blob
# of the session's previous Bash write to it, else "?" (unknown: no snapshot
# was taken). A write whose after-blob is "" (the file is gone) is left out;
# one whose after-blob is "@" (judged but not hashed) is kept, and the Stop
# gate reads the file itself.
session_bash_writes() {
  session_query "$1" "$2" '
    reduce ($ev[] | select(.t == "pre" or .t == "write")
      | select((.root | type) == "string" and (.rel | type) == "string")) as $e
      ({pre: {}, last: {}, out: []};
      ($e.root + "\t" + $e.rel) as $k
      | if $e.t == "pre" then .pre[$k] = (if $e.blob == "" then "-" else ($e.blob | tostring) end)
        elif $e.via == "bash" and ($e.blob | type) == "string" then
          (if $e.blob == "" then . else .out += [$k + "\t" + (.pre[$k] // .last[$k] // "?") + "\t" + $e.blob] end)
          | .last[$k] = (if $e.blob == "" then "-" else $e.blob end) | del(.pre[$k])
        else del(.pre[$k]) | del(.last[$k]) end)
    | .out[]'
}

# session_seen <home> <session id> <kind> <root> <rel> <agent> [via] -> 0 when
# the same write is already recorded since <root>'s last verified event.
session_seen() {
  [ "$(session_query "$1" "$2" '
    reduce ($ev[] | select(.root == $r)) as $e (false;
      if $e.t == "verified" then false
      elif $e.t == "write" and $e.rel == $p and $e.kind == $k and ($e.agent // "") == $a
        and ($e.via // "") == $v then true
      else . end)' --arg k "$3" --arg r "$4" --arg p "$5" --arg a "$6" --arg v "${7:-}")" = true ]
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
