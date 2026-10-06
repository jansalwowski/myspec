#!/usr/bin/env bash
# mark-code-changed.sh
# PostToolUse hook (Write|Edit and Bash matchers) — records every file this
# session writes, and keeps the session's live log. Also a PostToolUseFailure
# hook (Bash matcher): a Bash call that exits non-zero fires that event
# instead, with the same tool_input, and its writes landed all the same. And
# a PreToolUse hook (Bash matcher), where it only snapshots what a Bash write
# is about to change (below).
#
# Ledger: `write` events in the session-state file,
# .claude/state/sessions/<session_id>.jsonl in the main checkout of the
# repository holding the file (lib/session-event.sh, the only reader and
# writer), one per written file: `{"t":"write","root":<checkout>,"rel":<path>,
# "kind":"code|file","via":"bash|tool"}`. The root is the physical toplevel of the checkout
# holding the file, so a write in another repository or in a linked worktree
# never arms this checkout. A write in a submodule is filed with its
# superproject, whose checks verify it. verify-before-stop.sh runs its checks
# only when a `code` write for its checkout is newer than its last `verified`
# event. It reads every write as the list of files this session wrote when it
# decides whose failure it is. That is why non-code writes are recorded too: a
# config file this session edited is its own. Only a myspec project or one
# with a stop gate (.myspec.json or .claude/verification.json) gets the file.
#
# Snapshots, for the Stop gate's content checks (lib/stop-gate/content.sh,
# docs/stop-gate.md R14): a Bash write to a file those checks cover (a doc,
# or a file under .claude/, docs/ or the aiDir, not gitignored) is recorded
# with its content before and after, as git blobs written to the
# repository's object store (`git hash-object -w`; unreferenced, so git's gc
# prunes them). At PreToolUse each such target gets
# `{"t":"pre","root","rel","blob"}` (blob "" when the file does not exist
# yet), and at PostToolUse its `write` event carries the after-blob. The
# Stop gate judges only the lines between the two: what this session's Bash
# writes added, whatever the file held before or another session adds.
#
# Implement events: a Bash command that runs `session-event.sh implement
# start|stop` (feature-implement's orchestration state) is recorded here as
# `{"t":"implement","state":...}`, in the state file of the payload cwd's
# checkout. The model never sees its session id; this hook's payload has it.
#
# Session log: .claude/state/sessions/<session_id>.md in the PRIMARY checkout
# of the repository the edited file belongs to, created on the first code edit
# and appended to on every later one (`## Files touched`). Until 2.0 it lived
# under <aiDir>/memory/sessions/active/ — an untracked file in the doc tree
# that every git and worktree operation needed a special case for. The state
# directory is gitignored by construction and outside the doc tree.
#
# The store is pinned to the primary worktree: resolving from the hook's cwd
# instead lets a log land inside a linked worktree, where the bootstrap sweep
# never sees it and `git worktree remove` destroys it. Anchoring on the EDITED
# FILE (not the cwd) keeps a session that edits another repository from filing
# its log in this one.
#
# Bash writes: `sed -i`, redirects, `tee` and the like never fire the
# Write|Edit matcher, so this hook is registered under a Bash matcher too.
# Two sources name what a Bash call wrote (docs/stop-gate.md, Session
# writes). The status diff (lib/status-diff.sh, #276) captures `git status`
# of the checkouts the call reaches at PreToolUse and takes what changed by
# PostToolUse: a variable path, an interpreter's write, `git apply`. The
# command scanner (quoted spans and heredoc bodies blanked by
# lib/command-scan.sh) reads the targets the command names: a redirect
# target other than /dev/null or a descriptor, the operands of `tee`, `sed -i`
# and `perl -i`, every operand of `mv`, the destination of `cp`, `rsync` and
# `install`, and the files `patch` edits and writes. It alone sees a
# gitignored file, a project without git, and a call the diff could not
# take. Reading, grepping or running a file records nothing.
#
# `## Files touched` is how a skill finds ITS OWN session among several: the
# harness never exposes the session id to the model, but the paths it edited
# are known to it. Tests live in the plugin repository (hooks/tests/), which
# projects do not receive.
#
# Subagents (#225): a subagent's tool events carry the parent's session_id
# plus an agent_id (and agent_type); the main session's carry neither. The
# state file stays keyed by session_id, so a subagent's write arms the
# parent's Stop gate. Its events gain an "agent" field, the agent_id. In the
# log, a subagent's path is tagged `(subagent <agent_id>[, <agent_type>])`, so
# session-complete can tell the controller's own edits from delegated ones.
#
# Settings (#231, docs/project-settings-design.md), read through
# lib/myspec-config.sh (read_setting in lib/hook-core.sh) from the checkout
# that holds the written file:
# hooks.markCodeChanged.extraCodeExtensions adds to CODE_EXT, and a write to a
# path matching a hooks.markCodeChanged.ignorePaths glob (lib/glob-regex.sh,
# the same semantics as checks[].paths) is recorded as
# `file`, never `code`, so it does not arm the gate by itself. A default
# extension cannot be removed; ignoring the paths that hold it is the lever.

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
  exit 0
fi
[ -f "$HOOK_CORE" ] && [ -f "$(dirname "$HOOK_CORE")/session-event.sh" ] || exit 0
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/session-event.sh
. "$HOOK_LIB/session-event.sh"
# The content checks' scope decides which Bash writes get snapshots. Without
# the file the writes are still recorded; the Stop hook names the missing lib.
SNAPSHOTS=0
if [ -f "$HOOK_LIB/content-checks.sh" ] && [ -f "$HOOK_LIB/markdown-section-check.sh" ]; then
  # shellcheck source=lib/content-checks.sh
  . "$HOOK_LIB/content-checks.sh"
  SNAPSHOTS=1
fi

CODE_EXT='(ts|tsx|vue|js|jsx|mjs|cjs|mts|cts|py|rb|go|java|php|rs|cs|swift|kt|sh|bash|graphql|gql)'

# ere_literal <text> -> the text as an ERE matching only itself, so an
# extension such as c++ is the literal suffix.
ere_literal() {
  local s="$1" out="" c i=0
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      "."|"["|"\\"|"("|")"|"*"|"+"|"?"|"{"|"|"|"^"|'$') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# code_re_or_default <ERE> -> the ERE when it compiles, else the default
# code pattern with a warning: an uncompilable pattern makes every [[ =~ ]]
# return 2, which would record every write as file and never arm the gate.
code_re_or_default() {
  local rc=0
  # shellcheck disable=SC2319 # the [[ ]] status is the point: 2 = no compile
  [[ "x" =~ $1 ]] || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "mark-code-changed: hooks.markCodeChanged.extraCodeExtensions gave a pattern that does not compile; using the default extensions" >&2
    printf '%s' "\\.${CODE_EXT}\$"
  else
    printf '%s' "$1"
  fi
}

# Per-checkout settings, cached for this run: SET_ROOTS[i] has the code
# pattern SET_CODE_RE[i] and the ignore patterns SET_IGNORE[i] (one ERE per
# line).
SET_ROOTS=()
SET_CODE_RE=()
SET_IGNORE=()

