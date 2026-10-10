#!/usr/bin/env bash
# hook-core.sh
# Sourced, never run. The primitives every hook and the worktree libs used to
# copy: payload parsing, physical paths, checkout facts, the state TTL and the
# settings reader. One copy, one test file (lib/tests/hook-core.test.sh). The
# session-state file has its own lib, lib/session-event.sh.
#
# Found the way the hooks find every other lib: under CLAUDE_PLUGIN_ROOT, the
# plugin's installed directory, which the harness exports to every hook the
# plugin's hooks.json declares (since 3.0 nothing is copied into a project's
# .claude/). A hook that cannot find it fails open, as it does without jq.
# A lib run by a skill or by hand sources hook-core.sh beside itself.
# bash 3.2 compatible (macOS /bin/bash). git 2.31 or later
# is recommended: checkout_facts asks `git rev-parse --path-format=absolute`,
# and older git, which echoes the flag back, costs it a second call that
# resolves the relative git dirs itself (README "Installation").
#
# Every function reports through globals (CF_*, SETTING*) that only
# the sourcing scripts read.
# shellcheck disable=SC2034

HOOK_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# A session's isolation decision, and its feature-implement run, stay valid
# this long (8h; lib/session-event.sh).
HOOK_DECISION_TTL=28800

# jq expression for payload_parse: the payload's cwd candidates, one per line.
# `cwd` is what Claude Code sends; the tool's own `cwd`/`workdir`
# argument is the fallback.
HOOK_CWDS='[.cwd, .tool_input.cwd, .tool_input.workdir] | map(select(type == "string" and . != "")) | join("\n")'

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

