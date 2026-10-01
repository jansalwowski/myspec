#!/usr/bin/env bash
# guard-worktree-context.sh
# PreToolUse hook (Bash matcher) — the Bash half of work isolation. Two gates,
# both scoped to the MAIN checkout (a linked worktree is never guarded:
# worktrees have .git as a FILE, the main checkout as a DIRECTORY):
#
#   A. Branch mutations are blocked always. `git checkout`, `switch`, `merge`,
#      `rebase`, `pull`, and `branch -m/-c/-f` on the main checkout are how a
#      parallel agent knocks the user's working tree out from under them.
#      (`git checkout -- <file>` is blocked too; use `git restore <file>`.)
#      `rebase`/`merge` with only `--continue`, `--abort` or `--skip` are
#      allowed: they can only advance or unwind an operation the user already
#      started, and blocking them strands the checkout mid-rebase.
#      `branch -d/-D` is blocked only when a named branch is checked out in
#      some worktree (`git worktree list --porcelain`): deleting one no tree
#      has checked out, or a remote-tracking ref (`-dr`), disturbs no working
#      tree. A name the hook cannot resolve (quoted, `$VAR`, `@{-1}`) blocks.
#      Blocking those deletes unconditionally only taught agents to reach for
#      the bypass (issue #126).
#   B. When the session has chosen WORKTREE isolation, tree-specific commands
#      are blocked as well: builds, installs, e2e runs, `lint:fix`, `git push`
#      and `git worktree prune` silently target the wrong tree and are noticed
#      only when the output looks wrong. `.myspec.json` `isolation.blockInMain`
#      adds project patterns (anchored extended regexes over a command segment).
#
# Until 2.0 gate A was its own hook, guard-git-branch.sh; folding the two keeps
# one root resolver, one scanner, one worktree lookup, one block message.
#
# MATCHING: the blocklists are applied at COMMAND POSITION only, over input
# whose quoted spans and heredoc bodies have been blanked (lib/command-scan.sh).
# A plain substring match fires on the verb wherever it appears — inside a
# commit message, a PR body, doc prose — and blocks a command that mutates
# nothing. Those false positives were the branch guard's dominant failure mode.
# The fixture, hooks/tests/guard-worktree-context.test.sh, lives in the myspec
# plugin repo and is not copied into adopting projects.
#
# WHERE a segment runs is decided per segment, not once per command: the
# payload's cwd, then every `cd <dir>` before it (scoped to its subshell), then
# `git -C <dir>` / `--git-dir`. Launchers are looked through — `env`, `command`,
# `sudo`, `exec`, `nohup`, `time`, `nice`, git's global options (`-c k=v`,
# `--no-pager`, ...) — and `bash -c '...'` / `eval` payloads are scanned as
# commands. So `cd <worktree> && git checkout x` (the sanctioned path both block
# messages point at) is allowed, while `ls <worktree>; git checkout x` from the
# main checkout, or `cd <main> && git checkout x` from a worktree, is not.
# A `cd` target the hook cannot resolve (a variable, a path that does not exist
# yet) leaves the directory unchanged.
#
# Escape hatches:
#   MYSPEC_ALLOW_BRANCH_OPS=1    gate A. Deliberately NOT mentioned in the block
#                               reason: a hook cannot verify user confirmation,
#                               so advertising it would let any blocked agent
#                               wave itself through. Only flows whose skill
#                               documents it (feature-complete's merge) know it.
#   MYSPEC_ALLOW_MAIN_CHECKOUT=1 gate B. Advertised: refreshing the symlinked
#                               node_modules in the main checkout is a legitimate
#                               mid-worktree action, so this gate is a speed bump.
#
# Sanctioned branch cleanup needs no bypass: lib/branch-cleanup.sh makes its
# git calls in a child process this hook never sees.
#
# Output contract: a block prints
#   {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#     "permissionDecision": "deny", "permissionDecisionReason": "..."},
#    "decision": "block", "reason": "..."}
# (the current PreToolUse form plus the legacy fields older hosts read). An
# allowed command prints NOTHING and exits 0. It must never print
# {"decision": "approve"}: for PreToolUse that is the deprecated spelling of
# permissionDecision "allow", which skips the user's permission prompt — a
# guard that only means "I have no objection" would auto-approve every command.

