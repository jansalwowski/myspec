#!/usr/bin/env bash
# mark-code-changed.sh
# PostToolUse hook (Write|Edit and Bash matchers) — marks that code files were
# changed in this session, and keeps the session's live log.
#
# Marker: /tmp/.myspec-code-changed-<session_id>, so verify-before-stop.sh only
# runs verification when the current session actually modified code. It holds
# one line per repository the session edited (the primary checkout root), so an
# edit in a sibling repository does not arm this repository's Stop gate. A file
# outside every repository (/tmp, a scratchpad) is not a code change.
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
# Bash writes: `sed -i`, redirects, `tee`, `git apply` and the like never fire
# the Write|Edit matcher, so a Bash-driven session used to leave no log at all.
# Registered under a Bash matcher too, this hook scans the command (quoted spans
# and heredoc bodies blanked by lib/command-scan.sh) for a write verb and a
# code-file path. A script that writes from inside a heredoc body is not seen —
# run it as `python3 script.py` or use the Write tool.
#
# `## Files touched` is how a skill finds ITS OWN session among several: the
# harness never exposes the session id to the model, but the paths it edited
# are known to it. Tests: hooks/tests/mark-code-changed*.test.sh in the myspec
# plugin repository (not installed into adopting projects).

set -euo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)

CODE_EXT='(ts|tsx|vue|js|jsx|mjs|cjs|mts|cts|py|rb|go|java|php|rs|cs|swift|kt|sh|bash|graphql|gql)'

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
    dirname "$common_git_dir"
    return 0
  fi

  git -C "$path" rev-parse --show-toplevel 2>/dev/null
}