# load_settings <checkout root> -> sets CODE_RE and IGNORE_RES for it. Read
# from the checkout itself, else its primary checkout when it has no
# .myspec.json (as worktree-provision.sh does). No .myspec.json, no reader or
# an unreadable value: the defaults, and the reader names what it ignored.
load_settings() {
  local root="$1" src json ext exts="" g i re
  for ((i = 0; i < ${#SET_ROOTS[@]}; i++)); do
    if [ "${SET_ROOTS[$i]}" = "$root" ]; then
      CODE_RE="${SET_CODE_RE[$i]}"
      IGNORE_RES="${SET_IGNORE[$i]}"
      return 0
    fi
  done
  CODE_RE="\\.${CODE_EXT}\$"
  IGNORE_RES=""
  src="$root"
  if [ ! -f "$src/.myspec.json" ]; then
    src=$(main_worktree_root "$root" 2>/dev/null) || src=""
  fi
  if [ -n "$src" ] && [ -f "$src/.myspec.json" ]; then
    json=""
    read_setting hooks.markCodeChanged "$src" && json="$SETTING"
    [ -z "$SETTING_NOTES" ] || printf '%s\n' "$SETTING_NOTES" | sed 's/^/myspec-config: /' >&2
    if [ -n "$json" ]; then
      while IFS= read -r ext; do
        ext="${ext#.}"
        if [[ "$ext" =~ ^[A-Za-z0-9_+-]+(\.[A-Za-z0-9_+-]+)*$ ]]; then
          exts="$exts|$(ere_literal "$ext")"
        elif [ -n "$ext" ]; then
          echo "mark-code-changed: ignoring hooks.markCodeChanged.extraCodeExtensions entry '$ext': not an extension" >&2
        fi
      done < <(printf '%s' "$json" | jq -r '(.extraCodeExtensions // [])[] | strings' 2>/dev/null)
      if [ -n "$exts" ]; then
        CODE_RE=$(code_re_or_default "\\.(${CODE_EXT:1:${#CODE_EXT}-2}${exts})\$")
      fi
      # The globs compile through lib/glob-regex.sh (sourced by hook-core),
      # the one compiler the Stop hook's `paths` and provisioning's `clean`
      # use too.
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        if ! declare -F glob_regex >/dev/null; then
          echo "mark-code-changed: ignoring hooks.markCodeChanged.ignorePaths: lib/glob-regex.sh was not found in $HOOK_LIB" >&2
          break
        fi
        if ! re=$(glob_regex "$g"); then
          echo "mark-code-changed: ignoring hooks.markCodeChanged.ignorePaths glob '$g': it leaves the checkout" >&2
          continue
        fi
        IGNORE_RES="$IGNORE_RES$re"$'\n'
      done < <(printf '%s' "$json" | jq -r '(.ignorePaths // [])[] | strings' 2>/dev/null)
    fi
  fi
  SET_ROOTS+=("$root")
  SET_CODE_RE+=("$CODE_RE")
  SET_IGNORE+=("$IGNORE_RES")
}

# ignored <rel> -> 0 when the repo-relative path matches an IGNORE_RES glob.
ignored() {
  local re
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    [[ "$1" =~ $re ]] && return 0
  done <<< "$IGNORE_RES"
  return 1
}

# Pin a checkout to the primary worktree: a linked worktree's main checkout
# (checkout_facts), else the checkout itself (the main checkout, a submodule,
# a worktree of a bare repository).
main_worktree_root() {
  checkout_facts "$1" || return 1
  printf '%s\n' "${CF_MAIN:-$CF_ROOT}"
}

# checkout_root <existing dir> -> the physical root of the checkout holding it:
# its git toplevel, or, in a project without git, the nearest directory with a
# .myspec.json. Fails when there is neither: nothing there to verify.
checkout_root() {
  local dir="$1"
  if checkout_facts "$dir"; then
    printf '%s\n' "$CF_ROOT"
    return
  fi
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

# emit_target <word> [must-exist] [no-glob] -> the physical path of a written
# file named by <word>, taken from BASE_DIR when relative (the payload cwd,
# moved by any literal `cd` earlier in a Bash command; physical_path in
# lib/hook-core.sh). Placeholders for quoted spans (Q), variables,
# substitutions, remote paths and devices name nothing this hook can resolve.
# A glob expands against BASE_DIR. With must-exist, a word that is not a
# file after the write is skipped: sed's and perl's script operand.
emit_target() {
  local w="$1" p
  case "$w" in
    ''|Q|-|*'$'*|*'`'*|*:*|/dev/*) return 0 ;;
  esac
  if [ -z "${3:-}" ] && [[ "$w" == *[\*\?\[]* ]]; then
    # A failed cd or an empty glob both mean no targets.
    while IFS= read -r p; do
      emit_target "$p" "${2:-}" no-glob
    done < <(cd "$BASE_DIR" 2>/dev/null && { compgen -G "$w" || true; })
    return 0
  fi
  target_path_to p "$w" || return 0
  if [ -d "$p" ]; then
    return 0
  fi
  if [ -n "${2:-}" ] && [ ! -f "$p" ]; then
    return 0
  fi
  printf '%s\n' "$p"
}

# Directories target_path_to resolved, for this run: RES_DIRS[i] is
# RES_PHYS[i] physically.
RES_DIRS=()
RES_PHYS=()

# target_path_to <var> <word> -> physical_path "<word>" "$BASE_DIR" into
# <var>, with each directory resolved once per run: a long command names the
# same few directories over and over, and the subshells physical_path spends
# per call cost seconds on one (#277). A path ending in / takes physical_path
# itself.
target_path_to() {
  local _tp_p="$2" _tp_dir _tp_rest _tp_phys="" _tp_i
  case "$_tp_p" in
    /*) ;;
    *) _tp_p="${BASE_DIR:-$PWD}/$_tp_p" ;;
  esac
  case "$_tp_p" in
    */)
      _tp_p=$(physical_path "$_tp_p") || return 1
      printf -v "$1" '%s' "$_tp_p"
      return 0
      ;;
  esac
  _tp_dir="${_tp_p%/*}"
  _tp_rest="${_tp_p##*/}"
  [ -n "$_tp_dir" ] || _tp_dir=/
  while [ ! -d "$_tp_dir" ]; do
    _tp_rest="${_tp_dir##*/}/$_tp_rest"
    _tp_dir="${_tp_dir%/*}"
    [ -n "$_tp_dir" ] || _tp_dir=/
  done
  for ((_tp_i = 0; _tp_i < ${#RES_DIRS[@]}; _tp_i++)); do
    if [ "${RES_DIRS[$_tp_i]}" = "$_tp_dir" ]; then
      _tp_phys="${RES_PHYS[$_tp_i]}"
      break
    fi
  done
  if [ -z "$_tp_phys" ]; then
    _tp_phys=$(cd "$_tp_dir" 2>/dev/null && pwd -P) || return 1
    RES_DIRS+=("$_tp_dir")
    RES_PHYS+=("$_tp_phys")
  fi
  printf -v "$1" '%s/%s' "${_tp_phys%/}" "$_tp_rest"
}

# SCAN_PLAIN and SCAN_KEEP: the command's segments (split_segments) from the
# blanking and the keep scan of lib/command-scan.sh, each made once per hook
# call (scan_command) and read by the write gate, bash_write_targets and
# implement_requests alike.
SCAN_PLAIN=""
SCAN_KEEP=""
SCAN_KEPT=0

# scan_command [keep]: fills SCAN_PLAIN from $COMMAND, and SCAN_KEEP too with
# `keep`, each once.
scan_command() {
  if [ -z "$SCAN_PLAIN" ]; then
    SCAN_PLAIN=$(printf '%s' "$COMMAND" | sanitize_command | split_segments)
  fi
  if [ -n "${1:-}" ] && [ "$SCAN_KEPT" = 0 ]; then
    # shellcheck disable=SC2119 # keep mode is the argument
    SCAN_KEEP=$(printf '%s' "$COMMAND" | sanitize_command keep | split_segments)
    SCAN_KEPT=1
  fi
}

# segment_matches <pattern>... -> 0 when a segment of $COMMAND, its prefix
# stripped, matches one of the anchored EREs: find_matching_segment over the
# scan already made.
segment_matches() {
  local line seg pattern
  scan_command
  while IFS= read -r line; do
    strip_command_prefix_to seg "${line#*$'\t'}"
    for pattern in "$@"; do
      [[ "$seg" =~ $pattern ]] && return 0
    done
  done <<< "$SCAN_PLAIN"
  return 1
}

# bash_write_targets -> the files $COMMAND writes, one physical
# path per line. Every segment is scanned for redirects; a segment's operands
# count only when a write verb stands at its command position. A literal `cd`
# moves BASE_DIR for the segments after it, and a subshell restores it on exit,
# so `cd <worktree> && echo x > a.ts` records the worktree's file.
# Two scans of the command run in step: the plain one (quoted spans blanked to
# Q) decides what is a verb, an option or a redirect; the `keep` one supplies
# the operand's text, so a quoted literal path ("src/a.ts") resolves too. Both
# split into the same segments and words (lib/command-scan.sh).
bash_write_targets() {
  local line kline sep seg kseg verb word skip i last dest next inplace dw
  local -a words kwords ops scopes=()
  while IFS= read -r line && IFS= read -r kline <&3; do
    sep="${line%%$'\t'*}"
    case "$sep" in
      '(') scopes+=("$BASE_DIR") ;;
      ')')
        if [ "${#scopes[@]}" -gt 0 ]; then
          BASE_DIR="${scopes[${#scopes[@]}-1]}"
          unset "scopes[${#scopes[@]}-1]"
        fi
        ;;
    esac
    strip_command_prefix_to seg "${line#*$'\t'}"
    [ -n "$seg" ] || continue
    strip_command_prefix_to kseg "${kline#*$'\t'}"

    # Split as `read -a` does, without a here-string per segment (a temp
    # file each in bash 3.2) and with no glob expansion.
    set -f
    # shellcheck disable=SC2206 # word splitting is the point; globbing is off
    words=($seg) kwords=($kseg)
    set +f
    [ "${#words[@]}" -gt 0 ] || continue
    if [ "${#kwords[@]}" -ne "${#words[@]}" ]; then
      kwords=("${words[@]}")
    fi
    # A redirect before the command name, or after a brace group or subshell
    # (`{ ...; } >> f` leaves `>> f` as a segment of its own): its target is
    # written whatever runs, and the word after it is the command name.
    while [ "${#words[@]}" -gt 0 ] && [[ "${words[0]}" =~ ^[0-9]*\>{1,2} ]]; do
      if [[ "${words[0]}" =~ ^[0-9]*\>{1,2}$ ]]; then
        if [ "${#words[@]}" -ge 2 ]; then
          decode_word_to dw "${kwords[1]}"
          emit_target "$dw"
        fi
        words=("${words[@]:2}")
        kwords=("${kwords[@]:2}")
      else
        [[ "${kwords[0]}" =~ ^[0-9]*\>{1,2}(.*)$ ]]
        decode_word_to dw "${BASH_REMATCH[1]}"
        emit_target "$dw"
        words=("${words[@]:1}")
        kwords=("${kwords[@]:1}")
      fi
    done
    [ "${#words[@]}" -gt 0 ] || continue
    if [ "${words[0]}" = cd ]; then
      [ "${#words[@]}" -lt 2 ] || decode_word_to dw "${kwords[1]}"
      if [ "${#words[@]}" -ge 2 ] && next=$(cd "$BASE_DIR" 2>/dev/null && cd "$dw" 2>/dev/null && pwd -P); then
        BASE_DIR="$next"
        # Not a target: a checkout this command reaches, for the status diff.
        printf 'cd:%s\n' "$next"
      fi
      continue
    fi

    verb="${words[0]##*/}"
    ops=()
    skip=0
    inplace=0
    for ((i = 1; i < ${#words[@]}; i++)); do
      word="${words[$i]}"
      if [ "$skip" -eq 1 ]; then
        skip=0
        continue
      fi
      # Redirects: `>` or `2>>` alone takes the next word as its target, an
      # attached one (`>out.ts`) the rest of the word. `2>&1` and `>&2` never
      # get here with a target: the split on `&` leaves nothing after `>`.
      if [[ "$word" =~ ^[0-9]*\>{1,2}$ ]]; then
        if [ $((i + 1)) -lt "${#words[@]}" ]; then
          decode_word_to dw "${kwords[$((i + 1))]}"
          emit_target "$dw"
        fi
        skip=1
        continue
      fi
      if [[ "$word" =~ ^[0-9]*\>{1,2}(.+)$ ]]; then
        [[ "${kwords[$i]}" =~ ^[0-9]*\>{1,2}(.*)$ ]]
        decode_word_to dw "${BASH_REMATCH[1]}"
        emit_target "$dw"
        continue
      fi
      case "$word" in
        *'>'*)
          # Attached mid-word (`x>out.ts`): only an unquoted target is readable.
          [[ "${word##*>}" == *Q* ]] || emit_target "${word##*>}"
          continue
          ;;
        '<'|*'<') skip=1; continue ;;
        *'<'*) continue ;;
        -*)
          # -i anywhere among the options, alone or bundled (-ni, -pi,
          # -i.bak). Perl's -M/-m take a module name, which may hold an i.
          if { [ "$verb" = sed ] && { [[ "$word" =~ ^-[a-zA-Z]*i ]] || [[ "$word" == --in-place* ]]; }; } \
              || { [ "$verb" = perl ] && [[ ! "$word" =~ ^-[Mm] ]] && [[ "$word" =~ ^-[a-zA-Z]*i ]]; }; then
            inplace=1
          fi
          case "$verb:$word" in
            # Options that take the next word as their value. patch -o names
            # the file it writes.
            patch:-o|patch:--output)
              if [ $((i + 1)) -lt "${#words[@]}" ]; then
                decode_word_to dw "${kwords[$((i + 1))]}"
                emit_target "$dw"
              fi
              skip=1
              ;;
            patch:-[idprBDFVYzg]|install:-[mogS]) skip=1 ;;
          esac
          continue
          ;;
      esac
      decode_word_to dw "${kwords[$i]}"
      ops+=("$dw")
    done
    [ "${#ops[@]}" -gt 0 ] || continue
    last="${ops[${#ops[@]}-1]}"

    case "$verb" in
      sed|perl)
        # The script is an operand too unless -e gave it; it is not a file.
        [ "$inplace" -eq 1 ] || continue
        for word in "${ops[@]}"; do emit_target "$word" must-exist; done
        ;;
      tee)
        for word in "${ops[@]}"; do emit_target "$word"; done
        ;;
      mv|cp|rsync|install)
        # A move deletes its sources: those are changes too.
        if [ "$verb" = mv ]; then
          for word in "${ops[@]}"; do emit_target "$word"; done
        fi
        target_path_to dest "$last" || continue
        if [ -d "$dest" ]; then
          for ((i = 0; i < ${#ops[@]} - 1; i++)); do
            emit_target "$last/$(basename "${ops[$i]}")"
          done
        elif [ "$verb" != mv ]; then
          emit_target "$last"
        fi
        ;;
      patch)
        # patch [options] [originalfile [patchfile]]
        emit_target "${ops[0]}" must-exist
        ;;
    esac
  done <<< "$SCAN_PLAIN" 3<<< "$SCAN_KEEP"
  return 0
}

# Events for the session-state files, appended once the targets are done
# (flush_events): one jq call and one session_append_many per home, however
# many files the command wrote (#277). QUEUE_HOMES[i] is the home of the
# event built from fields 7i to 7i+6 of QUEUE_FIELDS: t, root, rel, kind,
# via, blob, and 1 when the event carries the blob (a `pre` event's "" means
# no file; a write without a snapshot has no blob field at all).
QUEUE_HOMES=()
QUEUE_FIELDS=()

# queue_event <home> <t> <root> <rel> <kind> <via> <blob> <has blob>; kind
# and via are empty for a `pre` event.
queue_event() {
  QUEUE_HOMES+=("$1")
  shift
  QUEUE_FIELDS+=("$@")
}

# flush_events: appends the queued events, home by home in first-queued
# order, each in the order queued. A write event carries this run's agent.
flush_events() {
  local i j home done_homes=$'\n'
  local -a args
  for ((i = 0; i < ${#QUEUE_HOMES[@]}; i++)); do
    home="${QUEUE_HOMES[$i]}"
    case "$done_homes" in *$'\n'"$home"$'\n'*) continue ;; esac
    done_homes="$done_homes$home"$'\n'
    args=()
    for ((j = i; j < ${#QUEUE_HOMES[@]}; j++)); do
      [ "${QUEUE_HOMES[$j]}" = "$home" ] || continue
      args+=("${QUEUE_FIELDS[@]:$((j * 7)):7}")
    done
    jq -nc --arg ag "$AGENT_ID" '$ARGS.positional as $a | range(0; $a | length; 7) as $i
      | {t: $a[$i], root: $a[$i + 1], rel: $a[$i + 2]}
        + (if $a[$i + 3] != "" then {kind: $a[$i + 3], via: $a[$i + 4]} else {} end)
        + (if $a[$i + 6] == "1" then {blob: $a[$i + 5]} else {} end)
        + (if $a[$i] == "write" and $ag != "" then {agent: $ag} else {} end)' \
      --args "${args[@]}" | session_append_many "$home" "$SESSION_ID" || true
  done
  QUEUE_HOMES=()
  QUEUE_FIELDS=()
}

# ledger_home_to <var> <root> -> the session home a write in <root> is filed
# with; fails when neither it nor the cwd's checkout is tracked. A checkout
# nested in the cwd's (a plain clone, not a submodule) whose own repository
# is untracked is filed with the cwd's checkout instead, under its own root:
# the Stop gate verifies such a root through the cwd's checkout (NESTED_ROOTS
# in lib/stop-gate/arm.sh). A checkout counts as tracked when its home or the
# checkout itself has the config: a linked worktree's branch can add a stop
# gate the main checkout does not have yet. The last answer is kept: the
# targets of one command share a root.
LH_ROOT="" LH_HOME="" LH_RC=1
ledger_home_to() {
  local _lh_home
  if [ "$2" != "$LH_ROOT" ] || [ -z "$LH_ROOT" ]; then
    LH_ROOT="$2" LH_HOME="" LH_RC=0
    if _lh_home=$(session_home "$2"); then
      if ! session_tracked_at "$_lh_home" "$2"; then
        case "$2/" in
          "$CWD_ROOT"/?*) [ -n "$CWD_ROOT" ] && [ -n "$CWD_HOME" ] && _lh_home="$CWD_HOME" || LH_RC=1 ;;
          *) LH_RC=1 ;;
        esac
      fi
    else
      LH_RC=1
    fi
    [ "$LH_RC" = 1 ] || LH_HOME="$_lh_home"
  fi
  [ "$LH_RC" = 0 ] || return 1
  printf -v "$1" '%s' "$LH_HOME"
}

# root_ai_to <var> <root> -> <root>'s aiDir (ai_dir), "" without a
# .myspec.json, read once per run and root: the content checks' scope.
AI_ROOT="" AI_DIR=""
root_ai_to() {
  if [ "$2" != "$AI_ROOT" ] || [ -z "$AI_ROOT" ]; then
    AI_ROOT="$2" AI_DIR=""
    [ ! -f "$2/.myspec.json" ] || AI_DIR=$(ai_dir "$2")
  fi
  printf -v "$1" '%s' "$AI_DIR"
}

# The writes of this run, one per target in order (pend_write), recorded by
# record_pending: PEND_KIND is "" at PreToolUse, PEND_HOME the ledger home;
# snapshot_pending sets PEND_SNAP (0: PEND_BLOB is the snapshot, 1: not
# judged, 2: judged but neither hashed nor kept) and PEND_SEEN marks a write
# already recorded. PEND_BEFORE is the file's content before the call when
# the status diff found the write (a blob id, "-" for no file), else "".
PEND_ROOT=()
PEND_REL=()
PEND_KIND=()
PEND_HOME=()
PEND_SNAP=()
PEND_BLOB=()
PEND_SEEN=()
PEND_BEFORE=()

# pend_write <kind> <root> <rel> [before]: queues the write for
# record_pending, unless <root> files with no tracked home.
pend_write() {
  local home
  ledger_home_to home "$2" || return 0
  PEND_KIND+=("$1")
  PEND_ROOT+=("$2")
  PEND_REL+=("$3")
  PEND_HOME+=("$home")
  PEND_SNAP+=(1)
  PEND_BLOB+=("")
  PEND_SEEN+=(0)
  PEND_BEFORE+=("${4:-}")
}

# is_binary <file> -> 0 when a NUL is in its first 8000 bytes, git's own
# test: its diff has no `+` lines to judge. A builtin read under the C locale
# counts bytes, with no process per file.
is_binary() {
  # shellcheck disable=SC2034 # LC_ALL is read by bash itself
  local LC_ALL=C _ib
  IFS= read -r -d '' -n 8000 _ib 2>/dev/null < "$1" && [ "${#_ib}" -lt 8000 ]
}

# snapshot_pending: for a Bash write, the snapshot of each pending file the
# Stop gate's content checks judge: its blob id as it is now, written to its
# root's object store ("" when the file does not exist). Not judged: a file
# the checks do not cover (absolute_paths_scope: the frontmatter and
# reuse-audit files are docs too; a gitignored file) or a binary. Every other
# file needs a before/after pair whatever its size, or its baseline falls
# back to HEAD (which a commit moves) and its after side to the file at Stop
# (which holds other sessions' lines). When git cannot write the blob (a
# read-only object store), a copy beside the session file stands in for it,
# as "kept:<id>" (session_keep); PEND_SNAP 2 when neither could be written.
# Per root, one git call asks which files are ignored and one hashes them
# all, so a command writing many files does not pay processes per file
# (#277). A path holding a newline cannot ride --stdin-paths: the root's
# files are then hashed one by one.
snapshot_pending() {
  local i j k root ai rel x id ignored done_roots=$'\n' one
  local -a idx hash_idx ids
  [ "$SNAPSHOTS" = 1 ] || return 0
  for ((i = 0; i < ${#PEND_ROOT[@]}; i++)); do
    root="${PEND_ROOT[$i]}"
    case "$done_roots" in *$'\n'"$root"$'\n'*) continue ;; esac
    done_roots="$done_roots$root"$'\n'
    idx=()
    for ((j = i; j < ${#PEND_ROOT[@]}; j++)); do
      [ "${PEND_ROOT[$j]}" != "$root" ] || idx+=("$j")
    done
    root_ai_to ai "$root"
    ignored=$'\034'
    while IFS= read -r -d '' x; do
      ignored="$ignored$x"$'\034'
    done < <(for j in "${idx[@]}"; do printf '%s\0' "${PEND_REL[$j]}"; done \
      | git -C "$root" check-ignore --stdin -z 2>/dev/null || true)
    hash_idx=()
    one=0
    for j in "${idx[@]}"; do
      rel="${PEND_REL[$j]}"
      case "$ignored" in *$'\034'"$rel"$'\034'*) continue ;; esac
      absolute_paths_scope_unignored "$root" "$rel" "$ai" || continue
      if [ ! -f "$root/$rel" ]; then
        PEND_SNAP[j]=0
        continue
      fi
      ! is_binary "$root/$rel" || continue
      case "$rel" in *$'\n'*) one=1 ;; esac
      hash_idx+=("$j")
    done
    [ "${#hash_idx[@]}" -gt 0 ] || continue
    ids=()
    if [ "$one" = 0 ]; then
      while IFS= read -r id; do
        ids+=("$id")
      done < <(for j in "${hash_idx[@]}"; do printf '%s\n' "${PEND_REL[$j]}"; done \
        | git -C "$root" hash-object -w --stdin-paths 2>/dev/null || true)
    fi
    for ((k = 0; k < ${#hash_idx[@]}; k++)); do
      j="${hash_idx[$k]}"
      rel="${PEND_REL[$j]}"
      if [ "${#ids[@]}" -eq "${#hash_idx[@]}" ] && [ -n "${ids[$k]}" ]; then
        id="${ids[$k]}"
      elif ! id=$(git -C "$root" hash-object -w -- "$rel" 2>/dev/null) \
          && ! id=$(session_keep "${PEND_HOME[$j]}" "$SESSION_ID" "$root" "$rel"); then
        PEND_SNAP[j]=2
        continue
      fi
      PEND_SNAP[j]=0
      PEND_BLOB[j]="$id"
    done
  done
}

# mark_seen_pending: sets PEND_SEEN for each write without a snapshot that
# the session already recorded since its root's last `verified` event
# (session_seen), with one read of each home's file.
mark_seen_pending() {
  local i j home done_homes=$'\n' cands
  local -a map fields
  for ((i = 0; i < ${#PEND_ROOT[@]}; i++)); do
    [ "${PEND_SNAP[$i]}" = 1 ] || continue
    home="${PEND_HOME[$i]}"
    case "$done_homes" in *$'\n'"$home"$'\n'*) continue ;; esac
    done_homes="$done_homes$home"$'\n'
    map=()
    fields=()
    for ((j = i; j < ${#PEND_ROOT[@]}; j++)); do
      if [ "${PEND_SNAP[$j]}" != 1 ] || [ "${PEND_HOME[$j]}" != "$home" ]; then
        continue
      fi
      map+=("$j")
      fields+=("${PEND_KIND[$j]}" "${PEND_ROOT[$j]}" "${PEND_REL[$j]}" "$AGENT_ID" "$VIA")
    done
    cands=$(jq -nc '$ARGS.positional | [range(0; length; 5) as $i | .[$i:$i + 5]]' --args "${fields[@]}") || continue
    while IFS= read -r j; do
      case "$j" in ''|*[!0-9]*) continue ;; esac
      PEND_SEEN[${map[$j]}]=1
    done < <(session_seen_many "$home" "$SESSION_ID" "$cands")
  done
}

# record_pending: the pending writes as events, in target order. PreToolUse:
# a `pre` event for each snapshot. PostToolUse: a `write` event for each
# file. A Bash write to a file the content checks judge carries its snapshot,
# or "@" when it could be neither hashed nor kept (the Stop gate then reads
# the file as it is), and is recorded every time, since each one is a new
# before/after pair for the Stop gate; when the status diff found it, a
# `pre` event from the capture taken at PreToolUse comes first (the command
# scanner may not have named the file then). Any other write is recorded
# once since its root's last `verified` event.
record_pending() {
  local i
  [ "$VIA" != bash ] || snapshot_pending
  if [ "$PRE" = 1 ]; then
    for ((i = 0; i < ${#PEND_ROOT[@]}; i++)); do
      [ "${PEND_SNAP[$i]}" = 0 ] || continue
      queue_event "${PEND_HOME[$i]}" pre "${PEND_ROOT[$i]}" "${PEND_REL[$i]}" "" "" "${PEND_BLOB[$i]}" 1
    done
  else
    mark_seen_pending
    for ((i = 0; i < ${#PEND_ROOT[@]}; i++)); do
      case "${PEND_SNAP[$i]}" in
        0)
          case "${PEND_BEFORE[$i]}" in
            '') ;;
            -) queue_event "${PEND_HOME[$i]}" pre "${PEND_ROOT[$i]}" "${PEND_REL[$i]}" "" "" "" 1 ;;
            *) queue_event "${PEND_HOME[$i]}" pre "${PEND_ROOT[$i]}" "${PEND_REL[$i]}" "" "" "${PEND_BEFORE[$i]}" 1 ;;
          esac
          queue_event "${PEND_HOME[$i]}" write "${PEND_ROOT[$i]}" "${PEND_REL[$i]}" "${PEND_KIND[$i]}" bash "${PEND_BLOB[$i]}" 1
          ;;
        2) queue_event "${PEND_HOME[$i]}" write "${PEND_ROOT[$i]}" "${PEND_REL[$i]}" "${PEND_KIND[$i]}" bash "@" 1 ;;
        *)
          [ "${PEND_SEEN[$i]}" = 0 ] || continue
          queue_event "${PEND_HOME[$i]}" write "${PEND_ROOT[$i]}" "${PEND_REL[$i]}" "${PEND_KIND[$i]}" "$VIA" "" 0
          ;;
      esac
    done
  fi
  flush_events
}

# target_root <path>: sets ROOT to the checkout holding the file (from its
# nearest existing directory, checkout_root) and REL to its path there;
# fails when it is in none. The last directory's answer is kept.
TR_DIR="" TR_ROOT=""
target_root() {
  local dir="${1%/*}" anchor
  [ -n "$dir" ] || dir=/
  if [ "$dir" != "$TR_DIR" ] || [ -z "$TR_DIR" ]; then
    TR_DIR="$dir" TR_ROOT=""
    if anchor=$(existing_dir "$dir"); then
      TR_ROOT=$(checkout_root "$anchor") || TR_ROOT=""
    fi
  fi
  [ -n "$TR_ROOT" ] || return 1
  ROOT="$TR_ROOT"
  case "$1" in
    "$ROOT"/*) REL="${1#"$ROOT"/}" ;;
    *) return 1 ;;
  esac
}

# script_word <word...> -> the index of the word that names the program a
# command runs, past `env` (its options and NAME=value assignments),
# `command` and a `bash`/`sh` interpreter with its options. Fails when the
# command runs no file: `bash -c`, `command -v`, `env -S`.
script_word() {
  local i=0 w n=$#
  local -a words=("$@")
  while [ "$i" -lt "$n" ]; do
    w=${words[$i]##*/}
    case "$w" in
      env)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in
            --) i=$((i + 1)); break ;;
            -u|-C|--unset|--chdir) i=$((i + 2)) ;;
            -S*|--split-string*) return 1 ;;
            -*) i=$((i + 1)) ;;
            [A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        while [ "$i" -lt "$n" ] && [[ "${words[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
          i=$((i + 1))
        done
        ;;
      command)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in
            --) i=$((i + 1)); break ;;
            -p) i=$((i + 1)) ;;
            -*) return 1 ;;
            *) break ;;
          esac
        done
        ;;
      bash|sh)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in
            --) i=$((i + 1)); break ;;
            -o|+o|-O|+O) i=$((i + 2)) ;;
            --*) i=$((i + 1)) ;;
            -*c*) return 1 ;;
            -*o|+*o|-*O|+*O) i=$((i + 2)) ;;
            -*|+*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        printf '%s\n' "$i"
        return 0
        ;;
      *)
        printf '%s\n' "$i"
        return 0
        ;;
    esac
  done
  return 1
}

