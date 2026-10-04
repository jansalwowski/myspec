#!/usr/bin/env bash
# guard-worktree-context.sh
# PreToolUse hook (Bash matcher) — the Bash half of work isolation. Two gates,
# both scoped to the MAIN checkout (a linked worktree or a submodule is never
# guarded; checkout_facts in lib/hook-core.sh tells them apart):
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
#      are blocked as well: builds, installs, e2e runs, `lint:fix`,
#      `docker compose exec`, `git push` and `git worktree prune` (not its
#      `--dry-run`) silently target the wrong tree and are noticed
#      only when the output looks wrong. The list is the setting
#      `isolation.blockInMain` (anchored extended regexes over a command
#      segment): a default in the settings schema, which a project extends
#      there and trims with `isolation.ignoreBlockInMain`.
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
# `git -C <dir>` / `--git-dir`, and a build tool's own directory flag
# (`make -C`, `mvn -f <pom>`, `gradle -p`). Launchers are looked through — `env`, `command`,
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
# Output contract: a block prints the PreToolUse deny form (pretool_deny in
# lib/hook-core.sh). An allowed command prints NOTHING and exits 0.

set -euo pipefail

MAX_DEPTH=3        # nested `bash -c` / `eval` payloads scanned

# The hook and its libs ship as a set: hooks/ + lib/ in the plugin,
# .claude/hooks/ + .claude/lib/ in a project. A missing jq or lib fails open
# rather than block on an infra error.
command -v jq >/dev/null 2>&1 || exit 0
HOOK_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/hook-core.sh"
[ -f "$HOOK_CORE" ] || HOOK_CORE="${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"
if [ ! -f "$HOOK_CORE" ] || [ ! -f "$(dirname "$HOOK_CORE")/command-scan.sh" ] \
    || [ ! -f "$(dirname "$HOOK_CORE")/session-event.sh" ]; then
  exit 0
fi
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/session-event.sh
. "$HOOK_LIB/session-event.sh"
# shellcheck source=lib/command-scan.sh
. "$HOOK_LIB/command-scan.sh"

payload_parse "$(cat)" COMMAND=.tool_input.command SESSION_ID=.session_id \
  CWDS="$HOOK_CWDS"
[ -n "$COMMAND" ] || exit 0

# The directory the command starts in: the payload's cwd, else the hook's own.
START_DIR=$(first_dir "$CWDS") || START_DIR="$PWD"

ALLOW_BRANCH_OPS=0
# Here-strings, not `printf | grep -q`, throughout: grep -q exits on the
# first match, a long input then kills printf with SIGPIPE, and under
# pipefail the match reads as a miss.
if grep -qE '(^|[[:space:]])MYSPEC_ALLOW_BRANCH_OPS=1[[:space:]]' <<< "$COMMAND"; then
  ALLOW_BRANCH_OPS=1
fi
ALLOW_MAIN_CHECKOUT=0
if grep -qE '(^|[[:space:]])MYSPEC_ALLOW_MAIN_CHECKOUT=1[[:space:]]' <<< "$COMMAND"; then
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

# Commands whose result depends on which tree they run in, or which write to
# it, are data: `isolation.blockInMain`, read through the settings reader. Its
# default (lib/myspec-config.schema.json) covers builds, installs, e2e runs,
# lint:fix, `docker compose exec`, `git push` and `git worktree prune` across
# the common stacks; a project adds anchored EREs there and removes default
# entries, by their exact text, with `isolation.ignoreBlockInMain`.

# A read-only form the default patterns would otherwise trip.
# `git worktree prune -n` / `--dry-run` only reports (issue #223).
HEAVY_CARVE_OUT='^git[[:space:]]+worktree[[:space:]]+prune([[:space:]]+[^[:space:]]+)*[[:space:]]+(-v*nv*|--dry-run)([[:space:]]|$)'

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

