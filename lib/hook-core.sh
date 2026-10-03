#!/usr/bin/env bash
# hook-core.sh
# Sourced, never run. The primitives every hook and the worktree libs used to
# copy: payload parsing, physical paths, checkout facts, the marker TTLs, the
# isolation-decision lookup and the settings reader. One copy, one test file
# (lib/tests/hook-core.test.sh).
#
# Found the way the hooks find every other lib: next to the hook's own
# directory (hooks/../lib in the plugin, .claude/hooks/../lib in a project),
# else under CLAUDE_PLUGIN_ROOT. A hook that cannot find it fails open, as it
# does without jq. bash 3.2 compatible (macOS /bin/bash).
#
# Every function reports through globals (CF_*, ISO_*, SETTING*) that only
# the sourcing scripts read.
# shellcheck disable=SC2034

HOOK_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# A session's own isolation decision, and the feature-implement marker, stay
# valid this long (8h).
HOOK_DECISION_TTL=28800
# Window in which a subagent inherits the newest decision (4h).
HOOK_INHERIT_TTL=14400

# jq expressions for payload_parse. HOOK_CWDS: the payload's cwd candidates,
# one per line. `cwd` is what Claude Code and Codex send; the tool's own
# `cwd`/`workdir` argument is the fallback. HOOK_SUBAGENT: non-empty only
# inside a subagent (agent_id, else agent_type).
HOOK_CWDS='[.cwd, .tool_input.cwd, .tool_input.workdir] | map(select(type == "string" and . != "")) | join("\n")'
HOOK_SUBAGENT='[.agent_id, .agent_type] | map(strings | select(. != "")) | first'

# glob_regex: the one glob compiler (lib/glob-regex.sh), for the scripts that
# read glob settings.
if [ -f "$HOOK_LIB/glob-regex.sh" ]; then
  # shellcheck source=lib/glob-regex.sh
  . "$HOOK_LIB/glob-regex.sh"
fi

# payload_parse <json> NAME=<jq expr>... -> sets each NAME to its value, with
# one jq call. A string is taken as is, less trailing newlines (as the
# per-field `$(jq ...)` calls it replaces read it), null or a missing field or
# a failing expression as empty, anything else as compact JSON (`true`,
# `[...]`). Unparseable input leaves every NAME empty. No jq regex: some jq
# builds lack it, and one failing call would empty every field.
# The locals carry a _pp_ prefix so no NAME a caller picks is shadowed.
payload_parse() {
  local _pp_json="$1" _pp_spec _pp_name _pp_prog="" _pp_out
  shift
  for _pp_spec in "$@"; do
    _pp_name="${_pp_spec%%=*}"
    case "$_pp_name" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) echo "hook-core: payload_parse: bad name '$_pp_name'" >&2; return 2 ;;
    esac
    printf -v "$_pp_name" '%s' ""
    _pp_prog="$_pp_prog\"$_pp_name=\" + ([try (${_pp_spec#*=})][0] | _str | @sh),"
  done
  [ -n "$_pp_prog" ] || return 0
  _pp_out=$(printf '%s' "$_pp_json" | jq -r "def _rt: if endswith(\"\\n\") then .[:-1] | _rt else . end; def _str: if type == \"string\" then _rt elif . == null then \"\" else tojson end; ${_pp_prog%,}" 2>/dev/null) || return 0
  eval "$_pp_out"
}

# first_dir <candidates, one per line> -> the first that is a directory.
first_dir() {
  local c
  while IFS= read -r c; do
    if [ -n "$c" ] && [ -d "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done <<< "$1"
  return 1
}

# existing_dir <path> -> the nearest directory at or above <path>.
existing_dir() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ] && [ ! -d "$d" ]; do
    d=$(dirname "$d")
  done
  [ -d "$d" ] || return 1
  printf '%s\n' "$d"
}

