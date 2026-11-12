#!/usr/bin/env bash
# bash-write-targets.sh
# The files a Bash command names as written: redirect targets (`>`, `>>`,
# `>|`), the operands of `tee`, `sed -i`, `perl -i`, `rm`, `touch` and
# `truncate`, every operand of `mv`, the destination of `cp`, `rsync`,
# `install` and `ln`, `dd`'s `of=`, and the files `patch` edits and writes.
# A directory names nothing (`rm -r dir`): the recorder's status diff sees
# what went, and the gate does not. Read
# before the command runs, from its text alone (lib/command-scan.sh), so an
# interpreter's write (`python -c`, `node -e`) or a variable path names
# nothing here.
#
# Sourced by mark-code-changed.sh, which records the writes, and by
# guard-worktree-context.sh, which asks the isolation question before them
# (#348), so the two read the same targets. Needs hook-core.sh and
# command-scan.sh sourced first, and two globals set by the caller:
#   COMMAND    the Bash command
#   BASE_DIR   the physical directory relative paths start from (the
#              payload cwd); a literal `cd` in the command moves it
#
# Public API:
#   bash_may_write                 # 0 when a segment holds a write verb or redirect
#   scan_command [keep]            # fills SCAN_PLAIN (and SCAN_KEEP)
#   segment_matches <ERE>...       # 0 when a segment matches one
#   bash_write_targets             # one physical path per line, plus `cd:<dir>`
#                                  # lines for each literal cd it follows

# Cheap gate before the full scan: a write verb at a command position, or a
# redirect to something other than a descriptor. Most Bash calls skip it.
BASH_WRITE_PATTERNS=(
  '^([^[:space:]]*/)?(sed|perl|tee|mv|cp|rsync|install|patch|rm|touch|ln|truncate|dd)([[:space:]]|$)'
  '>{1,2}[[:space:]]*[^&[:space:]]'
)

