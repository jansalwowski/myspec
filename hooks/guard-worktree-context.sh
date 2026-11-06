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
#   C. A Bash write is judged as the same write through the Write tool
#      (#348): each file the command names as written (redirects, `tee`,
#      `sed -i`, `mv`, `cp`, `rm`, `touch`, ...; lib/bash-write-targets.sh),
#      in the command and in its `bash -c` / `eval` payloads, goes through
#      require-isolation-decision.sh. So a session with no decision is asked
#      before writing source by redirect, or a doc on a protected branch, and
#      a worktree session cannot write the main checkout that way unless the
#      command carries MYSPEC_ALLOW_MAIN_CHECKOUT=1, gate B's escape. A file
#      the command does not name (an interpreter's write, a variable path) is
#      not seen before it lands; mark-code-changed.sh records it afterwards.
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
# A `cd` into a directory the command creates first (`mkdir -p d && cd d`)
# is followed too (cd_target_to in lib/hook-core.sh), and one `git worktree
# add` creates counts as a linked worktree; one the hook cannot resolve (a
# variable, a substitution, a missing path nothing before it creates) leaves
# the directory unchanged. A `git -C` into a created directory is followed
# under stricter rules (C_MADE).
#
# Escape hatches:
#   MYSPEC_ALLOW_BRANCH_OPS=1    gate A. Deliberately NOT mentioned in the block
#                               reason: a hook cannot verify user confirmation,
#                               so advertising it would let any blocked agent
#                               wave itself through. Only flows whose skill
#                               documents it (feature-complete's merge) know it.
#   MYSPEC_ALLOW_MAIN_CHECKOUT=1 gate B, and gate C in worktree mode. Advertised:
#                               refreshing the symlinked node_modules in the main
#                               checkout is a legitimate mid-worktree action, so
#                               this gate is a speed bump.
#
# Sanctioned branch cleanup needs no bypass: lib/branch-cleanup.sh makes its
# git calls in a child process this hook never sees.
#
# Output contract: a block prints the PreToolUse deny form (pretool_deny in
# lib/hook-core.sh). An allowed command prints NOTHING and exits 0.

set -euo pipefail

MAX_DEPTH=3        # nested `bash -c` / `eval` payloads scanned

# The hook runs from the plugin (hooks.json), which exports CLAUDE_PLUGIN_ROOT,
# and its libs are the plugin's lib/. A missing jq or lib fails open rather
# than block on an infra error.
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
# Gate C only; without it the gate is skipped, gates A and B still run.
if [ -f "$HOOK_LIB/bash-write-targets.sh" ]; then
  # shellcheck source=lib/bash-write-targets.sh
  . "$HOOK_LIB/bash-write-targets.sh"
fi

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
# `git worktree prune -n` / `--dry-run` only reports (issue #223). Applied to
# the schema's default entries only: a project entry that matches the dry run
# blocks it, as the project wrote it to.
HEAVY_CARVE_OUT='^git[[:space:]]+worktree[[:space:]]+prune([[:space:]]+[^[:space:]]+)*[[:space:]]+(-v*nv*|--dry-run)([[:space:]]|$)'

# --- where does a segment run? -------------------------------------------------

# resolve_dir <base> <encoded word> -> physical directory, or failure when the
# word is not a literal path that exists now.
resolve_dir() {
  local word
  decode_word_to word "$2"
  # `~` and `~/` are expanded by hand (cd_word_to in lib/hook-core.sh).
  cd_word_to word "$1" "$word" || return 1
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
        # A C there takes the rest of the cluster, else the next word, as
        # the directory (`make -kC <dir>`).
        rest="${w#-}"
        while [ -n "$rest" ]; do
          case "${rest:0:1}" in
            n|q) BUILD_DRY=1 ;;
            C)
              flag=-C
              if [ -n "${rest:1}" ]; then
                v="${rw[i]:$(( ${#w} - ${#rest} + 1 ))}"
              else
                v="${rw[i+1]:-}"
                i=$((i + 1))
              fi
              break ;;
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
  # A worktree `git worktree add` creates earlier in the command (cd_target_to)
  # is linked, wherever it sits.
  for abs in ${CD_NEW_WT[@]+"${CD_NEW_WT[@]}"} ${C_NEW_WT[@]+"${C_NEW_WT[@]}"}; do
    case "$1/" in "$abs/"*) [ -z "$2" ] && return 0 ;; esac
  done
  if [ -n "$2" ]; then
    # HEAD lives in the git dir, so it alone decides which checkout moves.
    # A `git -C` into a directory the command creates (#372) is read from
    # its longest existing prefix.
    abs=$(cd "$(existing_dir "$1")" 2>/dev/null && git --git-dir="$2" rev-parse --absolute-git-dir 2>/dev/null) || return 0
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

  checked_out=$(held_branches "$root")

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
      printf 'BLOCKED: branch %s is checked out in a worktree (see `git worktree list`), and deleting it would leave that working tree on a missing branch. Remove the worktree first: `git worktree remove <path>` as its own call, or chained with && before the delete, with the path written literally. Then delete the branch, or clean up with %s/branch-cleanup.sh. Blocked: %s' "$word" "$HOOK_LIB" "${segment:0:200}"
      return 0
    fi
  done
}

