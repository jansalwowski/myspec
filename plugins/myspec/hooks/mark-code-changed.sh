#!/usr/bin/env bash
# mark-code-changed.sh
# PostToolUse hook (Write|Edit and Bash matchers) — records every file this
# session writes, and keeps the session's live log.
#
# Ledger: /tmp/.myspec-session-writes-<session_id>, one line per written file:
# `<code|file><TAB><checkout root><TAB><repo-relative path>`. The root is the
# physical toplevel of the checkout holding the file, so a write in another
# repository or in a linked worktree never arms this checkout.
# verify-before-stop.sh runs its checks only when a `code` line for its
# checkout is newer than its last `verified` line. It reads every line as the
# list of files this session wrote when it decides whose failure it is. That is
# why non-code writes are recorded too: a config file this session edited is
# its own. It replaces the empty /tmp/.myspec-code-changed-<session_id> marker,
# which was deleted after every run and so lost that list.
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
# ledger stays keyed by session_id, so a subagent's write arms the parent's
# Stop gate. Its lines gain a fourth field, the agent_id, which the Stop
# hook's three-field parser ignores; a main-session line is unchanged. In the
# log, a subagent's path is tagged `(subagent <agent_id>[, <agent_type>])`, so
# session-complete can tell the controller's own edits from delegated ones.
#
# Settings (#231, docs/project-settings-design.md), read through
# lib/myspec-config.sh from the checkout that holds the written file:
# hooks.markCodeChanged.extraCodeExtensions adds to CODE_EXT, and a write to a
# path matching a hooks.markCodeChanged.ignorePaths glob (lib/glob-regex.sh,
# the same semantics as checks[].paths) is recorded as
# `file`, never `code`, so it does not arm the gate by itself. A default
# extension cannot be removed; ignoring the paths that hold it is the lever.

set -euo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)

CODE_EXT='(ts|tsx|vue|js|jsx|mjs|cjs|mts|cts|py|rb|go|java|php|rs|cs|swift|kt|sh|bash|graphql|gql)'
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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
  local root="$1" src cfg json ext exts="" g i re
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
    cfg=""
    for cand in "$SCRIPT_DIR/../lib/myspec-config.sh" "$src/.claude/lib/myspec-config.sh"; do
      if [ -f "$cand" ]; then
        cfg="$cand"
        break
      fi
    done
    if [ -n "$cfg" ] && json=$(bash "$cfg" get hooks.markCodeChanged --root "$src"); then
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
      # The globs compile through lib/glob-regex.sh, the one compiler the
      # Stop hook's `paths` and provisioning's `clean` use too.
      if ! declare -F glob_regex >/dev/null && [ -f "$(dirname "$cfg")/glob-regex.sh" ]; then
        # shellcheck source=/dev/null
        . "$(dirname "$cfg")/glob-regex.sh"
      fi
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        if ! declare -F glob_regex >/dev/null; then
          echo "mark-code-changed: ignoring hooks.markCodeChanged.ignorePaths: lib/glob-regex.sh was not found next to $cfg" >&2
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

# Nearest existing directory at or above the edited file. PostToolUse runs after
# the write, so the parent normally exists; walking up keeps resolution working
# when it does not.
anchor_dir_for_file() {
  local dir
  dir="$(dirname "$1")"

  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ] && [ ! -d "$dir" ]; do
    dir="$(dirname "$dir")"
  done

  if [ -d "$dir" ]; then
    printf '%s\n' "$dir"
    return 0
  fi

  return 1
}

# Pin a git toplevel to the primary worktree. A linked worktree is its own
# toplevel, so `--show-toplevel` inside <worktreeRoot>/<slug> returns the
# worktree; the parent of the common git dir is the main checkout. The two
# already agree in the primary worktree, so this is a no-op there.
main_worktree_root() {
  local path="$1"
  local common_git_dir

  common_git_dir=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1

  # Submodules and bare repos have a common dir that is not named `.git`; for
  # those the plain toplevel is already the correct root.
  if [ "$(basename "$common_git_dir")" = ".git" ]; then
    (cd "$(dirname "$common_git_dir")" && pwd -P)
    return
  fi

  common_git_dir=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  (cd "$common_git_dir" && pwd -P)
}