# implement_requests -> `start` or `stop` for each segment that
# runs session-event.sh implement <state>, the script called by any path,
# directly or through bash, sh, env or command.
implement_requests() {
  local line kline seg kseg i w
  local -a words kwords decoded
  while IFS= read -r line && IFS= read -r kline <&3; do
    strip_command_prefix_to seg "${line#*$'\t'}"
    strip_command_prefix_to kseg "${kline#*$'\t'}"
    # Split as `read -a` does, without a here-string per segment (a temp
    # file each in bash 3.2) and with no glob expansion.
    set -f
    # shellcheck disable=SC2206 # word splitting is the point; globbing is off
    words=($seg) kwords=($kseg)
    set +f
    if [ "${#kwords[@]}" -lt 3 ] || [ "${#kwords[@]}" -ne "${#words[@]}" ]; then
      continue
    fi
    decoded=()
    for w in "${kwords[@]}"; do
      decode_word_to w "$w"
      decoded+=("$w")
    done
    i=$(script_word "${decoded[@]}") || continue
    [ $((i + 2)) -lt "${#words[@]}" ] || continue
    [ "${decoded[$i]##*/}" = session-event.sh ] || continue
    [ "${words[$((i + 1))]}" = implement ] || continue
    case "${words[$((i + 2))]}" in start|stop) printf '%s\n' "${words[$((i + 2))]}" ;; esac
  done <<< "$SCAN_PLAIN" 3<<< "$SCAN_KEEP"
  return 0
}

