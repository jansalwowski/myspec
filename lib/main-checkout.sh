#!/usr/bin/env bash
# main-checkout.sh
# Prints the main checkout of the repository holding <dir> (default: the
# cwd), after climbing out of any submodule into its superproject: the tree
# `git worktree remove` never deletes. Skills put files there that must
# outlive a linked worktree, such as a session archive under
# <aiDir>/memory/sessions/archive/, the way the hooks pin the live session
# log (session_home in lib/session-event.sh).
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/lib/main-checkout.sh [<dir>]
#
# Exit:
#   0  the main checkout's absolute path on stdout (from the main checkout
#      itself, or from any linked worktree of it)
#   1  <dir> is in no git work tree: there are no worktrees, so the project
#      root is already safe
#   3  the repository has no main checkout git can name (a bare clone with
#      worktrees, a --separate-git-dir checkout seen from a linked worktree):
#      every checkout is removable, so nothing is printed
#
# bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

# shellcheck source=lib/hook-core.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-core.sh"

DIR="${1:-$PWD}"

if ! checkout_facts "$DIR"; then
  echo "main-checkout: $DIR is in no git work tree" >&2
  exit 1
fi
while [ "$CF_SUBMODULE" = 1 ] && [ -n "$CF_SUPER" ] && checkout_facts "$CF_SUPER"; do :; done

if [ -z "$CF_MAIN" ]; then
  echo "main-checkout: $CF_ROOT has no main checkout (bare or separate git dir)" >&2
  exit 3
fi
printf '%s\n' "$CF_MAIN"