# physical_path <path> [base] -> absolute, every directory above the last
# component resolved physically (symlinks, `..`); the last component is kept
# as named, so a symlinked file is not followed. A relative path is taken from
# <base> (default $PWD). The part below the nearest existing directory is
# appended unresolved: there is nothing on disk to resolve.
physical_path() {
  local p="$1" dir rest phys
  case "$p" in
    /*) ;;
    *) p="${2:-$PWD}/$p" ;;
  esac
  dir=$(dirname "$p")
  rest=$(basename "$p")
  while [ ! -d "$dir" ]; do
    if [ "$dir" = "/" ] || [ "$dir" = "." ]; then
      printf '%s\n' "$p"
      return 0
    fi
    rest="$(basename "$dir")/$rest"
    dir=$(dirname "$dir")
  done
  phys=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${phys%/}" "$rest"
}

# physical_dir <dir> -> the directory resolved physically.
physical_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# checkout_facts <path> -> facts about the checkout holding <path> (or its
# nearest existing directory), from one `git rev-parse` call:
#   CF_ROOT        its toplevel, physical
#   CF_GIT_DIR     its git dir; CF_COMMON_DIR the repository's common dir
#   CF_LINKED      1 in a linked worktree (git dir differs from common dir)
#   CF_SUBMODULE   1 in a submodule; CF_SUPER is the superproject's toplevel
#   CF_MAIN        the main checkout of this checkout's repository: the working
#                  tree attached to the common dir. Outside a linked worktree
#                  that is CF_ROOT itself (a plain repo, a `--separate-git-dir`
#                  checkout, a submodule: each is its own repository's main
#                  checkout). In a linked worktree it is the parent of a common
#                  dir named `.git` that is not bare. It is empty when the
#                  common dir is bare (`git clone --bare` plus worktrees) or
#                  stands apart from its working tree (`--separate-git-dir`
#                  seen from a linked worktree): git records no path back to
#                  that tree, and `git worktree list` then names the git dir.
# Fails, clearing them all, outside a work tree (no repository, a bare git
# dir). One-entry cache: a hook asks about the same place repeatedly.
CF_KEY="" CF_ROOT="" CF_GIT_DIR="" CF_COMMON_DIR="" CF_SUPER="" CF_MAIN=""
CF_LINKED=0 CF_SUBMODULE=0
checkout_facts() {
  local dir out bare line
  local -a f
  dir=$(existing_dir "$1") || dir=""
  [ "$dir" = "$CF_KEY" ] && [ -n "$CF_KEY" ] && [ -n "$CF_ROOT" ] && return 0
  CF_KEY="$dir" CF_ROOT="" CF_GIT_DIR="" CF_COMMON_DIR="" CF_SUPER="" CF_MAIN=""
  CF_LINKED=0 CF_SUBMODULE=0
  [ -n "$dir" ] || return 1
  out=$(git -C "$dir" rev-parse --path-format=absolute --show-toplevel --git-dir \
    --git-common-dir --show-superproject-working-tree 2>/dev/null) || return 1
  f=()
  while IFS= read -r line; do f+=("$line"); done <<< "$out"
  case "${f[0]:-}|${f[1]:-}|${f[2]:-}" in
    /*'|'/*'|'/*) ;;
    *) return 1 ;;
  esac
  CF_ROOT="${f[0]}" CF_GIT_DIR="${f[1]}" CF_COMMON_DIR="${f[2]}" CF_SUPER="${f[3]:-}"
  [ -z "$CF_SUPER" ] || CF_SUBMODULE=1
  if [ "$CF_GIT_DIR" = "$CF_COMMON_DIR" ]; then
    CF_MAIN="$CF_ROOT"
  else
    CF_LINKED=1
    if [ "$(basename "$CF_COMMON_DIR")" = ".git" ]; then
      bare=$(git config --file "$CF_COMMON_DIR/config" --type=bool --get core.bare 2>/dev/null || printf 'false')
      [ "$bare" = true ] || CF_MAIN=$(dirname "$CF_COMMON_DIR")
    fi
  fi
  return 0
}

# hook_repo_root <cwd candidates> [myspec] -> the checkout the hook runs for:
# the toplevel of the first candidate inside a work tree (with `myspec`, a
# candidate holding .myspec.json counts too, for a project without git), else
# that of $PWD, else that of the project the hook is installed in.
hook_repo_root() {
  local c top
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if top=$(git -C "$c" rev-parse --show-toplevel 2>/dev/null); then
      printf '%s\n' "$top"
      return 0
    fi
    if [ -n "${2:-}" ] && [ -f "$c/.myspec.json" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done <<< "$1"
  for c in "$PWD" "$HOOK_LIB/../.."; do
    if top=$(git -C "$c" rev-parse --show-toplevel 2>/dev/null); then
      printf '%s\n' "$top"
      return 0
    fi
  done
  return 1
}

# ai_dir <root> -> the doc tree configured in <root>/.myspec.json, without a
# leading ./ or trailing /; .ai, the documented default, when unset.
ai_dir() {
  local ai=""
  if [ -f "$1/.myspec.json" ]; then
    ai=$(jq -r '.aiDir // empty' "$1/.myspec.json" 2>/dev/null || printf '')
  fi
  ai="${ai#./}"
  while [ "${ai%/}" != "$ai" ]; do ai="${ai%/}"; done
  printf '%s\n' "${ai:-.ai}"
}

# isolation_decision <main root> <session id> <subagent> -> sets ISO_MODE
# (develop, worktree, or empty) and ISO_PATH (the recorded worktree path).
# The session's own marker decides while younger than HOOK_DECISION_TTL.
# Without one, a subagent (non-empty <subagent>) follows the newest marker
# younger than HOOK_INHERIT_TTL; a top-level session never inherits another
# session's answer (issue #146). Markers: .claude/state/isolation/<id>.json,
# written by set-isolation.sh.
isolation_decision() {
  local dir="$1/.claude/state/isolation" now newest
  ISO_MODE="" ISO_PATH=""
  [ -d "$dir" ] || return 0
  now=$(date +%s)
  if [ -n "$2" ] && [ -f "$dir/$2.json" ] && _iso_read "$dir/$2.json" "$HOOK_DECISION_TTL"; then
    return 0
  fi
  [ -n "$3" ] || return 0
  # shellcheck disable=SC2012 # ls -t is the portable mtime sort; the names are generated session ids
  # awk, not head: it reads all of ls, so no SIGPIPE under pipefail.
  newest=$(ls -t "$dir"/*.json 2>/dev/null | awk 'NR == 1' || printf '')
  if [ -n "$newest" ] && [ -f "$newest" ]; then
    _iso_read "$newest" "$HOOK_INHERIT_TTL" || true
  fi
}

# _iso_read <marker> <ttl> -> sets ISO_MODE/ISO_PATH when the marker is
# younger than <ttl>; fails otherwise. Uses `now` from the caller.
_iso_read() {
  local mode path at
  # \037, not a tab: IFS whitespace collapses, so an empty mode would shift
  # the fields.
  mode=$(jq -r '[.mode // "", .worktree_path // "", (.decided_at // 0 | tostring)] | join("\u001f")' "$1" 2>/dev/null || printf '')
  IFS=$'\037' read -r mode path at <<< "$mode"
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  [ $(( now - at )) -lt "$2" ] || return 1
  ISO_MODE="$mode" ISO_PATH="$path"
}

# pretool_deny <reason> -> prints the PreToolUse deny (plus the legacy fields
# older hosts read) and exits 0. An allowed call prints nothing: for
# PreToolUse {"decision": "approve"} is the deprecated spelling of
# permissionDecision "allow", which would skip the user's permission prompt.
pretool_deny() {
  local reason
  reason=$(printf '%s' "$1" | jq -Rs .)
  printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": %s}, "decision": "block", "reason": %s}\n' "$reason" "$reason"
  exit 0
}

# decision_block <printf format> [arg...] -> prints the formatted reason as
# {"decision": "block", "reason": ...}, the PostToolUse and Stop form the
# harness shows the agent, and exits 0.
decision_block() {
  local reason
  # shellcheck disable=SC2059 # the format is the caller's
  reason=$(printf "$@" | jq -Rs .)
  printf '{"decision": "block", "reason": %s}\n' "$reason"
  exit 0
}

# read_setting <dotted key> <root> -> sets SETTING to the value as JSON and
# SETTING_NOTES to the reader's notes (what it ignored, or why it failed),
# through the one settings reader (lib/myspec-config.sh, beside this file).
# Fails without the reader, or when it fails.
read_setting() {
  local err rc=0
  SETTING="" SETTING_NOTES=""
  [ -f "$HOOK_LIB/myspec-config.sh" ] || return 1
  err=$(mktemp "${TMPDIR:-/tmp}/.myspec-cfg.XXXXXX") || return 1
  SETTING=$(bash "$HOOK_LIB/myspec-config.sh" get "$1" --root "$2" 2>"$err") || rc=$?
  SETTING_NOTES=$(sed 's/^myspec-config: //' "$err")
  rm -f "$err"
  return "$rc"
}
