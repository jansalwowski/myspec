#!/usr/bin/env bash
# path-normalize.sh
# Helpers for converting absolute paths to portable placeholder forms before
# writing them to artifacts that may be shared, committed, or read on another
# machine. Source this file; do not execute directly.
#
# Placeholder convention:
#   <repo_root>                       — the current git toplevel
#   ~/.claude-personal/projects/<encoded_cwd>
#                                     — the harness-managed per-project memory dir
#
# Any other absolute path under $HOME (or starting with /Users//home) cannot
# be auto-converted and is treated as an error by callers.

# normalize_path <abs-path> [<repo-root>]
# Print the portable form on stdout. Exit 0 on success, 1 if not convertible.
normalize_path() {
  local abs="$1"
  local repo_root="${2:-}"
  local home="${HOME:-}"

  [ -n "$abs" ] || return 1

  if [ -z "$repo_root" ]; then
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

  # Harness per-project memory dir → ~/.claude-personal/projects/<encoded_cwd>/...
  if [ -n "$home" ]; then
    case "$abs" in
      "$home"/.claude-personal/projects/*)
        local rest="${abs#"$home"/.claude-personal/projects/}"
        local first="${rest%%/*}"
        local tail=""
        if [ "$first" != "$rest" ]; then
          tail="/${rest#"$first"/}"
        fi
        printf '~/.claude-personal/projects/<encoded_cwd>%s\n' "$tail"
        return 0
        ;;
    esac
  fi

  return 1
}

# resolve_repo_root [path]
# Print the git toplevel for the given path (or $PWD). Exit 1 if not in a repo.
resolve_repo_root() {
  local path="${1:-$PWD}"
  git -C "$path" rev-parse --show-toplevel 2>/dev/null
}

# canonical_main_worktree [path]
# When invoked inside an agent worktree, return the main worktree's toplevel
# instead. Used for computing a stable encoded-cwd across worktrees so the
# user-level auto-memory store does not splinter.
canonical_main_worktree() {
  local cur="${1:-$PWD}"
  local toplevel common_git_dir

  toplevel=$(git -C "$cur" rev-parse --show-toplevel 2>/dev/null) || {
    printf '%s\n' "$cur"
    return 0
  }

  common_git_dir=$(git -C "$cur" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    printf '%s\n' "$toplevel"
    return 0
  }

  if [ "$(basename "$common_git_dir")" = ".git" ]; then
    dirname "$common_git_dir"
  else
    printf '%s\n' "$toplevel"
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