# Repository root before main-worktree normalisation, most authoritative source
# first: the edited file's repository, then whatever cwd the payload carries.
resolve_repo_root_raw() {
  local file_path="$1"
  local anchor candidate resolved

  case "$file_path" in
    /*)
      if anchor=$(anchor_dir_for_file "$file_path"); then
        if resolved=$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null); then
          printf '%s\n' "$resolved"
          return 0
        fi
      fi
      ;;
  esac

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if resolved=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
      printf '%s\n' "$resolved"
      return 0
    fi
    if [ -f "$candidate/.myspec.json" ]; then
      printf '%s\n' "$candidate"
      return 0
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

  if resolved=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if resolved=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

# in_repo <path>: true unless an absolute path lies outside every repository
# (/tmp, a scratchpad): inside a git work tree, or under RAW_ROOT for a
# myspec project that is not a git repository.
in_repo() {
  local anchor
  case "$1" in
    /*) ;;
    *) return 0 ;;
  esac
  anchor=$(anchor_dir_for_file "$1") || return 1
  git -C "$anchor" rev-parse --show-toplevel >/dev/null 2>&1 && return 0
  case "$1" in
    "${RAW_ROOT:-}"/*) [ -n "${RAW_ROOT:-}" ] && return 0 ;;
  esac
  return 1
}

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

[ -n "$SESSION_ID" ] || exit 0

PATHS=()
CONTEXT=""

if [ -n "$FILE_PATH" ]; then
  # Only code files (not docs, config, etc.) — common extensions across stacks.
  if [[ ! "$FILE_PATH" =~ \.${CODE_EXT}$ ]]; then
    exit 0
  fi

  if ! RAW_ROOT="$(resolve_repo_root_raw "$FILE_PATH")"; then
    exit 0
  fi
  in_repo "$FILE_PATH" || exit 0

  PATHS=("$FILE_PATH")
  CONTEXT="Auto-created on first code edit at \`$FILE_PATH\`."
elif [ -n "$COMMAND" ]; then
  if ! RAW_ROOT="$(resolve_repo_root_raw "")"; then
    exit 0
  fi

  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  LIB=""
  for cand in "$SCRIPT_DIR/../lib/command-scan.sh" "$RAW_ROOT/.claude/lib/command-scan.sh" "$RAW_ROOT/lib/command-scan.sh"; do
    if [ -f "$cand" ]; then
      LIB="$cand"
      break
    fi
  done
  [ -n "$LIB" ] || exit 0

  # shellcheck source=/dev/null
  . "$LIB"

  # Paths come only from what a segment WRITES: the target of a `>`/`>>`
  # redirect, or the file arguments of a write verb at command position (sed -i,
  # perl -i, tee, mv, patch, git apply; for cp/rsync/install the destination).
  # A redirect to /dev/null or an fd dup (`2>&1`, `>&2`) writes nothing, and a
  # code path elsewhere in the command (`cat src/a.ts 2>/dev/null`, `git log --
  # src/a.ts > /dev/null`) is only read. Collecting from the whole command once
  # a write pattern matched anywhere logged read-only sessions and armed the
  # Stop hook's full verification on them. Relative paths resolve against the
  # cwd (and any literal `cd` before them), so a write inside a linked worktree
  # records the worktree file, not a same-named one in the main checkout.
  CODE_PATH_RE="^[A-Za-z0-9_@./-]+\.${CODE_EXT}\$"

  BASE_DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$BASE_DIR" ] && [ -d "$BASE_DIR" ] || BASE_DIR="$PWD"
  BASE_DIR=$(cd "$BASE_DIR" && pwd -P)

  add_path() {  # add_path <word>
    local w="${1#./}"
    [[ "$w" =~ $CODE_PATH_RE ]] || return 0
    case "$w" in
      /*) ;;
      *) w="$BASE_DIR/$w" ;;
    esac
    in_repo "$w" || return 0
    PATHS+=("$w")
  }

  while IFS= read -r line; do
    segment=$(strip_command_prefix "${line#*$'\t'}")
    words=()
    read -r -a words <<< "$segment" || true
    [ "${#words[@]}" -gt 0 ] || continue

    # A literal `cd` moves the base for relative paths after it.
    if [ "${words[0]}" = cd ]; then
      if [ "${#words[@]}" -ge 2 ] && NEXT_DIR=$(cd "$BASE_DIR" 2>/dev/null && cd "${words[1]}" 2>/dev/null && pwd -P); then
        BASE_DIR="$NEXT_DIR"
      fi
      continue
    fi

    # Redirect targets. `[0-9]*` covers `2>`; the scanner already split
    # `&>` and `>&N` on the `&`, leaving no target after the `>`.
    while IFS= read -r redirect; do
      target="${redirect##*[>|]}"
      target="${target#"${target%%[![:space:]]*}"}"
      case "$target" in
        /dev/*|'') ;;
        *) add_path "$target" ;;
      esac
    done < <(printf '%s' "$segment" | grep -oE '>{1,2}\|?[[:space:]]*[^[:space:]<>|]+' || true)

    # Write verbs: their file arguments.
    verb="${words[0]##*/}"
    args=("${words[@]:1}")
    case "$verb" in
      sed)
        printf '%s' "$segment" | grep -qE '^[^[:space:]]*sed[[:space:]]+(.*[[:space:]])?(-[a-zA-Z]*i|--in-place)' || args=() ;;
      perl)
        printf '%s' "$segment" | grep -qE '^[^[:space:]]*perl[[:space:]]+(.*[[:space:]])?-[a-zA-Z]*i' || args=() ;;
      tee|mv|patch) ;;
      git)
        [ "${words[1]:-}" = apply ] || args=() ;;
      cp|rsync|install)
        # Only the destination is written; into a directory, as <dir>/<name>.
        dest=""
        sources=()
        for w in ${args[@]+"${args[@]}"}; do
          case "$w" in
            *'>'*|'<'*) break ;;
            -*) ;;
            *) [ -z "$dest" ] || sources+=("$dest"); dest="$w" ;;
          esac
        done
        args=()
        if [ -n "$dest" ]; then
          if [[ "${dest#./}" =~ $CODE_PATH_RE ]]; then
            args=("$dest")
          else
            for w in ${sources[@]+"${sources[@]}"}; do
              [[ "$w" =~ $CODE_PATH_RE ]] && args+=("${dest%/}/${w##*/}")
            done
          fi
        fi ;;
      *) args=() ;;
    esac
    for w in ${args[@]+"${args[@]}"}; do
      case "$w" in
        -*) ;;
        *) add_path "$w" ;;
      esac
    done
  done < <(printf '%s' "$COMMAND" | sanitize_command | split_segments)

  [ "${#PATHS[@]}" -gt 0 ] || exit 0

  # Dedupe, keeping order.
  UNIQUE=()
  for p in "${PATHS[@]}"; do
    case " ${UNIQUE[*]-} " in
      *" $p "*) ;;
      *) UNIQUE+=("$p") ;;
    esac
  done
  PATHS=("${UNIQUE[@]}")

  # Anchor on the written file, as the Write branch does.
  if ANCHORED_ROOT="$(resolve_repo_root_raw "${PATHS[0]}")"; then
    RAW_ROOT="$ANCHORED_ROOT"
  fi

  CONTEXT="Auto-created on a Bash write: \`$(printf '%s' "$COMMAND" | tr '\n' ' ' | head -c 120)\`."