# A worktree that an earlier segment of the same `&&` chain removes is gone by
# the time a later `git branch -d/-D` runs: the delete only runs if the removal
# succeeded (#384). REMOVED_WT holds those worktrees' physical paths, one per
# line. walk keeps it across a segment only when the link in front of that
# segment is `&&` (a newline right after `&&` continues the line; the `&` of
# `2>&1` or `&>` is a redirect, not a link), and empties it at any other link
# (`;`, `||`, `|`, `&`, newline, subshell, group or substitution boundary).
# A removal is recorded only when it cannot be skipped or have its failure
# masked: no `|` or `||` link in front of it, no `!`, a literal path (no
# quote, variable, glob, or backslash in the removal text, since the scanner
# blanks escapes and the word it sees is not the path git gets), and no flag
# but -f, --force and --. Any command between the removal and the delete that
# is not on a short read-only list (wt_chain_safe) empties the list, since it
# could check the branch out again: `git worktree add`, `checkout`, `switch`,
# a script.
REMOVED_WT=$'\n'
WT_LINK_OK=0   # walk, per segment: may a removal in this segment count?
WT_GLUE=0      # walk, per segment: 1 for the tail of a redirect (`1` of 2>&1)

# note_segment <normalized segment> <dir> -> updates REMOVED_WT for one
# segment: adds the worktree a `git worktree remove` removes, or empties the
# list for a command that might check a branch out.
note_segment() {
  local word path="" wt skip=0 end_opts=0
  local -a words
  [ "$WT_GLUE" = 0 ] || return 0
  if [[ "$1" =~ ^git[[:space:]]+worktree[[:space:]]+remove([[:space:]]+(.*))?$ ]]; then
    [ "$WT_LINK_OK" = 1 ] || return 0
    read -r -a words <<< "${BASH_REMATCH[2]}"
    for word in ${words[@]+"${words[@]}"}; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$word" in
        *Q*) return 0 ;;     # Q is the scanner placeholder for a quoted span
        '>'|'>>'|'<'|[0-9]'>'|[0-9]'>>'|[0-9]'<') skip=1; continue ;;
        '>'*|'<'*|[0-9]'>'*|[0-9]'<'*) continue ;;
      esac
      if [ "$end_opts" = 0 ]; then
        case "$word" in
          --) end_opts=1; continue ;;
          --force|-f|-ff) continue ;;
          -*) return 0 ;;
        esac
      fi
      [ -z "$path" ] || return 0
      path="$word"
    done
    [ -n "$path" ] || return 0
    wt=$(removed_worktree "$2" "$path") || return 0
    REMOVED_WT="$REMOVED_WT$wt"$'\n'
    return 0
  fi
  wt_chain_safe "$1" || REMOVED_WT=$'\n'
}

# removed_worktree <dir> <word> -> the physical path of the worktree that
# `git worktree remove <word>` run in <dir> removes. Like git: a word that is
# the trailing path components of exactly one listed worktree names it,
# otherwise the word is a path relative to <dir>.
removed_worktree() {
  local word="$2" line p hit="" count=0
  while [ "${word%/}" != "$word" ] && [ "$word" != / ]; do word="${word%/}"; done
  while IFS= read -r line; do
    case "$line" in 'worktree '*) ;; *) continue ;; esac
    p="${line#worktree }"
    if [ "$p" = "$word" ] || [ "${p%/"$word"}" != "$p" ]; then
      hit="$p" count=$((count + 1))
    fi
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
  if [ "$count" = 1 ]; then
    (cd "$hit" 2>/dev/null && pwd -P)
    return
  fi
  resolve_dir "$1" "$2"
}