set -euo pipefail

OWN_TTL=28800      # 8h — a session's own isolation decision stays valid this long
INHERIT_TTL=14400  # 4h — window in which a subagent inherits a parent's decision
MAX_DEPTH=3        # nested `bash -c` / `eval` payloads scanned

approve() {
  exit 0
}

block() {
  local reason
  reason=$(printf '%s' "$1" | jq -Rs .)
  printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": %s}, "decision": "block", "reason": %s}\n' "$reason" "$reason"
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  approve
fi

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

[ -n "$COMMAND" ] || approve

# The directory the command starts in: the first cwd-like payload field that
# exists, else the hook's own cwd.
START_DIR=""
while IFS= read -r candidate; do
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    START_DIR="$candidate"
    break
  fi
done <<JSON
$(printf '%s' "$INPUT" | jq -r '
  [
    .cwd,
    .workdir,
    .workspace.cwd,
    .session.cwd,
    .tool_input.cwd,
    .tool_input.workdir
  ] | map(select(type == "string" and . != "")) | .[]
' 2>/dev/null)
JSON
[ -n "$START_DIR" ] || START_DIR="$PWD"

# The hook + lib ship as a pair:
#   myspec repo:      hooks/guard-worktree-context.sh + lib/command-scan.sh
#   adopting project: .claude/hooks/...              + .claude/lib/...
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
START_ROOT=$(git -C "$START_DIR" rev-parse --show-toplevel 2>/dev/null || printf '')
LIB=""
for cand in \
  "$SCRIPT_DIR/../lib/command-scan.sh" \
  ${START_ROOT:+"$START_ROOT/.claude/lib/command-scan.sh"} \
  ${START_ROOT:+"$START_ROOT/lib/command-scan.sh"}; do
  if [ -f "$cand" ]; then
    LIB="$cand"
    break
  fi
done

# Scanner missing — fail open rather than block on infra error, matching how
# the hook already treats a missing jq.
[ -n "$LIB" ] || approve

# shellcheck source=/dev/null
. "$LIB"

ALLOW_BRANCH_OPS=0
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])MYSPEC_ALLOW_BRANCH_OPS=1[[:space:]]'; then
  ALLOW_BRANCH_OPS=1
fi
ALLOW_MAIN_CHECKOUT=0
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]])MYSPEC_ALLOW_MAIN_CHECKOUT=1[[:space:]]'; then
  ALLOW_MAIN_CHECKOUT=1
fi

BRANCH_PATTERNS=(
  '^git[[:space:]]+checkout([[:space:]]|$)'
  '^git[[:space:]]+switch([[:space:]]|$)'
  '^git[[:space:]]+merge([[:space:]]|$)'
  '^git[[:space:]]+rebase([[:space:]]|$)'
  '^git[[:space:]]+pull([[:space:]]|$)'
  '^git[[:space:]]+branch[[:space:]]+(-[mMcC]|--move|--copy|--set-upstream)'
)

# Resuming or unwinding an operation already in progress.
BRANCH_CARVE_OUT='^git[[:space:]]+(rebase|merge)[[:space:]]+--(continue|abort|skip)[[:space:]]*$'

# Commands whose result depends on which tree they run in, or which write to it.
HEAVY_PATTERNS=(
  '^(yarn|npm|pnpm|bun)[[:space:]]+(run[[:space:]]+)?build([[:space:]]|$)'
  '^(yarn|pnpm|bun)[[:space:]]+(install|add|upgrade|remove|dedupe|up)([[:space:]]|$)'
  '^npm[[:space:]]+(install|ci|i|uninstall|update)([[:space:]]|$)'
  '^(yarn|npm|pnpm|bun)[[:space:]]+(run[[:space:]]+)?test:e2e'
  '^(yarn|npm|pnpm|bun)[[:space:]]+(run[[:space:]]+)?lint:fix([[:space:]]|$)'
  '^(pip|pip3|poetry|composer|bundle)[[:space:]]+install([[:space:]]|$)'
  '^(cargo|go)[[:space:]]+build([[:space:]]|$)'
  '^git[[:space:]]+push([[:space:]]|$)'
  '^git[[:space:]]+worktree[[:space:]]+prune([[:space:]]|$)'
)