else
  exit 0
fi

# RAW_ROOT is the repository root as seen from the edit (a linked worktree
# resolves to itself); REPO_ROOT is pinned to the primary checkout, where the
# session store lives.
if ! REPO_ROOT="$(main_worktree_root "$RAW_ROOT")"; then
  REPO_ROOT="$RAW_ROOT"
fi

# The marker names the repository, physical path, one line each, so the Stop
# hook of a different repository sees no code change of its own. Written
# before the .myspec.json gate: a repository without one still gets verified.
MARKER="/tmp/.myspec-code-changed-${SESSION_ID}"
MARKER_ROOT=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P) || MARKER_ROOT="$REPO_ROOT"
if ! grep -qxF -- "$MARKER_ROOT" "$MARKER" 2>/dev/null; then
  printf '%s\n' "$MARKER_ROOT" >> "$MARKER"
fi

# Logs only in a myspec-managed project: an edit in an unrelated repository
# must not grow a stray state tree there.
[ -f "$REPO_ROOT/.myspec.json" ] || exit 0

STATE_DIR="$REPO_ROOT/.claude/state/sessions"
ACTIVE_FILE="$STATE_DIR/${SESSION_ID}.md"

# Worktree marker: the edit resolved to a linked worktree when the raw root
# differs from the pinned primary checkout. The basename is portable (no
# absolute path) and lets session-clean's liveness gate match the session
# against `git worktree list`. Main checkout: empty (gate uses mtime).
WORKTREE=""
if [ "$RAW_ROOT" != "$REPO_ROOT" ]; then
  WORKTREE=$(basename "$RAW_ROOT")
fi

if [ ! -f "$ACTIVE_FILE" ]; then
  mkdir -p "$STATE_DIR"

  # Topic seed: parent directory name of the first edited file
  TOPIC_SEED=$(basename "$(dirname "${PATHS[0]}")" 2>/dev/null || echo "auto")
  [ -z "$TOPIC_SEED" ] || [ "$TOPIC_SEED" = "." ] && TOPIC_SEED="auto"
  STARTED=$(date '+%Y-%m-%d %H:%M')
  SHORT_ID="${SESSION_ID:0:8}"

  cat > "$ACTIVE_FILE" <<SESSION
---
session_id: $SESSION_ID
topic: "auto:$TOPIC_SEED"
feature: ""
mode: implementation
started: $STARTED
status: active
auto_created: true
worktree: "$WORKTREE"
---

# Session $SHORT_ID — auto:$TOPIC_SEED

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
if ! grep -q '^## Files touched' "$ACTIVE_FILE" 2>/dev/null; then
  printf '\n## Files touched\n' >> "$ACTIVE_FILE"
fi

for p in "${PATHS[@]}"; do
  case "$p" in
    "$REPO_ROOT"/*) rel="${p#"$REPO_ROOT"/}" ;;
    *) rel="$p" ;;
  esac
  if ! grep -qF -- "- \`$rel\`" "$ACTIVE_FILE"; then
    printf -- '- `%s`\n' "$rel" >> "$ACTIVE_FILE"
  fi
done

exit 0