# checkout_root <existing dir> -> the physical root of the checkout holding it:
# its git toplevel, or, in a project without git, the nearest directory with a
# .myspec.json. Fails when there is neither: nothing there to verify.
checkout_root() {
  local dir="$1" top
  if top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    (cd "$top" && pwd -P)
    return
  fi
  dir=$(cd "$dir" && pwd -P) || return 1
  while :; do
    if [ -f "$dir/.myspec.json" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" != "/" ] || return 1
    dir=$(dirname "$dir")
  done
}

# physical_path <path> -> absolute, with its directory resolved (symlinks,
# `..`). A relative path is taken from BASE_DIR: the payload cwd, moved by any
# literal `cd` earlier in a Bash command.
physical_path() {
  local p="$1" dir
  case "$p" in
    /*) ;;
    *) p="$BASE_DIR/$p" ;;
  esac
  dir=$(dirname "$p")
  if [ -d "$dir" ]; then
    dir=$(cd "$dir" && pwd -P) || return 1
    printf '%s/%s\n' "${dir%/}" "$(basename "$p")"
  else
    printf '%s\n' "$p"
  fi
}

# emit_target <word> [must-exist] [no-glob] -> the physical path of a written
# file named by <word>. Placeholders for quoted spans (Q), variables,
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
  p=$(physical_path "$w") || return 0
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
        dest=$(physical_path "$last") || continue
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

# ledger_add <kind> <root> <rel>: appends the line unless it is already there
# since the root's last `verified` line. A subagent's line ends in a fourth
# field, its agent_id; the Stop hook reads only the first three.
ledger_add() {
  local line
  line=$(printf '%s\t%s\t%s' "$1" "$2" "$3")
  if [ -n "$AGENT_ID" ]; then
    line="$line"$'\t'"$AGENT_ID"
  fi
  if [ -f "$LEDGER" ] && L="$line" R="$2" awk -F'\t' '
      $1 == "verified" && $2 == ENVIRON["R"] { seen = 0; next }
      $0 == ENVIRON["L"] { seen = 1 }
      END { exit !seen }' "$LEDGER"; then
    return 0
  fi
  printf '%s\n' "$line" >> "$LEDGER"
}

# write_session_log <checkout root> <path>...: creates or extends the live log
# in the primary checkout of <checkout root>, a myspec project only.
write_session_log() {
  local raw_root="$1" repo_root state_dir active_file worktree topic_seed started short_id p rel entry
  shift

  # raw_root is the repository root as seen from the edit (a linked worktree
  # resolves to itself); repo_root is pinned to the primary checkout, where the
  # session store lives.
  if ! repo_root="$(main_worktree_root "$raw_root")"; then
    repo_root="$raw_root"
  fi

  # Logs only in a myspec-managed project: an edit in an unrelated repository
  # must not grow a stray state tree there.
  [ -f "$repo_root/.myspec.json" ] || return 0

  state_dir="$repo_root/.claude/state/sessions"
  active_file="$state_dir/${SESSION_ID}.md"

  # Worktree marker: the edit resolved to a linked worktree when the raw root
  # differs from the pinned primary checkout. The basename is portable (no
  # absolute path) and lets session-clean's liveness gate match the session
  # against `git worktree list`. Main checkout: empty (gate uses mtime).
  worktree=""
  if [ "$raw_root" != "$repo_root" ]; then
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

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

[ -n "$SESSION_ID" ] || exit 0

# A subagent's events carry agent_id (and agent_type); the main session's do
# not. Only id-safe characters are kept, so a value can't break a ledger line
# or the log's markdown.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty | strings' 2>/dev/null | tr -cd 'A-Za-z0-9._:-')
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty | strings' 2>/dev/null | tr -cd 'A-Za-z0-9._:-')
AGENT_TAG=""
if [ -n "$AGENT_ID" ]; then
  AGENT_TAG=" (subagent $AGENT_ID${AGENT_TYPE:+, $AGENT_TYPE})"
fi

# The directory relative paths are taken from: the first cwd the payload
# carries that exists, else the hook's own.
PAYLOAD_CWD=""
while IFS= read -r candidate; do
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    PAYLOAD_CWD="$candidate"
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
[ -n "$PAYLOAD_CWD" ] || PAYLOAD_CWD="$PWD"
BASE_DIR=$(cd "$PAYLOAD_CWD" && pwd -P)

TARGETS=()
CONTEXT=""

if [ -n "$FILE_PATH" ]; then
  TARGETS=("$(physical_path "$FILE_PATH")")
  CONTEXT="Auto-created on first code edit at \`$FILE_PATH\`."
elif [ -n "$COMMAND" ]; then
  CWD_ROOT=$(git -C "$PAYLOAD_CWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PAYLOAD_CWD")
  LIB=""
  for cand in "$SCRIPT_DIR/../lib/command-scan.sh" "$CWD_ROOT/.claude/lib/command-scan.sh" "$CWD_ROOT/lib/command-scan.sh"; do
    if [ -f "$cand" ]; then
      LIB="$cand"
      break
    fi
  done
  [ -n "$LIB" ] || exit 0

  # shellcheck source=/dev/null
  . "$LIB"

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

LEDGER="/tmp/.myspec-session-writes-${SESSION_ID}"
CODE_ROOTS=()
CODE_PATHS=()

for p in "${TARGETS[@]}"; do
  anchor=$(anchor_dir_for_file "$p") || continue
  root=$(checkout_root "$anchor") || continue
  case "$p" in
    "$root"/*) rel="${p#"$root"/}" ;;
    *) continue ;;
  esac
  load_settings "$root"
  kind='file'
  if [[ "$p" =~ $CODE_RE ]] && ! ignored "$rel"; then
    kind=code
    CODE_ROOTS+=("$root")
    CODE_PATHS+=("$p")
  fi
  ledger_add "$kind" "$root" "$rel"
done

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