# --- where does a segment run? -------------------------------------------------

# resolve_dir <base> <encoded word> -> physical directory, or failure when the
# word is not a literal path that exists now.
resolve_dir() {
  local base="$1" word
  word=$(decode_word "$2")
  case "$word" in
    '') word="${HOME:-}" ;;
    -|*'$'*|*'`'*|*'*'*|*'?'*) return 1 ;;
    # \~ matches a literal ~ in the command text, expanded here by hand.
    \~) word="${HOME:-}" ;;
    \~/*) word="${HOME:-}/${word#\~/}" ;;
    /*) ;;
    *) word="$base/$word" ;;
  esac
  [ -n "$word" ] || return 1
  (cd "$word" 2>/dev/null && pwd -P)
}

# classify <dir> <git-dir or empty> -> sets CLS_ROOT to the main checkout the
# segment would act on, or empty when it acts on a linked worktree, a
# submodule, or no repository at all. One-entry cache: a command almost always
# runs in one place.
CLS_KEY=""
CLS_ROOT=""
classify() {
  local key="$1|$2" abs top
  [ "$key" = "$CLS_KEY" ] && return 0
  CLS_KEY="$key"
  CLS_ROOT=""
  if [ -n "$2" ]; then
    # HEAD lives in the git dir, so it alone decides which checkout moves.
    abs=$(cd "$1" 2>/dev/null && git --git-dir="$2" rev-parse --absolute-git-dir 2>/dev/null) || return 0
    case "$abs" in
      */worktrees/*) return 0 ;;
      */.git) CLS_ROOT="${abs%/.git}" ;;
    esac
    return 0
  fi
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -f "$top/.git" ] && return 0
  CLS_ROOT="$top"
}

# --- gate A: `git branch` delete / force ---------------------------------------

# branch_verdict <normalized segment> <main root> -> block reason, or nothing.
# Short flags may be clustered (-dr, -Df); any flag outside the known set
# blocks, so an unrecognised combination fails closed.
branch_verdict() {
  local segment="$1" root="$2" checked_out word flags ch is_delete is_remote is_force unknown end_opts
  local -a words names

  [[ "$segment" =~ ^git[[:space:]]+branch[[:space:]]+(.*)$ ]] || return 0
  read -r -a words <<< "${BASH_REMATCH[1]}"

  is_delete=0 is_remote=0 is_force=0 unknown="" end_opts=0
  names=()
  for word in ${words[@]+"${words[@]}"}; do
    if [ "$end_opts" = 1 ]; then names+=("$word"); continue; fi
    case "$word" in
      --) end_opts=1 ;;
      --delete) is_delete=1 ;;
      --remotes) is_remote=1 ;;
      --force) is_force=1 ;;
      --quiet) ;;
      --*) unknown="$word" ;;
      -?*)
        flags="${word#-}"
        while [ -n "$flags" ]; do
          ch="${flags:0:1}"
          flags="${flags:1}"
          case "$ch" in
            d|D) is_delete=1 ;;
            r) is_remote=1 ;;
            f) is_force=1 ;;
            q) ;;
            *) unknown="$word" ;;
          esac
        done
        ;;
      *) names+=("$word") ;;
    esac
  done

  if [ "$is_delete" != 1 ]; then
    # `branch -f <name> [<start>]` moves an existing branch ref.
    if [ "$is_force" = 1 ]; then
      printf 'BLOCKED: git branch -f rewrites a branch ref on the main checkout. Do the work in a linked worktree (see .claude/rules/work-isolation.md). Blocked: %s' "$(printf '%s' "$segment" | head -c 200)"
    fi
    return 0
  fi

  if [ -n "$unknown" ]; then
    printf 'BLOCKED: git branch delete combined with an unrecognised flag (%s) on the main checkout. Run the delete on its own. Blocked: %s' "$unknown" "$(printf '%s' "$segment" | head -c 200)"
    return 0
  fi

  # Remote-tracking refs are never checked out in any working tree.
  [ "$is_remote" = 1 ] && return 0

  checked_out=$(git -C "$root" worktree list --porcelain 2>/dev/null \
    | awk '/^branch refs\/heads\//{sub(/^branch refs\/heads\//, ""); print}')

  for word in ${names[@]+"${names[@]}"}; do
    # Q is the scanner placeholder for a quoted span.
    if [ "$word" = Q ] || [ "$word" = - ] || [[ "$word" == *[\$@*?[]* ]]; then
      printf 'BLOCKED: git branch delete names a branch the guard cannot resolve (%s): a quoted name, variable, glob or @{-N}. Write the branch name literally so the guard can confirm no worktree has it checked out. Blocked: %s' "$word" "$(printf '%s' "$segment" | head -c 200)"
      return 0
    fi
    # -i: on a case-insensitive filesystem (macOS default) git resolves
    # WT-A to the ref file of wt-a, so a case-variant name deletes it too.
    if printf '%s\n' "$checked_out" | grep -qixF -- "$word"; then
      # shellcheck disable=SC2016 # literal backticks: the message quotes a command
      printf 'BLOCKED: branch %s is checked out in a worktree (see `git worktree list`), and deleting it would leave that working tree on a missing branch. Remove the worktree first, or clean up with .claude/lib/branch-cleanup.sh. Blocked: %s' "$word" "$(printf '%s' "$segment" | head -c 200)"
      return 0
    fi
  done
}

