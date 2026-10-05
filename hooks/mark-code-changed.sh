#!/usr/bin/env bash
# mark-code-changed.sh
# PostToolUse hook (Write|Edit and Bash matchers) — records every file this
# session writes, and keeps the session's live log. Also a PreToolUse hook
# (Bash matcher), where it only snapshots what a Bash write is about to
# change (below).
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
# Write|Edit matcher, so this hook is registered under a Bash matcher too. It
# scans the command (quoted spans and heredoc bodies blanked by
# lib/command-scan.sh) and records only what the command writes: a redirect
# target other than /dev/null or a descriptor, the operands of `tee`, `sed -i`
# and `perl -i`, every operand of `mv`, the destination of `cp`, `rsync` and
# `install`, and the files `patch` edits and writes. Reading, grepping or
# running a file records nothing. A quoted literal path is read; a variable
# path, `git apply`, and a script that writes from inside a heredoc body are
# not seen — run it as `python3 script.py` or use the Write tool.
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
  p=$(physical_path "$w" "$BASE_DIR") || return 0
  if [ -d "$p" ]; then
    return 0
  fi
  if [ -n "${2:-}" ] && [ ! -f "$p" ]; then
    return 0
  fi
  printf '%s\n' "$p"
}

# bash_write_targets <command> -> the files the command writes, one physical
# path per line. Every segment is scanned for redirects; a segment's operands
# count only when a write verb stands at its command position. A literal `cd`
# moves BASE_DIR for the segments after it, and a subshell restores it on exit,
# so `cd <worktree> && echo x > a.ts` records the worktree's file.
# Two scans of the command run in step: the plain one (quoted spans blanked to
# Q) decides what is a verb, an option or a redirect; the `keep` one supplies
# the operand's text, so a quoted literal path ("src/a.ts") resolves too. Both
# split into the same segments and words (lib/command-scan.sh).
bash_write_targets() {
  local line kline sep seg kseg verb word skip i last dest next inplace
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
    seg=$(strip_command_prefix "${line#*$'\t'}")
    [ -n "$seg" ] || continue
    kseg=$(strip_command_prefix "${kline#*$'\t'}")

    read -ra words <<< "$seg"
    read -ra kwords <<< "$kseg"
    [ "${#words[@]}" -gt 0 ] || continue
    if [ "${#kwords[@]}" -ne "${#words[@]}" ]; then
      kwords=("${words[@]}")
    fi
    # A redirect before the command name, or after a brace group or subshell
    # (`{ ...; } >> f` leaves `>> f` as a segment of its own): its target is
    # written whatever runs, and the word after it is the command name.
    while [ "${#words[@]}" -gt 0 ] && [[ "${words[0]}" =~ ^[0-9]*\>{1,2} ]]; do
      if [[ "${words[0]}" =~ ^[0-9]*\>{1,2}$ ]]; then
        [ "${#words[@]}" -lt 2 ] || emit_target "$(decode_word "${kwords[1]}")"
        words=("${words[@]:2}")
        kwords=("${kwords[@]:2}")
      else
        emit_target "$(decode_word "$(printf '%s' "${kwords[0]}" | sed -E 's/^[0-9]*>{1,2}//')")"
        words=("${words[@]:1}")
        kwords=("${kwords[@]:1}")
      fi
    done
    [ "${#words[@]}" -gt 0 ] || continue
    if [ "${words[0]}" = cd ]; then
      if [ "${#words[@]}" -ge 2 ] && next=$(cd "$BASE_DIR" 2>/dev/null && cd "$(decode_word "${kwords[1]}")" 2>/dev/null && pwd -P); then
        BASE_DIR="$next"
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
          emit_target "$(decode_word "${kwords[$((i + 1))]}")"
        fi
        skip=1
        continue
      fi
      if [[ "$word" =~ ^[0-9]*\>{1,2}(.+)$ ]]; then
        emit_target "$(decode_word "$(printf '%s' "${kwords[$i]}" | sed -E 's/^[0-9]*>{1,2}//')")"
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
                emit_target "$(decode_word "${kwords[$((i + 1))]}")"
              fi
              skip=1
              ;;
            patch:-[idprBDFVYzg]|install:-[mogS]) skip=1 ;;
          esac
          continue
          ;;
      esac
      ops+=("$(decode_word "${kwords[$i]}")")
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
        dest=$(physical_path "$last" "$BASE_DIR") || continue
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
  done < <(printf '%s' "$1" | sanitize_command | split_segments) \
       3< <(printf '%s' "$1" | sanitize_command keep | split_segments)
  return 0
}

