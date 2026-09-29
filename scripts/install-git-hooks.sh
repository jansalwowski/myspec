#!/usr/bin/env bash
# install-git-hooks.sh
# Points git at the repo's versioned hooks in .githooks/ by setting
# core.hooksPath. The path is relative, so every worktree of the clone runs the
# hooks from its own checkout; the setting itself is shared by all of them.
#
# Idempotent. Writes the repo-local config only, and refuses to replace a
# different repo-local core.hooksPath unless --force.
#
# Usage: scripts/install-git-hooks.sh [--force | --uninstall]

set -euo pipefail

HOOKS_PATH=.githooks

mode=install
case "${1:-}" in
  "") ;;
  --force) mode=force ;;
  --uninstall) mode=uninstall ;;
  -h|--help) echo "usage: $0 [--force | --uninstall]"; exit 0 ;;
  *) echo "usage: $0 [--force | --uninstall]" >&2; exit 2 ;;
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "install-git-hooks: not inside a git work tree" >&2; exit 2; }
current=$(git config --local --get core.hooksPath || true)
global=$(git config --global --get core.hooksPath || true)

if [ "$mode" = uninstall ]; then
  if [ -z "$current" ]; then
    echo "core.hooksPath is not set in this repo; nothing to uninstall"
  elif [ "$current" = "$HOOKS_PATH" ]; then
    git config --local --unset core.hooksPath
    echo "unset core.hooksPath (was $HOOKS_PATH); git uses .git/hooks again"
  else
    echo "core.hooksPath is $current, not $HOOKS_PATH; left unchanged"
  fi
  exit 0
fi

if [ ! -d "$root/$HOOKS_PATH" ]; then
  echo "install-git-hooks: $root/$HOOKS_PATH does not exist" >&2
  exit 1
fi

if [ "$current" = "$HOOKS_PATH" ]; then
  echo "core.hooksPath already $HOOKS_PATH; nothing to do"
elif [ -n "$current" ] && [ "$mode" != force ]; then
  echo "install-git-hooks: core.hooksPath is already $current; rerun with --force to replace it" >&2
  exit 1
else
  git config --local core.hooksPath "$HOOKS_PATH"
  if [ -n "$current" ]; then
    echo "set core.hooksPath=$HOOKS_PATH (replaced $current)"
  else
    echo "set core.hooksPath=$HOOKS_PATH"
  fi
fi

if [ -n "$global" ] && [ "$global" != "$HOOKS_PATH" ]; then
  echo "  note: this overrides your global core.hooksPath ($global) in this repo only"
fi

for h in "$root/$HOOKS_PATH"/*; do
  [ -f "$h" ] || continue
  if [ -x "$h" ]; then
    echo "  active: $HOOKS_PATH/$(basename "$h")"
  else
    echo "  not executable, git will skip it: $HOOKS_PATH/$(basename "$h") (chmod +x it)"
  fi
done
echo "Bypass once with --no-verify; remove with: $0 --uninstall"