# read_only_cmd <normalized segment> -> 0 for a few shell builtins and
# read-only git: what wt_chain_safe and c_read_only both let through.
read_only_cmd() {
  [[ "$1" =~ ^(echo|printf|true|:|pwd|ls|test)([[:space:]]|$) ]] && return 0
  [[ "$1" =~ ^git[[:space:]]+(fetch|status|log|show|diff|rev-parse|ls-remote|for-each-ref|worktree[[:space:]]+list)([[:space:]]|$) ]]
}

# wt_chain_safe <normalized segment> -> 0 for a command that cannot check a
# branch out: read_only_cmd, a worktree removal or prune, or another branch
# delete.
wt_chain_safe() {
  local w del=0
  local -a words
  read_only_cmd "$1" && return 0
  [[ "$1" =~ ^git[[:space:]]+worktree[[:space:]]+(remove|prune)([[:space:]]|$) ]] && return 0
  [[ "$1" =~ ^git[[:space:]]+branch[[:space:]]+(.*)$ ]] || return 1
  read -r -a words <<< "${BASH_REMATCH[1]}"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in
      --delete) del=1 ;;
      --force|--remotes|--quiet|--) ;;
      -*[!dDrfq]*) return 1 ;;
      -*[dD]*) del=1 ;;
      -*) ;;
    esac
  done
  [ "$del" = 1 ]
}