# file_sha256 <file> -> the file's SHA-256, hex. Fails when the file is not
# a readable regular file or no hash tool exists (sha256sum on Linux and
# BusyBox, shasum on macOS, openssl as the last resort).
file_sha256() {
  local out
  [ -f "$1" ] && [ -r "$1" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum < "$1") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 < "$1") || return 1
  elif command -v openssl >/dev/null 2>&1; then
    out=$(openssl dgst -sha256 < "$1") || return 1
    out="${out##* }"
  else
    return 1
  fi
  printf '%s\n' "${out%% *}"
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
  local dir out bare line i
  local -a f
  dir=$(existing_dir "$1") || dir=""
  [ "$dir" = "$CF_KEY" ] && [ -n "$CF_KEY" ] && [ -n "$CF_ROOT" ] && return 0
  CF_KEY="$dir" CF_ROOT="" CF_GIT_DIR="" CF_COMMON_DIR="" CF_SUPER="" CF_MAIN=""
  CF_LINKED=0 CF_SUBMODULE=0
  [ -n "$dir" ] || return 1
  out=$(git -C "$dir" rev-parse --path-format=absolute --show-toplevel --git-dir \
    --git-common-dir 2>/dev/null) || return 1
  f=()
  while IFS= read -r line; do f+=("$line"); done <<< "$out"
  if [ "${f[0]:-}" = --path-format=absolute ]; then
    # git < 2.31 echoes the flag it does not know and prints the git dirs
    # relative to <dir>: ask again without it and resolve them here.
    out=$(git -C "$dir" rev-parse --show-toplevel --git-dir --git-common-dir 2>/dev/null) || return 1
    f=()
    while IFS= read -r line; do f+=("$line"); done <<< "$out"
    for i in 0 1 2; do
      case "${f[i]:-}" in
        ''|/*) ;;
        *) f[i]=$(cd "$dir" 2>/dev/null && cd "${f[i]}" 2>/dev/null && pwd -P) || return 1 ;;
      esac
    done
  fi
  case "${f[0]:-}|${f[1]:-}|${f[2]:-}" in
    /*'|'/*'|'/*) ;;
    *) return 1 ;;
  esac
  CF_ROOT="${f[0]}" CF_GIT_DIR="${f[1]}" CF_COMMON_DIR="${f[2]}"
  # --show-superproject-working-tree runs `git ls-files` in the parent
  # directory's repository, an extra process that walks a whole outer index
  # (a dotfiles home, a monorepo of repos). Asked only where a submodule can
  # be: git keeps a submodule's git dir under the superproject's
  # .git/modules/, so a repository whose common dir is named .git (a plain
  # checkout, a linked worktree of one) is none. A submodule whose .git directory sits
  # inside it (an existing clone added in place and never absorbed, see
  # `git submodule absorbgitdirs`) therefore reads as a plain repository.
  if [ "$(basename "$CF_COMMON_DIR")" != .git ]; then
    CF_SUPER=$(git -C "$dir" rev-parse --show-superproject-working-tree 2>/dev/null) || CF_SUPER=""
  fi
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
# that of $PWD, else that of CLAUDE_PROJECT_DIR, the project the harness
# started in (exported to hooks like CLAUDE_PLUGIN_ROOT).
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
  for c in "$PWD" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$c" ] || continue
    if top=$(git -C "$c" rev-parse --show-toplevel 2>/dev/null); then
      printf '%s\n' "$top"
      return 0
    fi
  done
  return 1
}

# ai_dir <root> -> the doc tree configured in <root>/.myspec.json, without a
# leading ./ or trailing /, read through the one settings reader (read_setting
# below), whose schema holds the default: no hook carries one of its own. A
# value the reader rejects (not a string, a file that is not JSON) is named on
# stderr and replaced by the schema default inside the reader; an empty
# string is unset and takes the same default here, read from the schema. A
# caller that asks per file (the content checks) resolves once per root and
# passes the value on.
ai_dir() {
  local ai="" dflt
  if read_setting aiDir "$1"; then
    ai=$(printf '%s' "$SETTING" | jq -r 'if type == "string" then . else empty end' 2>/dev/null || printf '')
    [ -z "$SETTING_NOTES" ] || printf '%s\n' "$SETTING_NOTES" | sed 's/^/myspec-config: /' >&2
  fi
  ai="${ai#./}"
  while [ "${ai%/}" != "$ai" ]; do ai="${ai%/}"; done
  if [ -z "$ai" ]; then
    dflt=$(jq -r '.keys.aiDir.default' "$HOOK_LIB/myspec-config.schema.json" 2>/dev/null || printf '')
    ai="${dflt:-.ai}"
  fi
  printf '%s\n' "$ai"
}

# protected_checkout <checkout root> -> 0 when the checkout's HEAD is one no
# write should land on before the isolation question (#348): a detached HEAD,
# the default branch (origin/HEAD, else main or master), or a branch matching
# an isolation.protectedBranches glob. PROTECTED_HEAD names it for a block
# message ("a detached HEAD", "branch main"). Fails outside a repository.
PROTECTED_HEAD=""
protected_checkout() {
  local branch dflt pat rc=0
  PROTECTED_HEAD=""
  branch=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    1) PROTECTED_HEAD="a detached HEAD"; return 0 ;;
    *) return 1 ;;
  esac
  dflt=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
  dflt="${dflt#origin/}"
  if [ -n "$dflt" ]; then
    [ "$branch" != "$dflt" ] || PROTECTED_HEAD="branch $branch"
  else
    case "$branch" in main|master) PROTECTED_HEAD="branch $branch" ;; esac
  fi
  if [ -z "$PROTECTED_HEAD" ] && read_setting isolation.protectedBranches "$1"; then
    [ -z "$SETTING_NOTES" ] || printf '%s\n' "$SETTING_NOTES" | sed 's/^/myspec-config: /' >&2
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      # shellcheck disable=SC2254 # the entry is a glob on purpose
      case "$branch" in $pat) PROTECTED_HEAD="branch $branch"; break ;; esac
    done < <(printf '%s' "$SETTING" | jq -r 'if type == "array" then .[] | strings else empty end' 2>/dev/null || true)
  fi
  [ -n "$PROTECTED_HEAD" ]
}

# pretool_deny <reason> -> prints the PreToolUse deny and exits 0. Only the
# hookSpecificOutput form: the top-level decision/reason pair is the
# deprecated PreToolUse spelling, and the host floor (README) reads this one.
# An allowed call prints nothing: {"decision": "approve"} is the deprecated
# spelling of permissionDecision "allow", which would skip the user's
# permission prompt.
pretool_deny() {
  local reason
  reason=$(printf '%s' "$1" | jq -Rs .)
  printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": %s}}\n' "$reason"
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
# through the one settings reader beside this file: lib/myspec-config.sh,
# which needs jq, or its Node twin lib/myspec-config.mjs when jq is absent,
# so a lib script that otherwise runs without jq keeps doing so. Fails
# without a reader that can run, or when it fails.
read_setting() {
  local err rc=0 reader
  SETTING="" SETTING_NOTES=""
  if command -v jq >/dev/null 2>&1 && [ -f "$HOOK_LIB/myspec-config.sh" ]; then
    reader=(bash "$HOOK_LIB/myspec-config.sh")
  elif command -v node >/dev/null 2>&1 && [ -f "$HOOK_LIB/myspec-config.mjs" ]; then
    reader=(node "$HOOK_LIB/myspec-config.mjs")
  else
    SETTING_NOTES="reading a setting needs jq with $HOOK_LIB/myspec-config.sh, or node with $HOOK_LIB/myspec-config.mjs"
    return 1
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/.myspec-cfg.XXXXXX") || return 1
  SETTING=$("${reader[@]}" get "$1" --root "$2" 2>"$err") || rc=$?
  SETTING_NOTES=$(sed 's/^myspec-config: //' "$err")
  rm -f "$err"
  return "$rc"
}

# json_string <json> -> the string a JSON string value holds; nothing for
# any other value. jq when present; without it sed, which undoes only \" and
# \\ (enough for a path setting read through the Node reader).
json_string() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r 'if type == "string" then . else empty end' 2>/dev/null || printf ''
  else
    printf '%s\n' "$1" | sed -n 's/^"\(.*\)"$/\1/p' | sed 's/\\"/"/g; s/\\\\/\\/g'
  fi
}

# lock_paths_for <dir> <pattern>... -> the <dir>-relative regular files the
# lockfile patterns match there, one per line, in pattern order. A pattern
# is a shell glob: * and ? stay within one directory, [...] is a class. The
# one matcher for worktree-provision.sh, which records what a pattern
# matched, and the Stop hook's provision check (stop-gate/provision.sh),
# which compares it, so the two cannot drift on what a pattern matches.
lock_paths_for() {
  local dir="$1" pat f IFS=''
  shift
  for pat in "$@"; do
    for f in "$dir"/$pat; do
      [ -f "$f" ] && printf '%s\n' "${f#"$dir"/}"
    done
  done
  return 0
}
