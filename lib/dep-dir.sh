#!/usr/bin/env bash
# dep-dir.sh
# lint: sourced under set -euo pipefail
# Sourced, never run. The one rule for "a dependency directory holds nothing
# installed", shared by lib/worktree-provision.sh (whether a directory already
# in the worktree may be moved aside for a link, or filled by a copy) and
# lib/stop-gate/provision.sh (deps_not_installed, the Stop hook's
# "Dependencies not installed" note). Each caller keeps its own list of
# dependency directories; this file knows none of them.
#
# A directory holds nothing installed when none of DEP_MARKERS exists in it
# and every entry directly in it is
#   - a file git tracks: a placeholder the repository keeps there
#     (node_modules/.gitkeep, #239), or
#   - an untracked entry named in DEP_CACHES: a tool's cache written before
#     any install (a test run's .vite or .cache, #373, #375).
# Any other entry is an install, a dot-prefixed one included: installers keep
# packages in dot directories (.pnpm, .bun, .deno), so the rule errs toward
# "installed" and a directory it cannot place is never moved. Both lists are
# data, one entry per name, across ecosystems; another tool is one more word.
# bash 3.2 compatible (macOS /bin/bash).

# Install-state markers, any ecosystem's, relative to the directory: npm,
# Yarn (classic and Berry), pnpm, Composer, Go vendoring, a venv, CocoaPods.
DEP_MARKERS=".package-lock.json .yarn-state.yml .yarn-integrity .modules.yaml autoload.php composer/installed.json modules.txt pyvenv.cfg Manifest.lock"

# Cache and OS-litter names tools write into a dependency directory without
# installing anything (bundlers, test runners, linters, type checkers).
DEP_CACHES=".cache .vite .vitest .vitest-cache .parcel-cache .eslintcache .turbo .pytest_cache .mypy_cache .ruff_cache .phpunit.cache .phpunit.result.cache .php-cs-fixer.cache .rspec_status .DS_Store"

# dep_dir_uninstalled <checkout> <dir, relative to it> -> 0 when nothing is
# installed in <checkout>/<dir> (no entry at all counts), printing one
# "tracked<TAB><path>" or "cache<TAB><path>" line per entry, the path
# relative to <checkout>. Returns 1 on a marker, at the first entry that is
# an install, or when <dir> is not a real directory (absent, or a link).
dep_dir_uninstalled() {
  local co="$1" rel="$2" tracked e name m
  [ -d "$co/$rel" ] && [ ! -L "$co/$rel" ] || return 1
  for m in $DEP_MARKERS; do
    [ ! -e "$co/$rel/$m" ] || return 1
  done
  tracked=$'\n'$(git -C "$co" ls-files -- ":(literal)$rel" 2>/dev/null || true)$'\n'
  for e in "$co/$rel"/* "$co/$rel"/.[!.]* "$co/$rel"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    name="${e#"$co"/}"
    if [ -f "$e" ] && [ ! -L "$e" ]; then
      case "$tracked" in
        *$'\n'"$name"$'\n'*) printf 'tracked\t%s\n' "$name"; continue ;;
      esac
    fi
    case " $DEP_CACHES " in
      *" ${e##*/} "*) printf 'cache\t%s\n' "$name" ;;
      *) return 1 ;;
    esac
  done
  return 0
}