# ledger_add <kind> <root> <rel>: records the write in the session-state
# file of <root>'s repository, unless the same write is already there since
# the root's last `verified` event. A subagent's event carries its agent_id.
# A checkout nested in the cwd's (a plain clone, not a submodule) whose own
# repository is untracked is filed with the cwd's checkout instead, under its
# own root: the Stop gate verifies such a root through the cwd's checkout
# (NESTED_ROOTS in lib/stop-gate/arm.sh). A checkout counts as tracked when
# its home or the checkout itself has the config: a linked worktree's branch
# can add a stop gate the main checkout does not have yet.
#
# A Bash write (VIA=bash) to a file the content checks cover also carries
# the file's blob after the write (snapshot_blob), and is recorded every
# time, since each one is a new before/after pair for the Stop gate.
ledger_add() {
  local home blob=""
  home=$(ledger_home "$2") || return 0
  if [ "$VIA" = bash ] && blob=$(snapshot_blob "$2" "$3"); then
    session_append "$home" "$SESSION_ID" "$(jq -nc --arg k "$1" --arg r "$2" --arg p "$3" --arg a "$AGENT_ID" --arg b "$blob" \
      '{t: "write", root: $r, rel: $p, kind: $k, via: "bash", blob: $b} + (if $a != "" then {agent: $a} else {} end)')" || true
    return 0
  fi
  session_seen "$home" "$SESSION_ID" "$1" "$2" "$3" "$AGENT_ID" "$VIA" && return 0
  session_append "$home" "$SESSION_ID" "$(jq -nc --arg k "$1" --arg r "$2" --arg p "$3" --arg a "$AGENT_ID" --arg v "$VIA" \
    '{t: "write", root: $r, rel: $p, kind: $k, via: $v} + (if $a != "" then {agent: $a} else {} end)')" || true
}

# ledger_home <root> -> the session home a write in <root> is filed with
# (ledger_add); fails when neither it nor the cwd's checkout is tracked.
ledger_home() {
  local home
  home=$(session_home "$1") || return 1
  if ! session_tracked_at "$home" "$1"; then
    [ -n "$CWD_ROOT" ] && [ -n "$CWD_HOME" ] || return 1
    case "$1/" in
      "$CWD_ROOT"/?*) home="$CWD_HOME" ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$home"
}

# snapshot_blob <root> <rel> -> the blob id of the file as it is now, written
# to <root>'s object store; "" when the file does not exist. Fails, printing
# nothing, for a file the content checks do not cover (absolute_paths_scope:
# the frontmatter and reuse-audit files are docs too) or when git cannot
# hash it (a root without git).
snapshot_blob() {
  [ "$SNAPSHOTS" = 1 ] || return 1
  absolute_paths_scope "$1" "$2" || return 1
  if [ ! -f "$1/$2" ]; then
    printf '\n'
    return 0
  fi
  git -C "$1" hash-object -w -- "$2" 2>/dev/null
}