# write_session_log <checkout root> <path>...: creates or extends the live log
# beside the session's state file (session_home and session_dir in
# lib/session-event.sh decide where both live), a myspec project only.
write_session_log() {
  local raw_root="$1" repo_root state_dir active_file worktree topic_seed started short_id p rel entry
  shift

  # raw_root is the repository root as seen from the edit (a linked worktree
  # resolves to itself); repo_root is the session home: the primary checkout,
  # a submodule's superproject, or a bare repository's common dir.
  if ! repo_root="$(session_home "$raw_root")"; then
    repo_root="$raw_root"
  fi

  # Logs only in a myspec-managed project: an edit in an unrelated repository
  # must not grow a stray state tree there.
  [ -f "$repo_root/.myspec.json" ] || [ -f "$raw_root/.myspec.json" ] || return 0

  state_dir=$(session_dir "$repo_root")
  active_file="$state_dir/${SESSION_ID}.md"

  # Worktree marker: the edit resolved to a linked worktree. The basename is
  # portable (no absolute path) and lets session-clean's liveness gate match
  # the session against `git worktree list`. Main checkout, submodule:
  # empty (gate uses mtime).
  worktree=""
  if checkout_facts "$raw_root" && [ "$CF_LINKED" = 1 ]; then
    worktree=$(basename "$raw_root")
  fi

  if [ ! -f "$active_file" ]; then
    mkdir -p "$state_dir"

    # Topic seed: parent directory name of the first edited file
    topic_seed=$(basename "$(dirname "$1")" 2>/dev/null || echo "auto")
    if [ -z "$topic_seed" ] || [ "$topic_seed" = "." ]; then
      topic_seed="auto"
    fi
    started=$(date '+%Y-%m-%d %H:%M')
    short_id="${SESSION_ID:0:8}"

    cat > "$active_file" <<SESSION
---
session_id: $SESSION_ID
topic: "auto:$topic_seed"
feature: ""
mode: implementation
started: $started
status: active
auto_created: true
worktree: "$worktree"
---

# Session $short_id — auto:$topic_seed

## Context
$CONTEXT Refine topic, feature, and mode as the work crystallizes.

## Log

| # | Action | File(s) | Result | Attempt | Type | Note |
|---|--------|---------|--------|---------|------|------|

## Insights

## Outcome
<!-- Fill on /myspec:session-complete -->
- **What worked**:
- **Root cause**:
- **Key insights**:

## Extraction Candidates
<!-- Fill on /myspec:session-complete -->

## Files touched
<!-- Appended by mark-code-changed.sh; this is how a skill recognises its own session -->
SESSION
  fi

  # Append every code path once. `## Files touched` is the LAST section of
  # every log this hook or the session-log template creates, so appending is
  # a plain `>>`. A log without it is not backfilled (the 1.x shape is gone
  # since 3.0): the paths still land at its end.
  for p in "$@"; do
    case "$p" in
      "$repo_root"/*) rel="${p#"$repo_root"/}" ;;
      *) rel="$p" ;;
    esac
    # shellcheck disable=SC2016 # literal backticks: a markdown code span
    entry=$(printf -- '- `%s`%s' "$rel" "$AGENT_TAG")
    # A whole-line match: the controller's own line and a subagent's tagged
    # line for the same path are both kept.
    if ! grep -qxF -- "$entry" "$active_file"; then
      printf '%s\n' "$entry" >> "$active_file"
    fi
  done
}

# The status diff (lib/status-diff.sh, #276): at PreToolUse each checkout a
# Bash call reaches is captured, under
# <session dir>/<session_id>.bash/<tool_use_id>.<n> in the cwd's home; at
# PostToolUse (or PostToolUseFailure) what changed since is added to what the
# command scanner read. The scanner stays for what the diff cannot see: a
# gitignored file, a project without git, a call with no capture.

# diff_keep <root> <rel> -> 0 for a file the content checks would judge, so
# its capture is written to the object store as a before side. Called by
# name from status_capture.
# shellcheck disable=SC2317,SC2329
diff_keep() {
  local ai
  [ "$SNAPSHOTS" = 1 ] || return 1
  # "/" stands for an aiDir no path is under: a doc kind, .claude/ or docs/
  # is in scope without it, so the settings reader runs only for a file
  # that needs the aiDir to decide.
  if ! absolute_paths_scope_unignored "$1" "$2" /; then
    [ -f "$1/.myspec.json" ] || return 1
    root_ai_to ai "$1"
    absolute_paths_scope_unignored "$1" "$2" "$ai" || return 1
  fi
  ! is_binary "$1/$2"
}

# diff_log <start|end>: appends this call to the repository's Bash call log,
# <session dir>/bash-calls.log, one short O_APPEND line (`<epoch> <event>
# <session_id> <tool_use_id>`), so concurrent sessions' lines never
# interleave. The order of the lines is the order of the calls, with no clock
# to compare: that is what diff_overlap reads. Past 256 KiB the log becomes
# bash-calls.log.old (a rename, atomic) and a new one starts; then, too,
# captures older than an hour go (calls whose PostToolUse never came), so
# the sweep costs no process on every call. <epoch> is NOW.
diff_log() {
  local log="$BASH_DIRS/bash-calls.log" size
  if [ "$1" = start ] && [ -f "$log" ]; then
    size=$(wc -c < "$log" 2>/dev/null || printf 0)
    if [ "${size// /}" -gt 262144 ]; then
      mv -f -- "$log" "$log.old" 2>/dev/null || true
      find "${BASH_DIRS:?}" -mindepth 2 -maxdepth 2 -path '*.bash/*' -mmin +60 -exec rm -f {} + 2>/dev/null || true
    fi
  fi
  printf '%s %s %s %s\n' "$NOW" "$1" "$SESSION_ID" "$TOOL_USE_ID" >> "$log" 2>/dev/null || true
}

# diff_capture <dir>...: logs the call's start, then captures the checkout of
# each directory that files with a tracked home, once each, as
# <CALL>.0, <CALL>.1, ... in the session's .bash directory (made once per
# session, not per call).
diff_capture() {
  local d root home n=0 done_roots=$'\n' done_dirs=$'\n'
  [ -d "${CALL%/*}" ] || mkdir -p "${CALL%/*}" 2>/dev/null || return 0
  diff_log start
  for d in "$@"; do
    # Each directory once: a command writing many files in one directory
    # asks git about it once.
    case "$done_dirs" in *$'\n'"$d"$'\n'*) continue ;; esac
    done_dirs="$done_dirs$d"$'\n'
    if [ "$d" = "$CWD_ROOT" ]; then
      root="$CWD_ROOT"
    else
      d=$(existing_dir "$d") || continue
      root=$(checkout_root "$d") || continue
    fi
    case "$done_roots" in *$'\n'"$root"$'\n'*) continue ;; esac
    done_roots="$done_roots$root"$'\n'
    ledger_home_to home "$root" || continue
    if ! status_capture "$root" diff_keep > "${CALL:?}.$n" 2>/dev/null; then
      rm -f -- "${CALL:?}.$n"
      continue
    fi
    n=$((n + 1))
  done
}

# diff_overlap -> 0 when another session ran a Bash call in this repository
# while this one ran, read from the call log (diff_log): a line of another
# session after this call's start, or a call of another session still open
# when this one started (opened in the last 15 minutes; an older one never
# finished). Its writes would be in this call's diff, so the diff alone then
# names nothing (the scanner's targets still count). Also 0 when this call's
# start is not in the log: nothing can be told. A subagent shares its
# parent's session id, so its calls are this session's own.
diff_overlap() {
  local log="$BASH_DIRS/bash-calls.log"
  { cat -- "$log.old" "$log" 2>/dev/null || true; } | awk -v sid="$SESSION_ID" -v id="$TOOL_USE_ID" -v now="$NOW" '
    $3 == sid && $4 == id && $2 == "start" {
      found = 1
      for (k in open) if (open[k] >= now - 900) busy = 1
      next
    }
    $3 == sid { next }
    found && ($2 == "start" || $2 == "end") { busy = 1; next }
    $2 == "start" { open[$3 " " $4] = $1 }
    $2 == "end" { delete open[$3 " " $4] }
    END { exit (found && !busy) ? 1 : 0 }'
}

# diff_targets: adds each file the status diff found to TARGETS (and its
# content before the call to DIFF_PATHS / DIFF_BEFORE), then closes the call:
# its capture files go, and its end goes to the call log.
DIFF_PATHS=()
DIFF_BEFORE=()
diff_targets() {
  local cap rel before p
  [ -f "$CALL.0" ] || return 0
  if ! diff_overlap; then
    for cap in "$CALL".[0-9]*; do
      [ -f "$cap" ] || continue
      while IFS= read -r -d '' p && IFS= read -r -d '' rel && IFS= read -r -d '' before; do
        p="$p/$rel"
        case "$SEEN" in
          *$'\n'"$p"$'\n'*) ;;
          *)
            SEEN="$SEEN$p"$'\n'
            TARGETS+=("$p")
            ;;
        esac
        DIFF_PATHS+=("$p")
        DIFF_BEFORE+=("$before")
      done < <(status_changes "$cap" | diff_with_root "$cap")
    done
  fi
  rm -f -- "${CALL:?}".[0-9]*
  diff_log end
}

# diff_with_root <capture file>: status_changes' pairs on stdin, each
# prefixed with the capture's root, as NUL-separated triples.
diff_with_root() {
  local root rel before
  IFS= read -r -d '' root < "$1" || return 0
  while IFS= read -r -d '' rel && IFS= read -r -d '' before; do
    printf '%s\0%s\0%s\0' "$root" "$rel" "$before"
  done
}

# diff_before <path> -> the content before the call the status diff found
# for <path>, "" when it did not find the write.
diff_before() {
  local i
  for ((i = 0; i < ${#DIFF_PATHS[@]}; i++)); do
    if [ "${DIFF_PATHS[$i]}" = "$1" ]; then
      printf '%s' "${DIFF_BEFORE[$i]}"
      return 0
    fi
  done
}

payload_parse "$(cat)" FILE_PATH='.tool_input.file_path // .tool_input.notebook_path' \
  COMMAND=.tool_input.command SESSION_ID=.session_id HOOK_EVENT='.hook_event_name | strings' \
  AGENT_ID='.agent_id | strings' AGENT_TYPE='.agent_type | strings' CWDS="$HOOK_CWDS" \
  TOOL_USE_ID='.tool_use_id | strings'

[ -n "$SESSION_ID" ] || exit 0

# A subagent's events carry agent_id (and agent_type); the main session's do
# not. Only id-safe characters are kept, so a value can't break a ledger line
# or the log's markdown.
AGENT_ID=${AGENT_ID//[!A-Za-z0-9._:-]/}
AGENT_TYPE=${AGENT_TYPE//[!A-Za-z0-9._:-]/}
AGENT_TAG=""
if [ -n "$AGENT_ID" ]; then
  AGENT_TAG=" (subagent $AGENT_ID${AGENT_TYPE:+, $AGENT_TYPE})"
fi

# The directory relative paths are taken from: the payload's cwd, else the
# hook's own.
PAYLOAD_CWD=$(first_dir "$CWDS") || PAYLOAD_CWD="$PWD"
BASE_DIR=$(physical_dir "$PAYLOAD_CWD")

# The cwd's checkout and its tracked session home, for a write into a
# nested untracked clone (ledger_home_to) and for the status diff's
# captures. Empty when the cwd is in no tracked project.
CWD_ROOT="" CWD_HOME=""
# Asked here, in this shell, so the subshells below find the answer cached.
checkout_facts "$BASE_DIR" || true
if CWD_ROOT=$(checkout_root "$BASE_DIR") && CWD_HOME=$(session_home "$CWD_ROOT") \
    && session_tracked_at "$CWD_HOME" "$CWD_ROOT"; then
  # ledger_home_to's answer for the cwd's checkout, without asking again.
  LH_ROOT="$CWD_ROOT" LH_HOME="$CWD_HOME" LH_RC=0
else
  CWD_ROOT="" CWD_HOME=""
fi

TARGETS=()
SEEN=$'\n'
CONTEXT=""
# PreToolUse (Bash only): snapshot the targets, record nothing else.
PRE=0
[ "$HOOK_EVENT" != PreToolUse ] || PRE=1
VIA=tool

if [ -n "$FILE_PATH" ]; then
  [ "$PRE" = 0 ] || exit 0
  TARGETS=("$(physical_path "$FILE_PATH" "$BASE_DIR")")
  CONTEXT="Auto-created on first code edit at \`$FILE_PATH\`."
elif [ -n "$COMMAND" ]; then
  # The scanner ships beside hook-core.
  [ -f "$HOOK_LIB/command-scan.sh" ] || exit 0
  # shellcheck source=lib/command-scan.sh
  . "$HOOK_LIB/command-scan.sh"

  VIA=bash
  # feature-implement's orchestration state, recorded with this payload's
  # session id in the cwd's checkout, once (at PostToolUse).
  if [ "$PRE" = 0 ] && [[ "$COMMAND" == *session-event.sh*implement* ]] && IMPLEMENT_HOME=$(session_home "$BASE_DIR") \
      && session_tracked_at "$IMPLEMENT_HOME" "$(checkout_root "$BASE_DIR" || true)"; then
    scan_command keep
    while IFS= read -r state; do
      session_append "$IMPLEMENT_HOME" "$SESSION_ID" "{\"t\":\"implement\",\"state\":\"$state\"}" || true
    done < <(implement_requests)
  fi

  # Cheap gate before the full scan: a write verb or a redirect at some
  # segment, or a `cd` (it brings another checkout into the status diff's
  # reach). Most Bash calls skip the scan.
  WRITE_PATTERNS=(
    '^([^[:space:]]*/)?(sed|perl|tee|mv|cp|rsync|install|patch)([[:space:]]|$)'
    '>{1,2}[[:space:]]*[^&[:space:]]'
    '^cd([[:space:]]|$)'
  )
  # Each file once, in first-seen order: a command that appends to the same
  # file in every statement writes it once as far as the ledger is concerned
  # (one snapshot before, one after). REACH: the directories whose
  # checkouts the status diff captures.
  REACH=()
  [ -z "$CWD_ROOT" ] || REACH=("$CWD_ROOT")
  if segment_matches "${WRITE_PATTERNS[@]}"; then
    scan_command keep
    while IFS= read -r p; do
      case "$p" in
        '') continue ;;
        cd:*) REACH+=("${p#cd:}"); continue ;;
      esac
      case "$SEEN" in *$'\n'"$p"$'\n'*) continue ;; esac
      SEEN="$SEEN$p"$'\n'
      TARGETS+=("$p")
      REACH+=("${p%/*}")
    done < <(bash_write_targets)
  fi

  # The status diff needs the call id that pairs PreToolUse with PostToolUse,
  # a tracked cwd to keep its captures in, and the lib.
  TOOL_USE_ID=${TOOL_USE_ID//[!A-Za-z0-9_-]/}
  if [ -n "$TOOL_USE_ID" ] && [ -n "$CWD_HOME" ] && [ -f "$HOOK_LIB/status-diff.sh" ] \
      && session_file "$CWD_HOME" "$SESSION_ID" >/dev/null; then
    # shellcheck source=lib/status-diff.sh
    . "$HOOK_LIB/status-diff.sh"
    BASH_DIRS=$(session_dir "$CWD_HOME")
    CALL="$BASH_DIRS/$SESSION_ID.bash/$TOOL_USE_ID"
    NOW=$(date +%s)
    if [ "$PRE" = 1 ]; then
      diff_capture ${REACH[@]+"${REACH[@]}"}
    else
      diff_targets
    fi
  fi

  # Parameter expansion, not `printf | tr | head -c`: head exits after 120
  # bytes, tr dies of SIGPIPE on a long command (a heredoc write), and under
  # pipefail plus set -e the hook exited 141 before writing the ledger (#249).
  CONTEXT_CMD=${COMMAND:0:120}
  CONTEXT_CMD=${CONTEXT_CMD//$'\n'/ }
  CONTEXT="Auto-created on a Bash write: \`$CONTEXT_CMD\`."
else
  exit 0
fi

[ "${#TARGETS[@]}" -gt 0 ] || exit 0

CODE_ROOTS=()
CODE_PATHS=()

for p in "${TARGETS[@]}"; do
  # PostToolUse runs after the write, so the parent normally exists; the
  # nearest existing directory keeps resolution working when it does not.
  target_root "$p" || continue
  root="$ROOT" rel="$REL"
  if [ "$PRE" = 1 ]; then
    pend_write "" "$root" "$rel"
    continue
  fi
  load_settings "$root"
  kind='file'
  if [[ "$p" =~ $CODE_RE ]] && ! ignored "$rel"; then
    kind=code
    CODE_ROOTS+=("$root")
    CODE_PATHS+=("$p")
  fi
  pend_write "$kind" "$root" "$rel" "$(diff_before "$p")"
done
record_pending
[ "$PRE" = 0 ] || exit 0

# One log per checkout the code writes landed in, in first-seen order.
DONE_ROOTS=$'\n'
for ((i = 0; i < ${#CODE_ROOTS[@]}; i++)); do
  root="${CODE_ROOTS[$i]}"
  case "$DONE_ROOTS" in
    *$'\n'"$root"$'\n'*) continue ;;
  esac
  DONE_ROOTS="$DONE_ROOTS$root"$'\n'
  ROOT_PATHS=()
  for ((j = i; j < ${#CODE_ROOTS[@]}; j++)); do
    if [ "${CODE_ROOTS[$j]}" = "$root" ]; then
      ROOT_PATHS+=("${CODE_PATHS[$j]}")
    fi
  done
  write_session_log "$root" "${ROOT_PATHS[@]}"
done

exit 0