# --- gate B: the session's isolation mode --------------------------------------

MODE_ROOT=""
MODE=""
MARKER_PATH=""

# session_mode <main root> -> sets MODE and MARKER_PATH for that checkout.
session_mode() {
  local state_dir="$1/.claude/state/isolation" now newest marker_mode marker_path marker_age
  [ "$1" = "$MODE_ROOT" ] && return 0
  MODE_ROOT="$1"
  MODE=""
  MARKER_PATH=""
  [ -d "$state_dir" ] || return 0
  now=$(date +%s)

  read_marker() {
    marker_mode=$(jq -r '.mode // empty' "$1" 2>/dev/null || printf '')
    marker_path=$(jq -r '.worktree_path // empty' "$1" 2>/dev/null || printf '')
    marker_age=$(( now - $(jq -r '.decided_at // 0' "$1" 2>/dev/null || printf 0) ))
  }

  # 1. This session's own decision.
  if [ -n "$SESSION_ID" ] && [ -f "$state_dir/${SESSION_ID}.json" ]; then
    read_marker "$state_dir/${SESSION_ID}.json"
    if [ "$marker_age" -lt "$OWN_TTL" ]; then
      MODE="$marker_mode"
      MARKER_PATH="$marker_path"
      return 0
    fi
  fi

  # 2. Inherited decision — subagents cannot prompt, so they follow the newest
  #    recent marker.
  # shellcheck disable=SC2012 # ls -t is the portable mtime sort; the names are generated session ids
  newest=$(ls -t "$state_dir"/*.json 2>/dev/null | head -1 || printf '')
  if [ -n "$newest" ] && [ -f "$newest" ]; then
    read_marker "$newest"
    if [ "$marker_age" -lt "$INHERIT_TTL" ]; then
      MODE="$marker_mode"
      MARKER_PATH="$marker_path"
    fi
  fi
}

block_heavy() {  # block_heavy <main root> <segment>
  local root="$1" target="$MARKER_PATH" candidates where
  # Name the worktree if we can: recorded path first, then a lone linked worktree.
  if [ -z "$target" ]; then
    candidates=$(git -C "$root" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print $2}' | grep -v "^${root}$" || printf '')
    if [ "$(printf '%s\n' "$candidates" | grep -c .)" = "1" ]; then
      target="$candidates"
    fi
  fi

  if [ -n "$target" ]; then
    where="Run it in the session's worktree instead:
  cd $target"
  else
    where="Run it in the session's worktree instead (see \`git worktree list\`); no worktree path was recorded for this session."
  fi

  block "BLOCKED: this session chose WORKTREE isolation, but this command is about to run in the main checkout.

$where

Blocked: $(printf '%s' "$2" | head -c 160)

If the main checkout really is the right place (refreshing the symlinked node_modules, for example), re-run it prefixed with MYSPEC_ALLOW_MAIN_CHECKOUT=1."
}

matches_any() {  # matches_any <segment> <pattern>...
  local segment="$1" pattern
  shift
  for pattern in "$@"; do
    if printf '%s' "$segment" | grep -qE -- "$pattern"; then
      return 0
    fi
  done
  return 1
}

# check_segment <normalized segment> <dir> <git-dir> — applies both gates.
check_segment() {
  local segment="$1" dir="$2" gitdir="$3" verdict extra
  local -a patterns

  if [ "$ALLOW_BRANCH_OPS" = 0 ]; then
    if matches_any "$segment" "${BRANCH_PATTERNS[@]}" \
        && ! printf '%s' "$segment" | grep -qE -- "$BRANCH_CARVE_OUT"; then
      classify "$dir" "$gitdir"
      if [ -n "$CLS_ROOT" ]; then
        block "BLOCKED: Branch-mutating git commands are not allowed on the main checkout. Do the work in a linked worktree (see .claude/rules/work-isolation.md) or pass isolation: \"worktree\" in your Agent tool call. If you need to restore a file, use \`git restore <file>\` not \`git checkout\`. Blocked: $(printf '%s' "$segment" | head -c 200)"
      fi
    fi

    if [[ "$segment" =~ ^git[[:space:]]+branch[[:space:]] ]]; then
      classify "$dir" "$gitdir"
      if [ -n "$CLS_ROOT" ]; then
        verdict=$(branch_verdict "$segment" "$CLS_ROOT")
        [ -z "$verdict" ] || block "$verdict"
      fi
    fi
  fi

  [ "$ALLOW_MAIN_CHECKOUT" = 0 ] || return 0
  [ -n "$segment" ] || return 0

  classify "$dir" "$gitdir"
  [ -n "$CLS_ROOT" ] || return 0
  session_mode "$CLS_ROOT"
  [ "$MODE" = "worktree" ] || return 0

  patterns=("${HEAVY_PATTERNS[@]}")
  if [ -f "$CLS_ROOT/.myspec.json" ]; then
    while IFS= read -r extra; do
      [ -n "$extra" ] && patterns+=("$extra")
    done < <(jq -r '.isolation.blockInMain // [] | .[] | select(type == "string")' "$CLS_ROOT/.myspec.json" 2>/dev/null)
  fi

  if matches_any "$segment" "${patterns[@]}"; then
    block_heavy "$CLS_ROOT" "$segment"
  fi
}

# join_words <start> <word>... -> words from index <start> joined by spaces.
join_words() {
  local start="$1" out="" i=0 w
  shift
  for w in "$@"; do
    if [ "$i" -ge "$start" ]; then
      out="${out:+$out }$w"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# walk <command> <start dir> <depth> — checks every segment of <command>.
# Blocks (and exits) on the first offending segment; returns when clean.
walk() {
  local cmd="$1" dir="$2" depth="$3"
  local -a seps segs_s segs_r sw rw stack
  local line k n j c w sub gdir gitdir norm payload

  k=0
  while IFS= read -r line; do
    seps[k]="${line%%$'\t'*}"
    segs_s[k]="${line#*$'\t'}"
    k=$((k + 1))
  done < <(printf '%s' "$cmd" | sanitize_command | split_segments)
  n=$k
  k=0
  while IFS= read -r line; do
    segs_r[k]="${line#*$'\t'}"
    k=$((k + 1))
  done < <(printf '%s' "$cmd" | sanitize_command keep | split_segments)

  stack=()
  for ((k = 0; k < n; k++)); do
    case "${seps[k]}" in
      '(') stack+=("$dir") ;;
      ')')
        if [ "${#stack[@]}" -gt 0 ]; then
          dir="${stack[${#stack[@]}-1]}"
          unset "stack[${#stack[@]}-1]"
        fi
        ;;
    esac

    sw=()
    rw=()
    read -r -a sw <<< "${segs_s[k]}" || true
    read -r -a rw <<< "${segs_r[k]:-}" || true
    [ "${#sw[@]}" -gt 0 ] || continue
    # The two streams split identically by construction; if they ever do not,
    # arguments fall back to their blanked form (unresolvable, never guessed).
    [ "${#rw[@]}" = "${#sw[@]}" ] || rw=("${sw[@]}")

    # Launchers and prefixes that do not change which command runs.
    j=0
    while [ "$j" -lt "${#sw[@]}" ]; do
      w="${sw[j]}"
      case "$w" in
        then|do|else|if|elif|while|until|'!'|time|nohup|exec|builtin)
          j=$((j + 1)) ;;
        sudo|doas)
          j=$((j + 1))
          while [ "$j" -lt "${#sw[@]}" ] && [[ "${sw[j]}" == -* ]]; do j=$((j + 1)); done ;;
        env)
          j=$((j + 1))
          while [ "$j" -lt "${#sw[@]}" ]; do
            case "${sw[j]}" in
              -C|--chdir)
                if sub=$(resolve_dir "$dir" "${rw[j+1]:-}"); then dir="$sub"; fi
                j=$((j + 2)) ;;
              -u|--unset|-S|--split-string) j=$((j + 2)) ;;
              -*) j=$((j + 1)) ;;
              *) break ;;
            esac
          done ;;
        command)
          j=$((j + 1))
          # `command -v git` looks git up; it does not run it.
          case "${sw[j]:-}" in
            -v|-V) j="${#sw[@]}" ;;
            -p) j=$((j + 1)) ;;
          esac ;;
        nice)
          j=$((j + 1))
          case "${sw[j]:-}" in
            -n) j=$((j + 2)) ;;
            -*) j=$((j + 1)) ;;
          esac ;;
        *)
          if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            j=$((j + 1))
          else
            break
          fi ;;
      esac
    done
    [ "$j" -lt "${#sw[@]}" ] || continue

    c="${sw[j]##*/}"
    case "$c" in
      cd|pushd)
        j=$((j + 1))
        while [ "$j" -lt "${#sw[@]}" ] && [[ "${sw[j]}" == -?* ]]; do j=$((j + 1)); done
        if sub=$(resolve_dir "$dir" "${rw[j]:-}"); then dir="$sub"; fi
        continue ;;
      bash|sh|zsh|dash|ksh)
        j=$((j + 1))
        payload=""
        while [ "$j" -lt "${#sw[@]}" ] && [[ "${sw[j]}" == -* ]]; do
          case "${sw[j]}" in
            --*) ;;
            -*c*) payload=1 ;;
          esac
          j=$((j + 1))
        done
        if [ -n "$payload" ] && [ "$j" -lt "${#sw[@]}" ] && [ "$depth" -lt "$MAX_DEPTH" ]; then
          walk "$(decode_word "${rw[j]}")" "$dir" $((depth + 1))
        fi
        continue ;;
      eval)
        if [ "$depth" -lt "$MAX_DEPTH" ]; then
          walk "$(decode_word "$(join_words $((j + 1)) "${rw[@]}")")" "$dir" $((depth + 1))
        fi
        continue ;;
      git)
        gdir="$dir"
        gitdir=""
        j=$((j + 1))
        while [ "$j" -lt "${#sw[@]}" ]; do
          case "${sw[j]}" in
            -C)
              if sub=$(resolve_dir "$gdir" "${rw[j+1]:-}"); then gdir="$sub"; fi
              j=$((j + 2)) ;;
            -c|--namespace|--config-env|--work-tree|--attr-source)
              j=$((j + 2)) ;;
            --git-dir)
              gitdir=$(decode_word "${rw[j+1]:-}")
              j=$((j + 2)) ;;
            --git-dir=*)
              gitdir=$(decode_word "${rw[j]#--git-dir=}")
              j=$((j + 1)) ;;
            -*) j=$((j + 1)) ;;
            *) break ;;
          esac
        done
        norm="git $(join_words "$j" "${sw[@]}")"
        norm="${norm% }"
        check_segment "$norm" "$gdir" "$gitdir"
        ;;
      *)
        check_segment "$(join_words "$j" "${sw[@]}")" "$dir" ""
        ;;
    esac
  done
}

walk "$COMMAND" "$START_DIR" 0
approve