# resolve_file_dir <base> <encoded word> -> the directory a build-file
# argument names: the word itself when it is a directory, else its parent.
resolve_file_dir() {
  local word
  resolve_dir "$1" "$2" && return 0
  word=$(decode_word "$2")
  case "$word" in */*) ;; *) word=. ;; esac
  resolve_dir "$1" "${word%/*}"
}

# build_dir <dir> <tool> <sanitized word>... -- <encoded word>... -> sets
# BUILD_DIR to where a make, maven or gradle run builds: <dir> moved by
# `make -C`/`--directory`, `mvn -f`/`--file` (a pom's directory) or
# `gradle -p`/`--project-dir`, wherever among the arguments it appears. Sets
# BUILD_DRY=1 for a make run that only reports (-n, -q and their long forms).
# An unresolvable value leaves the directory unchanged.
build_dir() {
  local dir="$1" tool="$2" i n w v flag rest
  local -a sw=() rw=()
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do sw+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  rw=("$@")
  n=${#sw[@]}
  BUILD_DIR="$dir" BUILD_DRY=0
  for ((i = 0; i < n; i++)); do
    w="${sw[i]}" v="" flag=""
    case "$tool:$w" in
      make:-C|make:--directory|mvn:-f|mvn:--file|gradle:-p|gradle:--project-dir)
        flag="$w" v="${rw[i+1]:-}"
        i=$((i + 1)) ;;
      make:--directory=*|mvn:--file=*|gradle:--project-dir=*)
        flag="${w%%=*}" v="${rw[i]#*=}" ;;
      make:-C?*|mvn:-f?*|gradle:-p?*)
        flag="${w:0:2}" v="${rw[i]:2}" ;;
      make:--just-print|make:--dry-run|make:--recon|make:--question)
        BUILD_DRY=1 ;;
      make:-[A-Za-z]*)
        # A short-option cluster: n or q before a letter that takes a value.
        rest="${w#-}"
        while [ -n "$rest" ]; do
          case "${rest:0:1}" in
            n|q) BUILD_DRY=1 ;;
            f|I|o|W|l|j|E) break ;;
          esac
          rest="${rest:1}"
        done ;;
    esac
    [ -n "$flag" ] || continue
    case "$flag" in
      -f|--file) v=$(resolve_file_dir "$BUILD_DIR" "$v") || continue ;;
      *) v=$(resolve_dir "$BUILD_DIR" "$v") || continue ;;
    esac
    BUILD_DIR="$v"
  done
}

# classify <dir> <git-dir or empty> -> sets CLS_ROOT to the main checkout the
# segment would act on, or empty when it acts on a linked worktree, a
# submodule, or no repository at all (checkout_facts). One-entry cache: a
# command almost always runs in one place.
CLS_KEY=""
CLS_ROOT=""
classify() {
  local key="$1|$2" abs
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
  checkout_facts "$1" || return 0
  [ "$CF_LINKED" = 0 ] && [ "$CF_SUBMODULE" = 0 ] && CLS_ROOT="$CF_ROOT"
  return 0
}

# procedure_doc <main root> -> where init/update install the isolation
# procedure (manifest `files` entry work-isolation.md, under the aiDir). Block
# messages cite it so the full procedure is read only when a block fires.
procedure_doc() {
  printf '%s/work-isolation.md' "$(ai_dir "$1")"
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
      printf 'BLOCKED: git branch -f rewrites a branch ref on the main checkout. Do the work in a linked worktree (procedure: %s). Blocked: %s' "$(procedure_doc "$root")" "${segment:0:200}"
    fi
    return 0
  fi

  if [ -n "$unknown" ]; then
    printf 'BLOCKED: git branch delete combined with an unrecognised flag (%s) on the main checkout. Run the delete on its own. Blocked: %s' "$unknown" "${segment:0:200}"
    return 0
  fi

  # Remote-tracking refs are never checked out in any working tree.
  [ "$is_remote" = 1 ] && return 0

  checked_out=$(git -C "$root" worktree list --porcelain 2>/dev/null \
    | awk '/^branch refs\/heads\//{sub(/^branch refs\/heads\//, ""); print}')

  for word in ${names[@]+"${names[@]}"}; do
    # Q is the scanner placeholder for a quoted span.
    if [ "$word" = Q ] || [ "$word" = - ] || [[ "$word" == *[\$@*?[]* ]]; then
      printf 'BLOCKED: git branch delete names a branch the guard cannot resolve (%s): a quoted name, variable, glob or @{-N}. Write the branch name literally so the guard can confirm no worktree has it checked out. Blocked: %s' "$word" "${segment:0:200}"
      return 0
    fi
    # -i: on a case-insensitive filesystem (macOS default) git resolves
    # WT-A to the ref file of wt-a, so a case-variant name deletes it too.
    if grep -qixF -- "$word" <<< "$checked_out"; then
      # shellcheck disable=SC2016 # literal backticks: the message quotes a command
      printf 'BLOCKED: branch %s is checked out in a worktree (see `git worktree list`), and deleting it would leave that working tree on a missing branch. Remove the worktree first, or clean up with .claude/lib/branch-cleanup.sh. Blocked: %s' "$word" "${segment:0:200}"
      return 0
    fi
  done
}

# --- gate B: the session's isolation mode --------------------------------------

# session_mode <main root> -> sets ISO_MODE and ISO_PATH for that checkout:
# the session's decision, which a subagent shares with its parent through the
# session id (session_isolation in lib/session-event.sh).
MODE_ROOT=""
session_mode() {
  [ "$1" = "$MODE_ROOT" ] && return 0
  MODE_ROOT="$1"
  session_isolation "$1" "$SESSION_ID"
}

block_heavy() {  # block_heavy <main root> <segment>
  local root="$1" target="$ISO_PATH" candidates where
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

  pretool_deny "BLOCKED: this session chose WORKTREE isolation, but this command is about to run in the main checkout.

$where

Blocked: ${2:0:160}

If the main checkout really is the right place (refreshing the symlinked node_modules, for example), re-run it prefixed with MYSPEC_ALLOW_MAIN_CHECKOUT=1.

Full procedure: $(procedure_doc "$root")"
}

# heavy_patterns <main root> -> sets HEAVY to that checkout's
# isolation.blockInMain minus isolation.ignoreBlockInMain, read once per root.
# The reader's notes go to stderr. When the reader fails (a partial install)
# there is no list: the first such command of the session is denied with the
# reader's error, recorded as a `notice` event, and later ones pass, as the
# Stop gate blocks once on a missing lib rather than guess.
HEAVY_ROOT=""
HEAVY=()
heavy_patterns() {
  local p
  [ "$1" != "$HEAVY_ROOT" ] || return 0
  HEAVY_ROOT="$1"
  HEAVY=()
  if ! read_setting isolation "$1"; then
    [ -z "$SETTING_NOTES" ] || printf 'guard-worktree-context: %s\n' "$SETTING_NOTES" >&2
    # shellcheck disable=SC2016 # a jq program: $ev is a jq variable
    if [ -n "$SESSION_ID" ] && [ "$(session_query "$1" "$SESSION_ID" \
        '[$ev[] | select(.t == "notice" and .what == "guard-settings")] | length')" = 0 ] \
        && session_append "$1" "$SESSION_ID" '{"t":"notice","what":"guard-settings"}'; then
      pretool_deny "myspec lib missing, run /myspec:update. The settings reader (lib/myspec-config.sh) could not read isolation.blockInMain, so this session's worktree guard cannot tell which commands to keep out of the main checkout: ${SETTING_NOTES:-no reason given}. This command is denied once; later ones are not checked until the install is repaired."
    fi
    return 0
  fi
  [ -z "$SETTING_NOTES" ] || printf 'guard-worktree-context: %s\n' "$SETTING_NOTES" >&2
  while IFS= read -r p; do
    [ -n "$p" ] && HEAVY+=("$p")
  done < <(jq -r '(.ignoreBlockInMain // [] | if type == "array" then . else [] end) as $skip
    | .blockInMain // [] | if type == "array" then .[] else empty end
    | select(type == "string") | select(. as $p | $skip | index([$p]) | not)' <<< "$SETTING" 2>/dev/null)
}

matches_any() {  # matches_any <segment> <pattern>...
  local segment="$1" pattern
  shift
  for pattern in "$@"; do
    if grep -qE -- "$pattern" <<< "$segment"; then
      return 0
    fi
  done
  return 1
}

# check_segment <normalized segment> <dir> <git-dir> — applies both gates.
check_segment() {
  local segment="$1" dir="$2" gitdir="$3" verdict

  if [ "$ALLOW_BRANCH_OPS" = 0 ]; then
    if matches_any "$segment" "${BRANCH_PATTERNS[@]}" \
        && ! grep -qE -- "$BRANCH_CARVE_OUT" <<< "$segment"; then
      classify "$dir" "$gitdir"
      if [ -n "$CLS_ROOT" ]; then
        pretool_deny "BLOCKED: Branch-mutating git commands are not allowed on the main checkout. Do the work in a linked worktree (procedure: $(procedure_doc "$CLS_ROOT")) or pass isolation: \"worktree\" in your Agent tool call. If you need to restore a file, use \`git restore <file>\` not \`git checkout\`. Blocked: ${segment:0:200}"
      fi
    fi

    if [[ "$segment" =~ ^git[[:space:]]+branch[[:space:]] ]]; then
      classify "$dir" "$gitdir"
      if [ -n "$CLS_ROOT" ]; then
        verdict=$(branch_verdict "$segment" "$CLS_ROOT")
        [ -z "$verdict" ] || pretool_deny "$verdict"
      fi
    fi
  fi

  [ "$ALLOW_MAIN_CHECKOUT" = 0 ] || return 0
  [ -n "$segment" ] || return 0

  classify "$dir" "$gitdir"
  [ -n "$CLS_ROOT" ] || return 0
  session_mode "$CLS_ROOT"
  [ "$ISO_MODE" = "worktree" ] || return 0

  heavy_patterns "$CLS_ROOT"
  if [ "${#HEAVY[@]}" -gt 0 ] && matches_any "$segment" "${HEAVY[@]}" \
      && ! grep -qE -- "$HEAVY_CARVE_OUT" <<< "$segment"; then
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
      make|mvn|mvnw|gradle|gradlew)
        case "$c" in mvnw) c=mvn ;; gradlew) c=gradle ;; esac
        build_dir "$dir" "$c" "${sw[@]:j+1}" -- "${rw[@]:j+1}"
        [ "$BUILD_DRY" = 0 ] || continue
        check_segment "$(join_words "$j" "${sw[@]}")" "$BUILD_DIR" ""
        ;;
      *)
        check_segment "$(join_words "$j" "${sw[@]}")" "$dir" ""
        ;;
    esac
  done
}

walk "$COMMAND" "$START_DIR" 0
exit 0
