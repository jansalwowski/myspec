#!/usr/bin/env bash
# dep-dir.sh
# lint: sourced under set -euo pipefail
# Sourced, never run. The one rule for "a dependency directory holds nothing
# installed", shared by lib/worktree-provision.sh (whether a directory already
# in the worktree may be moved aside for a link) and lib/stop-gate/provision.sh
# (deps_not_installed, the Stop hook's "Dependencies not installed" note).
# Each caller keeps its own list of dependency directories; this file knows
# none of them.
#
# An entry directly in the directory is not an install when it is
#   - a file git tracks: a placeholder the repository keeps there
#     (node_modules/.gitkeep, #239);
#   - dot-prefixed and untracked: a tool's cache written before any install
#     (.vite, .vitest-cache or .cache from a test run, #373, #375).
# Any other entry (a package directory, an untracked file, a link without a
# leading dot) is. An installer's own dot-prefixed state file is not told
# apart here: the stop gate checks its install-state markers first, and
# provision only moves a directory aside, never deletes it.
# bash 3.2 compatible (macOS /bin/bash).

# dep_dir_uninstalled <checkout> <dir, relative to it> -> 0 when nothing is
# installed in <checkout>/<dir> (no entry at all counts), printing one
# "tracked<TAB><path>" or "dot<TAB><path>" line per entry, the path relative
# to <checkout>. Returns 1, at the first entry that is an install, or when
# <dir> is not a real directory (absent, or a link).
dep_dir_uninstalled() {
  local co="$1" rel="$2" tracked e name
  [ -d "$co/$rel" ] && [ ! -L "$co/$rel" ] || return 1
  tracked=$'\n'$(git -C "$co" ls-files -- ":(literal)$rel" 2>/dev/null || true)$'\n'
  for e in "$co/$rel"/* "$co/$rel"/.[!.]* "$co/$rel"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    name="${e#"$co"/}"
    if [ -f "$e" ] && [ ! -L "$e" ]; then
      case "$tracked" in
        *$'\n'"$name"$'\n'*) printf 'tracked\t%s\n' "$name"; continue ;;
      esac
    fi
    case "${e##*/}" in
      .*) printf 'dot\t%s\n' "$name" ;;
      *) return 1 ;;
    esac
  done
  return 0
}