# snapshot_pre <root> <rel>: records the file's content before a Bash write
# (PreToolUse), as a `pre` event, for a file snapshot_blob covers.
snapshot_pre() {
  local home blob
  home=$(ledger_home "$1") || return 0
  blob=$(snapshot_blob "$1" "$2") || return 0
  session_append "$home" "$SESSION_ID" "$(jq -nc --arg r "$1" --arg p "$2" --arg b "$blob" \
    '{t: "pre", root: $r, rel: $p, blob: $b}')" || true
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

# implement_requests <command> -> `start` or `stop` for each segment that
# runs session-event.sh implement <state>, the script called by any path,
# directly or through bash, sh, env or command.
implement_requests() {
  local line kline seg kseg i w
  local -a words kwords decoded
  while IFS= read -r line && IFS= read -r kline <&3; do
    seg=$(strip_command_prefix "${line#*$'\t'}")
    kseg=$(strip_command_prefix "${kline#*$'\t'}")
    read -ra words <<< "$seg"
    read -ra kwords <<< "$kseg"
    if [ "${#kwords[@]}" -lt 3 ] || [ "${#kwords[@]}" -ne "${#words[@]}" ]; then
      continue
    fi
    decoded=()
    for w in "${kwords[@]}"; do decoded+=("$(decode_word "$w")"); done
    i=$(script_word "${decoded[@]}") || continue
    [ $((i + 2)) -lt "${#words[@]}" ] || continue
    [ "${decoded[$i]##*/}" = session-event.sh ] || continue
    [ "${words[$((i + 1))]}" = implement ] || continue
    case "${words[$((i + 2))]}" in start|stop) printf '%s\n' "${words[$((i + 2))]}" ;; esac
  done < <(printf '%s' "$1" | sanitize_command | split_segments) \
       3< <(printf '%s' "$1" | sanitize_command keep | split_segments)
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

  # Append every code path once. Kept as the LAST section so appending is a
  # plain `>>`; a log created by a 1.x hook gains the section on its first edit.
  if ! grep -q '^## Files touched' "$active_file" 2>/dev/null; then
    printf '\n## Files touched\n' >> "$active_file"
  fi

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

payload_parse "$(cat)" FILE_PATH='.tool_input.file_path // .tool_input.notebook_path' \
  COMMAND=.tool_input.command SESSION_ID=.session_id HOOK_EVENT='.hook_event_name | strings' \
  AGENT_ID='.agent_id | strings' AGENT_TYPE='.agent_type | strings' CWDS="$HOOK_CWDS"

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

TARGETS=()
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
    while IFS= read -r state; do
      session_append "$IMPLEMENT_HOME" "$SESSION_ID" "{\"t\":\"implement\",\"state\":\"$state\"}" || true
    done < <(implement_requests "$COMMAND")
  fi

  # Cheap gate before the full scan: a write verb or a redirect at some
  # segment. Most Bash calls stop here.
  WRITE_PATTERNS=(
    '^([^[:space:]]*/)?(sed|perl|tee|mv|cp|rsync|install|patch)([[:space:]]|$)'
    '>{1,2}[[:space:]]*[^&[:space:]]'
  )
  [ -n "$(find_matching_segment "$COMMAND" "${WRITE_PATTERNS[@]}")" ] || exit 0

  while IFS= read -r p; do
    [ -n "$p" ] && TARGETS+=("$p")
  done < <(bash_write_targets "$COMMAND")

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

# The cwd's checkout and its tracked session home, for a write into a
# nested untracked clone (ledger_add). Empty when the cwd is in no tracked
# project.
CWD_ROOT="" CWD_HOME=""
if CWD_ROOT=$(checkout_root "$BASE_DIR") && CWD_HOME=$(session_home "$CWD_ROOT") \
    && session_tracked_at "$CWD_HOME" "$CWD_ROOT"; then
  :
else
  CWD_ROOT="" CWD_HOME=""
fi

CODE_ROOTS=()
CODE_PATHS=()

for p in "${TARGETS[@]}"; do
  # PostToolUse runs after the write, so the parent normally exists; the
  # nearest existing directory keeps resolution working when it does not.
  anchor=$(existing_dir "$(dirname "$p")") || continue
  root=$(checkout_root "$anchor") || continue
  case "$p" in
    "$root"/*) rel="${p#"$root"/}" ;;
    *) continue ;;
  esac
  if [ "$PRE" = 1 ]; then
    snapshot_pre "$root" "$rel"
    continue
  fi
  load_settings "$root"
  kind='file'
  if [[ "$p" =~ $CODE_RE ]] && ! ignored "$rel"; then
    kind=code
    CODE_ROOTS+=("$root")
    CODE_PATHS+=("$p")
  fi
  ledger_add "$kind" "$root" "$rel"
done
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
