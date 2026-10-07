#!/usr/bin/env bash
# path-normalize.sh
# Helpers for converting absolute paths to portable placeholder forms before
# writing them to artifacts that may be shared, committed, or read on another
# machine. Source this file; do not execute directly.
#
# Placeholder convention:
#   <repo_root>                       — the current git toplevel
#   <config_dir>/projects/<encoded_cwd>
#                                     — the harness-managed per-project memory
#                                       store; <config_dir> is
#                                       $CLAUDE_CONFIG_DIR, default ~/.claude
#
# Any other absolute path under $HOME (or starting with /Users//home) cannot
# be auto-converted and is treated as an error by callers.

# checkout_facts (canonical_main_worktree) comes from hook-core.sh beside
# this file, sourced here once and only when present: a project script that
# sources this file must not abort when the install is partial.
if ! declare -F checkout_facts >/dev/null 2>&1 \
    && [ -f "$(dirname "${BASH_SOURCE[0]}")/hook-core.sh" ]; then
  # shellcheck source=lib/hook-core.sh
  . "$(dirname "${BASH_SOURCE[0]}")/hook-core.sh"
fi

# normalize_path <abs-path> [<repo-root>]
# Print the portable form on stdout. Exit 0 on success, 1 if not convertible.
normalize_path() {
  local abs="$1"
  local repo_root="${2:-}"

  [ -n "$abs" ] || return 1

  if [ -z "$repo_root" ]; then
    # shellcheck disable=SC2119 # no argument means $PWD, not this function's $1
    repo_root="$(resolve_repo_root || true)"
  fi

  # Repo-internal → <repo_root>/<rel>
  if [ -n "$repo_root" ]; then
    if [ "$abs" = "$repo_root" ]; then
      printf '<repo_root>\n'
      return 0
    fi
    case "$abs" in
      "$repo_root"/*)
        printf '<repo_root>/%s\n' "${abs#"$repo_root"/}"
        return 0
        ;;
    esac
  fi

  # Harness per-project memory store → <config_dir>/projects/<encoded_cwd>/...
  local rest
  if rest=$(config_projects_rest "$abs"); then
    printf '<config_dir>/projects/<encoded_cwd>%s\n' "$rest"
    return 0
  fi

  return 1
}

# config_projects_rest <abs-path> -> for a path under a Claude config dir's
# projects/ tree, what follows the encoded-cwd segment ("" or "/..."); exit 1
# for any other path. The config dirs: $CLAUDE_CONFIG_DIR, ~/.claude, and
# ~/.claude-personal (a common CLAUDE_CONFIG_DIR, recognised when the
# variable is not exported to this process).
config_projects_rest() {
  local abs="$1" dir rest first
  for dir in "${CLAUDE_CONFIG_DIR:-}" "${HOME:+$HOME/.claude}" "${HOME:+$HOME/.claude-personal}"; do
    dir="${dir%/}"
    [ -n "$dir" ] || continue
    case "$abs" in
      "$dir"/projects/?*)
        rest="${abs#"$dir"/projects/}"
        first="${rest%%/*}"
        if [ "$first" = "$rest" ]; then
          printf '\n'
        else
          printf '/%s\n' "${rest#"$first"/}"
        fi
        return 0
        ;;
    esac
  done
  return 1
}

# resolve_repo_root [path]
# Print the git toplevel for the given path (or $PWD). Exit 1 if not in a repo.
# shellcheck disable=SC2120 # the path argument is optional; sourcing scripts may pass it
resolve_repo_root() {
  local path="${1:-$PWD}"
  git -C "$path" rev-parse --show-toplevel 2>/dev/null
}

# canonical_main_worktree [path]
# When invoked inside an agent worktree, return the main worktree's toplevel
# instead (checkout_facts in hook-core.sh, beside this file); the checkout's
# own toplevel when git cannot name one, and the path itself outside git or
# without hook-core.sh.
# Used for computing a stable encoded-cwd across worktrees so the user-level
# auto-memory store does not splinter.
canonical_main_worktree() {
  local cur="${1:-$PWD}"
  if declare -F checkout_facts >/dev/null && checkout_facts "$cur"; then
    printf '%s\n' "${CF_MAIN:-$CF_ROOT}"
  else
    printf '%s\n' "$cur"
  fi
}

# encode_cwd <abs-path>
# Apply the harness encoding: replace `/` and `_` with `-`.
encode_cwd() {
  printf '%s' "$1" | tr '/_' '-'
}

# detect_absolute_paths
# Read content from stdin, print each absolute-path-shaped match on its own
# line. Patterns: /Users/<name>, /home/<name>, encoded-cwd literals like
# -Users-<name>- or -home-<name>-.
detect_absolute_paths() {
  grep -oE '(/Users/[A-Za-z][A-Za-z0-9._-]*|/home/[A-Za-z][A-Za-z0-9._-]*|-Users-[A-Za-z][A-Za-z0-9._-]+|-home-[A-Za-z][A-Za-z0-9._-]+)' 2>/dev/null || true
}