bash_may_write() {
  segment_matches "${BASH_WRITE_PATTERNS[@]}"
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
    # compgen -G does not expand a tilde.
    tilde_to w "$w" || return 0
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

# operand_to <var> <keep-scan word> -> decode_word_to into <var>. A word that
# decodes to a leading `~` the shell would not expand, because a character up
# to the first unquoted `/` was quoted ('~/x', "~"/x, ~"/x"), gets a `./` so
# target_path_to keeps it relative. The keep scan marks a quoted span with
# \035 (lib/command-scan.sh).
operand_to() {
  local _op_w _op_pre="${2%%/*}"
  decode_word_to _op_w "$2"
  if [[ "$_op_w" == '~'* ]] && [[ "$2" != '~'* || "$_op_pre" == *$'\035'* ]]; then
    _op_w="./$_op_w"
  fi
  printf -v "$1" '%s' "$_op_w"
}

# tilde_to <var> <word> -> <word> with an unquoted leading `~` or `~/`
# expanded to $HOME, as bash does, into <var>. Returns 1 for a tilde this
# hook cannot resolve: `~user/...` (another home), `~+`, `~-`, or no $HOME.
# Any other word is copied as is.
tilde_to() {
  local _tt_w="$2"
  case "$_tt_w" in
    \~|\~/*)
      [ -n "${HOME:-}" ] || return 1
      _tt_w="$HOME${_tt_w#\~}"
      ;;
    \~*) return 1 ;;
  esac
  printf -v "$1" '%s' "$_tt_w"
}

# Directories target_path_to resolved, for this run: RES_DIRS[i] is
# RES_PHYS[i] physically.
RES_DIRS=()
RES_PHYS=()

# target_path_to <var> <word> -> physical_path "<word>" "$BASE_DIR" into
# <var>, with each directory resolved once per run: a long command names the
# same few directories over and over, and the subshells physical_path spends
# per call cost seconds on one (#277). A path ending in / takes physical_path
# itself. A leading `~` is $HOME (tilde_to; #451), and returns 1 when it names
# a home this hook cannot resolve.
target_path_to() {
  local _tp_p _tp_dir _tp_rest _tp_phys="" _tp_i
  tilde_to _tp_p "$2" || return 1
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
# call (scan_command) and read by bash_may_write, bash_write_targets and
# mark-code-changed.sh's implement_requests alike.
SCAN_PLAIN=""
SCAN_KEEP=""
SCAN_KEPT=0

# scan_command [keep]: fills SCAN_PLAIN from $COMMAND, and SCAN_KEEP too with
# `keep`, each once.
# shellcheck disable=SC2120 # keep is optional; the callers pass it in their own files
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
  # shellcheck disable=SC2119 # the plain scan only
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
# so `cd <worktree> && echo x > a.ts` records the worktree's file. A cd into a
# directory an earlier segment creates (`mkdir -p d && cd d`) follows it too
# (cd_target_to in lib/hook-core.sh), and so does `pushd <dir>`.
# Two scans of the command run in step: the plain one (quoted spans blanked to
# Q) decides what is a verb, an option or a redirect; the `keep` one supplies
# the operand's text, so a quoted literal path ("src/a.ts") resolves too. Both
# split into the same segments and words (lib/command-scan.sh).
bash_write_targets() {
  local line kline sep seg kseg verb word skip i last dest next inplace dw held=""
  # held: BASE_DIR before a cd into a created directory, until the chain ends.
  local -a words kwords ops dws scopes=() helds=()
  # Per command scanned: what its segments create (cd_note_made).
  # shellcheck disable=SC2034 # read by cd_target_to in lib/hook-core.sh
  local -a CD_MADE=() CD_NEW_WT=()
  while IFS= read -r line && IFS= read -r kline <&3; do
    sep="${line%%$'\t'*}"
    case "$sep" in
      '(') scopes+=("$BASE_DIR") helds+=("$held") ;;
      ')')
        if [ "${#scopes[@]}" -gt 0 ]; then
          BASE_DIR="${scopes[${#scopes[@]}-1]}" held="${helds[${#helds[@]}-1]}"
          unset "scopes[${#scopes[@]}-1]" "helds[${#helds[@]}-1]"
        fi
        ;;
    esac
    if ! cd_link "$sep" && [ -n "$held" ]; then
      BASE_DIR="$held" held=""
    fi
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
          operand_to dw "${kwords[1]}"
          emit_target "$dw"
        fi
        words=("${words[@]:2}")
        kwords=("${kwords[@]:2}")
      else
        [[ "${kwords[0]}" =~ ^[0-9]*\>{1,2}(.*)$ ]]
        operand_to dw "${BASH_REMATCH[1]}"
        emit_target "$dw"
        words=("${words[@]:1}")
        kwords=("${kwords[@]:1}")
      fi
    done
    [ "${#words[@]}" -gt 0 ] || continue
    case "${words[0]}" in
      cd|pushd)
        i=1
        while [ "$i" -lt "${#words[@]}" ] && [[ "${words[$i]}" == -?* ]]; do i=$((i + 1)); done
        if [ "$i" -lt "${#words[@]}" ]; then
          decode_word_to dw "${kwords[$i]}"
          # `pushd +N` rotates the stack: no literal directory.
          if [[ "$dw" != +* ]] && cd_target_to next "$BASE_DIR" "$dw"; then
            [ "$CD_LEXICAL" = 0 ] || [ -n "$held" ] || held="$BASE_DIR"
            BASE_DIR="$next"
            # Not a target: a checkout this command reaches, for the status diff.
            printf 'cd:%s\n' "$next"
          fi
        fi
        continue ;;
      mkdir|git)
        if [ "${words[0]}" = mkdir ] || [ "${words[1]:-}" = worktree ]; then
          dws=()
          for ((i = 0; i < ${#kwords[@]}; i++)); do
            decode_word_to dw "${kwords[$i]}"
            dws+=("$dw")
          done
          cd_note_made "$BASE_DIR" "${dws[@]}"
        fi ;;
    esac

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
          operand_to dw "${kwords[$((i + 1))]}"
          emit_target "$dw"
        fi
        skip=1
        continue
      fi
      if [[ "$word" =~ ^[0-9]*\>{1,2}(.+)$ ]]; then
        [[ "${kwords[$i]}" =~ ^[0-9]*\>{1,2}(.*)$ ]]
        operand_to dw "${BASH_REMATCH[1]}"
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
                operand_to dw "${kwords[$((i + 1))]}"
                emit_target "$dw"
              fi
              skip=1
              ;;
            patch:-[idprBDFVYzg]|install:-[mogS]|touch:-[rtd]|truncate:-[sr]|ln:-S) skip=1 ;;
          esac
          continue
          ;;
      esac
      operand_to dw "${kwords[$i]}"
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
      tee|rm|touch|truncate)
        for word in "${ops[@]}"; do emit_target "$word"; done
        ;;
      dd)
        for word in "${ops[@]}"; do
          case "$word" in of=*) emit_target "${word#of=}" ;; esac
        done
        ;;
      ln)
        # One operand links into the current directory, under its name.
        if [ "${#ops[@]}" -eq 1 ]; then
          emit_target "$(basename "$last")"
          continue
        fi
        target_path_to dest "$last" || continue
        if [ -d "$dest" ] && [ ! -L "$dest" ]; then
          for ((i = 0; i < ${#ops[@]} - 1; i++)); do
            emit_target "$last/$(basename "${ops[$i]}")"
          done
        else
          emit_target "$last"
        fi
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
