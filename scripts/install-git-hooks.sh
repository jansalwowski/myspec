#!/usr/bin/env bash
# install-git-hooks.sh
# Points git at the repo's versioned hooks in .githooks/ by setting
# core.hooksPath. The path is relative, so every worktree of the clone runs the
# hooks from its own checkout; the setting itself is shared by all of them.
#
# Idempotent. Writes the repo-local config only. A core.hooksPath that already
# points at the default hooks dir (.git/hooks, relative or absolute) is
# replaced; any other value needs --force. A replaced value is kept in
# myspec.previousHooksPath and restored by --uninstall. Hooks that stop running
# because of the switch are listed.
#
# Usage: scripts/install-git-hooks.sh [--force | --uninstall]

set -euo pipefail

HOOKS_PATH=.githooks
PREV_KEY=myspec.previousHooksPath

mode=install
case "${1:-}" in
  "") ;;
  --force) mode=force ;;
  --uninstall) mode=uninstall ;;
  -h|--help) echo "usage: $0 [--force | --uninstall]"; exit 0 ;;
  *) echo "usage: $0 [--force | --uninstall]" >&2; exit 2 ;;
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "install-git-hooks: not inside a git work tree" >&2; exit 2; }
common=$(git rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
current=$(git config --local --get core.hooksPath || true)
global=$(git config --global --get core.hooksPath || true)

# physical <path>: absolute physical path of an existing dir, empty otherwise.
# Relative hooksPath values are relative to the work tree root, where hooks run.
physical() {
  local p=$1
  case "$p" in /*) ;; "~"/*) p="$HOME/${p#\~/}" ;; *) p="$root/$p" ;; esac
  [ -d "$p" ] && (cd "$p" && pwd -P) || true
}
default_hooks=$(mkdir -p "$common/hooks" 2>/dev/null; physical "$common/hooks")

# live_hooks <dir>: hook files git would run from <dir> (executable, not *.sample).
live_hooks() {
  local d=$1 h
  [ -n "$d" ] && [ -d "$d" ] || return 0
  for h in "$d"/*; do
    [ -f "$h" ] && [ -x "$h" ] || continue
    case "$h" in *.sample) continue ;; esac
    basename "$h"
  done
}

if [ "$mode" = uninstall ]; then
  if [ -z "$current" ]; then
    echo "core.hooksPath is not set in this repo; nothing to uninstall"
  elif [ "$current" = "$HOOKS_PATH" ]; then
    prev=$(git config --local --get "$PREV_KEY" || true)
    if [ -n "$prev" ]; then
      git config --local core.hooksPath "$prev"
      git config --local --unset "$PREV_KEY"
      echo "restored core.hooksPath=$prev (was $HOOKS_PATH)"
    else
      git config --local --unset core.hooksPath
      echo "unset core.hooksPath (was $HOOKS_PATH); git uses .git/hooks again"
    fi
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
else
  # The dir git runs hooks from today: the configured one, else the default.
  if [ -n "$current" ]; then was_dir=$(physical "$current"); else was_dir=$default_hooks; fi
  is_default=0
  [ -n "$current" ] && [ -n "$was_dir" ] && [ "$was_dir" = "$default_hooks" ] && is_default=1
  if [ -n "$current" ] && [ "$is_default" -eq 0 ] && [ "$mode" != force ]; then
    echo "install-git-hooks: core.hooksPath is already $current; rerun with --force to replace it" >&2
    exit 1
  fi
  git config --local core.hooksPath "$HOOKS_PATH"
  if [ -n "$current" ]; then
    git config --local "$PREV_KEY" "$current"
    echo "set core.hooksPath=$HOOKS_PATH (replaced $current; --uninstall restores it)"
  else
    # Nothing to restore later; drop a record left by an earlier install.
    git config --local --unset "$PREV_KEY" 2>/dev/null || true
    echo "set core.hooksPath=$HOOKS_PATH"
  fi
  stopped=$(live_hooks "$was_dir")
  if [ -n "$stopped" ]; then
    echo "  warning: these hooks in ${was_dir} no longer run:"
    printf '    %s\n' $stopped
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