# held_branches <main root> -> the branches checked out in that repository's
# worktrees, one per line, less the branch of each linked worktree in
# REMOVED_WT. The main worktree is never dropped: git refuses to remove it.
held_branches() {
  local line wt="" first=1 phys
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        [ -z "$wt" ] || first=0
        wt="${line#worktree }" ;;
      'branch refs/heads/'*)
        if [ "$first" = 0 ] && [ "$REMOVED_WT" != $'\n' ] \
            && phys=$(cd "$wt" 2>/dev/null && pwd -P); then
          case "$REMOVED_WT" in *$'\n'"$phys"$'\n'*) continue ;; esac
        fi
        printf '%s\n' "${line#branch refs/heads/}" ;;
    esac
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
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
# isolation.blockInMain minus isolation.ignoreBlockInMain, read once per root,
# and HEAVY_DEFAULT[i] to 1 when HEAVY[i] is one of the schema's defaults
# (myspec-config.schema.json, beside the reader).
# The reader's notes go to stderr. When the reader fails (a partial install)
# there is no list: the first such command of the session is denied with the
# reader's error, recorded as a `notice` event, and later ones pass, as the
# Stop gate blocks once on a missing lib rather than guess.
HEAVY_ROOT=""
HEAVY=()
HEAVY_DEFAULT=()
heavy_patterns() {
  local p schema="$HOOK_LIB/myspec-config.schema.json"
  [ "$1" != "$HEAVY_ROOT" ] || return 0
  HEAVY_ROOT="$1"
  HEAVY=()
  HEAVY_DEFAULT=()
  [ -f "$schema" ] || schema=/dev/null
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
  # One line per entry: 1 or 0 (a schema default or not), a tab, the
  # pattern; then x, a tab, and each ignoreBlockInMain entry that names no
  # blockInMain entry (it drops nothing: a typo, or a changed default).
  while IFS= read -r p; do
    [ -n "${p#?$'\t'}" ] || continue
    case "$p" in
      x*) printf 'guard-worktree-context: isolation.ignoreBlockInMain entry matches no isolation.blockInMain entry, so it drops nothing: %s\n' "${p#?$'\t'}" >&2 ;;
      *)
        HEAVY+=("${p#?$'\t'}")
        HEAVY_DEFAULT+=("${p%%$'\t'*}") ;;
    esac
  done < <(jq -r --slurpfile schema "$schema" '
    ($schema[0].keys["isolation.blockInMain"].default // []) as $def
    | (.ignoreBlockInMain // [] | if type == "array" then . else [] end) as $skip
    | (.blockInMain // [] | if type == "array" then . else [] end) as $all
    | ($all[] | select(type == "string") | select(. as $p | $skip | index([$p]) | not)
       | (if . as $p | $def | index([$p]) then "1" else "0" end) + "\t" + .),
      ($skip[] | strings | select(. as $p | $all | index([$p]) | not) | "x\t" + .)' <<< "$SETTING" 2>/dev/null)
}

# heavy_match <segment> -> 0 when an entry of HEAVY matches the segment, the
# dry-run carve-out excepted for the default entries.
heavy_match() {
  local i
  for ((i = 0; i < ${#HEAVY[@]}; i++)); do
    grep -qE -- "${HEAVY[i]}" <<< "$1" || continue
    if [ "${HEAVY_DEFAULT[i]}" = 1 ] && grep -qE -- "$HEAVY_CARVE_OUT" <<< "$1"; then
      continue
    fi
    return 0
  done
  return 1
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

# A `git -C <dir>` into a directory an earlier segment creates (#372). `cd`
# needs only the `&&` chain (cd_link), because a cd that fails stops it. A
# `git -C` names its directory afresh, so what runs between the creation and
# the use could turn a new worktree back into a plain directory of the main
# checkout. C_MADE holds the CD_MADE entries a `git -C` may follow: those of a
# creation with no `|` or `||` link in front of it and no `!` (WT_LINK_OK).
# It is emptied with CD_MADE at the end of the chain, and by any segment in
# between that is not a creation, a cd, a git command whose final -C is a
# created directory (`git worktree` excepted), a redirect's tail, or
# read-only (c_read_only). A variable or substituted path is never followed.
# C_NEW_WT is the -C counterpart of CD_NEW_WT, kept apart so that forgetting
# what a -C entered never drops what a cd entered.
C_MADE=()
C_NEW_WT=()    # the created worktrees a `git -C` entered
C_KEEP=0       # walk, per segment: 1 when the segment cannot empty C_MADE

# c_forget -> empties C_MADE and C_NEW_WT, so a later classify reads a
# directory a -C names as it is.
c_forget() {
  C_MADE=() C_NEW_WT=() CLS_KEY=""
}

# c_read_only <normalized segment> -> 0 for read_only_cmd with no output
# redirect but to /dev/null (`echo … > new/.git` rewrites a worktree). A
# trailing `>` is the first half of `2>&1`.
c_read_only() {
  local s="${1%>}"
  s="${s//>>\/dev\/null/}"
  s="${s//>\/dev\/null/}"
  case "$s" in *'>'*) return 1 ;; esac
  read_only_cmd "$1"
}

# git_c_target_to <var> <base> <word> -> the directory `git -C <word>` from
# <base> enters: an existing one physically, else cd_target_to with C_MADE as
# the record of created directories and C_NEW_WT for the worktrees it enters.
git_c_target_to() {
  local _gc_p _gc_rc=0
  local -a _gc_made _gc_wt
  CD_LEXICAL=0
  cd_word_to _gc_p "$2" "$3" || return 1
  if _gc_p=$(cd "$_gc_p" 2>/dev/null && pwd -P); then
    printf -v "$1" '%s' "$_gc_p"
    return 0
  fi
  [ "${#C_MADE[@]}" -gt 0 ] || return 1
  _gc_made=(${CD_MADE[@]+"${CD_MADE[@]}"})
  _gc_wt=(${CD_NEW_WT[@]+"${CD_NEW_WT[@]}"})
  CD_MADE=("${C_MADE[@]}")
  CD_NEW_WT=(${C_NEW_WT[@]+"${C_NEW_WT[@]}"})
  cd_target_to "$1" "$2" "$3" || _gc_rc=1
  # `new/..` lands where a directory exists: not a created one.
  [ "$_gc_rc" = 1 ] || [ ! -d "${!1}" ] || CD_LEXICAL=0
  C_NEW_WT=(${CD_NEW_WT[@]+"${CD_NEW_WT[@]}"})
  CD_MADE=(${_gc_made[@]+"${_gc_made[@]}"})
  CD_NEW_WT=(${_gc_wt[@]+"${_gc_wt[@]}"})
  return "$_gc_rc"
}

# check_segment <normalized segment> <dir> <git-dir> — applies both gates.
check_segment() {
  local segment="$1" dir="$2" gitdir="$3" verdict

  note_segment "$segment" "$dir"
  [ "$WT_GLUE" = 1 ] || [ "$C_KEEP" = 1 ] || c_read_only "$segment" || c_forget

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
  if heavy_match "$segment"; then
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

# --- gate C: the files the command writes ------------------------------------

# Each named target as a Write of that file, judged by the Write|Edit hook
# itself: one rule for both tools, and its block message carries the ask.
ISO_HOOK="$(dirname "${BASH_SOURCE[0]}")/require-isolation-decision.sh"
C_SEEN=$'\n'

# gate_c <command> <dir> — blocks (and exits) on the first target the hook
# denies. walk calls it for the command and for every `bash -c` / `eval`
# payload, each from the directory it starts in. Cost: the hook runs once per
# distinct target, and not at all when the session's answer lets every one
# through.
gate_c() {
  local target verdict
  declare -F bash_write_targets >/dev/null && [ -f "$ISO_HOOK" ] && [ -n "$SESSION_ID" ] || return 0
  # The scanner's globals, per command scanned.
  COMMAND="$1" SCAN_PLAIN="" SCAN_KEEP="" SCAN_KEPT=0
  # A directory the command creates before it cds there does not exist yet
  # (cd_target_to); its existing prefix is already physical.
  BASE_DIR=$(physical_dir "$2") || BASE_DIR="$2"
  bash_may_write || return 0
  # develop lets every write through, as the hook would. In worktree mode
  # MYSPEC_ALLOW_MAIN_CHECKOUT=1, gate B's advertised escape, lifts the same
  # block here; it never skips the first question.
  if checkout_facts "$BASE_DIR" && [ -n "$CF_MAIN" ]; then
    session_mode "$CF_MAIN"
    case "$ISO_MODE" in
      develop) return 0 ;;
      worktree) [ "$ALLOW_MAIN_CHECKOUT" = 0 ] || return 0 ;;
    esac
  fi
  scan_command keep
  while IFS= read -r target; do
    case "$target" in ''|cd:*) continue ;; esac
    case "$C_SEEN" in *$'\n'"$target"$'\n'*) continue ;; esac
    C_SEEN="$C_SEEN$target"$'\n'
    verdict=$(jq -nc --arg f "$target" --arg c "$2" --arg s "$SESSION_ID" \
        '{tool_name: "Write", tool_input: {file_path: $f}, cwd: $c, session_id: $s}' \
      | bash "$ISO_HOOK" 2>/dev/null \
      | jq -r '.hookSpecificOutput | select(.permissionDecision == "deny") | .permissionDecisionReason' 2>/dev/null) || verdict=""
    [ -z "$verdict" ] || pretool_deny "Bash write to $target, judged as a Write of that file:

$verdict"
  done < <(bash_write_targets)
}

# note_made <dir> <encoded word>... -> cd_note_made over the decoded words.
note_made() {
  local dir="$1" w
  local -a d=()
  shift
  for w in "$@"; do
    decode_word_to w "$w"
    d+=("$w")
  done
  cd_note_made "$dir" ${d[@]+"${d[@]}"}
}

# c_note_made <count before> -> copies the CD_MADE entries the segment just
# added to C_MADE when its links allow (WT_LINK_OK), and keeps C_MADE through
# the segment: a creation does not change what another directory is.
c_note_made() {
  local i="$1"
  C_KEEP=1
  [ "$WT_LINK_OK" = 1 ] || return 0
  while [ "$i" -lt "${#CD_MADE[@]}" ]; do
    C_MADE+=("${CD_MADE[i]}")
    i=$((i + 1))
  done
}

# walk <command> <start dir> <depth> — checks every segment of <command>.
# Blocks (and exits) on the first offending segment; returns when clean.
walk() {
  local cmd="$1" dir="$2" depth="$3" start="$2"
  local -a seps segs_s segs_r sw rw stack helds
  local line k n j c w sub gdir gitdir norm payload held="" chain="" link esc=0
  local made clex
  local saved_wt="$REMOVED_WT"

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
  # A backslash in a removal's text: the scanner blanked it, so the path it
  # reads is not the one git gets (note_segment).
  # shellcheck disable=SC1003 # an ERE: the backslashes are literal
  if grep -qE 'worktree[[:space:]\\]+remove[^;&|()]*\\' <<< "$cmd"; then esc=1; fi

  # A payload (`bash -c`) sees what the command around it creates.
  if [ "$depth" = 0 ]; then CD_MADE=() CD_NEW_WT=() C_MADE=() C_NEW_WT=(); fi
  stack=() helds=()
  for ((k = 0; k < n; k++)); do
    link="${seps[k]}"
    case "$link" in
      +|r) ;;
      *) chain="$chain$link" ;;
    esac
    case "${seps[k]}" in
      '(') stack+=("$dir") helds+=("$held") ;;
      ')')
        if [ "${#stack[@]}" -gt 0 ]; then
          dir="${stack[${#stack[@]}-1]}" held="${helds[${#helds[@]}-1]}"
          unset "stack[${#stack[@]}-1]" "helds[${#helds[@]}-1]"
        fi
        ;;
    esac
    # held: the directory before a cd into a created one, until the `&&`
    # chain ends (cd_link).
    if ! cd_link "${seps[k]}"; then
      c_forget
      if [ -n "$held" ]; then dir="$held" held=""; fi
    fi

    sw=()
    rw=()
    read -r -a sw <<< "${segs_s[k]}" || true
    read -r -a rw <<< "${segs_r[k]:-}" || true
    [ "${#sw[@]}" -gt 0 ] || continue
    # A worktree removal carries over only through an unbroken && link; ^ is
    # the start of a payload, which runs where its bash -c / eval segment does.
    WT_GLUE=0
    if [ "$link" = r ]; then
      WT_GLUE=1
    else
      case "$chain" in '^'|'&&') ;; *) REMOVED_WT=$'\n' ;; esac
      WT_LINK_OK=1
      case "$chain" in *'|'*) WT_LINK_OK=0 ;; esac
      [ "$esc" = 0 ] || WT_LINK_OK=0
      case " ${segs_s[k]} " in *[[:space:]]'!'[[:space:]]*) WT_LINK_OK=0 ;; esac
      chain=""
    fi
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
    # What the segment creates, for a later cd into it.
    C_KEEP=0
    if [ "$c" = mkdir ]; then
      made="${#CD_MADE[@]}"
      note_made "$dir" "${rw[@]:j}"
      c_note_made "$made"
    fi
    case "$c" in
      cd|pushd)
        j=$((j + 1))
        while [ "$j" -lt "${#sw[@]}" ] && [[ "${sw[j]}" == -?* ]]; do j=$((j + 1)); done
        decode_word_to sub "${rw[j]:-}"
        # `pushd +N` rotates the stack: no literal directory.
        if [[ "$sub" != +* ]] && cd_target_to sub "$dir" "$sub"; then
          [ "$CD_LEXICAL" = 0 ] || [ -n "$held" ] || held="$dir"
          dir="$sub"
        fi
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
        else
          REMOVED_WT=$'\n'; c_forget   # a script, or a payload not scanned (#384)
        fi
        continue ;;
      eval)
        if [ "$depth" -lt "$MAX_DEPTH" ]; then
          walk "$(decode_word "$(join_words $((j + 1)) "${rw[@]}")")" "$dir" $((depth + 1))
        else
          REMOVED_WT=$'\n'; c_forget
        fi
        continue ;;
      git)
        gdir="$dir"
        gitdir=""
        clex=0   # 1 while the last -C entered a created directory
        j=$((j + 1))
        while [ "$j" -lt "${#sw[@]}" ]; do
          case "${sw[j]}" in
            -C)
              decode_word_to sub "${rw[j+1]:-}"
              # git ignores an empty -C; cd_word_to would read it as $HOME.
              if [ -z "$sub" ]; then
                :
              elif git_c_target_to sub "$gdir" "$sub"; then
                gdir="$sub" clex="$CD_LEXICAL"
              else
                clex=0
              fi
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
        C_KEEP="$clex"
        # `git worktree` other than add can remove a created worktree.
        if [ "${sw[j]:-}" = worktree ]; then
          C_KEEP=0
          if [ "${sw[j+1]:-}" = add ]; then
            made="${#CD_MADE[@]}"
            note_made "$gdir" git "${rw[@]:j}"
            c_note_made "$made"
          fi
        fi
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
  # A payload's own removals stay inside it. One that emptied the list (a
  # link, or a command that might check a branch out) leaves it empty.
  if [ "$depth" -gt 0 ] && [ "$REMOVED_WT" != $'\n' ]; then REMOVED_WT="$saved_wt"; fi
  # After gates A and B: a branch or worktree block names the real problem.
  gate_c "$cmd" "$start"
}

walk "$COMMAND" "$START_DIR" 0
exit 0
