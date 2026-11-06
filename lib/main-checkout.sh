#!/usr/bin/env bash
# main-checkout.sh
# Prints the main checkout of the project holding <dir> (default: the cwd):
# the tree `git worktree remove` never deletes, after climbing out of any
# submodule into its superproject (outer_checkout_facts, shared with
# session_home in lib/session-event.sh). Skills put files there that must
# outlive a linked worktree, such as a session archive under
# <aiDir>/memory/sessions/archive/, the way the hooks pin the live session
# log. Without git it is the nearest directory holding a .myspec.json.
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/lib/main-checkout.sh [<dir>]
#
# Exit:
#   0  the absolute path on stdout (from the main checkout itself, from any
#      linked worktree of it, or the project root without git)
#   1  nothing to name: <dir> is in no git work tree and under no
#      .myspec.json, or a superproject on the way could not be read
#   3  the repository has no main checkout git can name (a bare clone with
#      worktrees, a --separate-git-dir checkout seen from a linked worktree):
#      every checkout is removable, so nothing is printed
#
# bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

# shellcheck source=lib/hook-core.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-core.sh"

DIR="${1:-$PWD}"

if checkout_facts "$DIR"; then
  ROOT="$CF_ROOT"
  if ! outer_checkout_facts "$DIR"; then
    echo "main-checkout: cannot read the superproject of $ROOT" >&2
    exit 1
  fi
  if [ -z "$CF_MAIN" ]; then
    echo "main-checkout: $CF_ROOT has no main checkout (bare or separate git dir)" >&2
    exit 3
  fi
  printf '%s\n' "$CF_MAIN"
  exit 0
fi

d=$(existing_dir "$DIR") && d=$(physical_dir "$d") || d=""
while [ -n "$d" ]; do
  if [ -f "$d/.myspec.json" ]; then
    printf '%s\n' "$d"
    exit 0
  fi
  [ "$d" != / ] || break
  d=$(dirname "$d")
done
echo "main-checkout: $DIR is in no git work tree and under no .myspec.json" >&2
exit 1
