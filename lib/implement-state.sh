#!/usr/bin/env bash
# implement-state.sh
# The run-state directory feature-implement keeps per feature, which survives a
# restarted session and is never committed:
# <main checkout>/.claude/state/implement/<feature>/.
#
# Usage:
#   "${CLAUDE_PLUGIN_ROOT}"/lib/implement-state.sh init <feature>
#   "${CLAUDE_PLUGIN_ROOT}"/lib/implement-state.sh stamp <feature> <phase> <stage>
#   "${CLAUDE_PLUGIN_ROOT}"/lib/implement-state.sh probe-run <feature> <milestone>
#
# init       create the directory, make sure git ignores .claude/state/ (the
#            main checkout's info/exclude when nothing ignores it yet), and
#            print its absolute path
# stamp      append "<stage> <epoch seconds>" to phase-<phase>.times there
# probe-run  create the next free probes/milestone-<milestone>/run-<R>/ and
#            print its absolute path
#
# One command per step, so a session asks for one permission instead of a
# chain of mkdir, git and redirects, and a write under .claude/ (which Claude
# Code guards) goes through the script. <main checkout> is session_home's
# answer (lib/session-event.sh), so every checkout of a repository, linked
# worktrees included, shares one state directory (#441); a repository with no
# main checkout keeps it in its git common dir, myspec-state/implement/. State
# an older version left in any checkout moves there on first use.
#
# Exit 1 on a bad argument or outside a git checkout; nothing is created then.

set -euo pipefail

# shellcheck source=lib/session-event.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session-event.sh"

die() { echo "implement-state: $*" >&2; exit 1; }
usage() { die "usage: implement-state.sh init <feature> | stamp <feature> <phase> <stage> | probe-run <feature> <milestone>"; }

# A name becomes one path segment: no slash, no leading dot, nothing odd.
segment() { [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid $1: '$2'"; }

[ $# -ge 2 ] || usage
CMD="$1" FEATURE="$2"
segment feature "$FEATURE"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout"
HOME_DIR=$(session_home "$TOP") || die "cannot resolve the main checkout of $TOP"
SESSIONS=$(session_dir "$HOME_DIR")
STATE="${SESSIONS%/sessions}/implement/$FEATURE"

# Before #441 each checkout kept its own state. Move the first one found in any
# checkout of the repository (the run may have stopped in another worktree)
# into $STATE, unless $STATE already holds something.
migrate() {
  local wt old
  while IFS= read -r wt; do
    old="$wt/.claude/state/implement/$FEATURE"
    if [ ! -d "$old" ] || [ "$old" -ef "$STATE" ]; then continue; fi
    if [ -e "$STATE" ] && ! rmdir "$STATE" 2>/dev/null; then
      echo "implement-state: $old also holds state for $FEATURE; using $STATE" >&2
    else
      mkdir -p "$(dirname "$STATE")"
      mv "$old" "$STATE"
      echo "implement-state: moved $old to $STATE" >&2
    fi
  done < <(git -C "$TOP" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
}

ensure() {
  migrate
  mkdir -p "$STATE"
  # Only a checkout's .claude/state/ needs ignoring; the common dir is git's own.
  case "$STATE" in
    "$HOME_DIR/.claude/state/"*) ;;
    *) return 0 ;;
  esac
  if ! git -C "$HOME_DIR" check-ignore -q "$STATE"; then
    local exclude
    exclude=$(git -C "$HOME_DIR" rev-parse --path-format=absolute --git-path info/exclude)
    mkdir -p "$(dirname "$exclude")"
    printf '%s\n' '.claude/state/' >> "$exclude"
  fi
}

case "$CMD" in
  init)
    [ $# -eq 2 ] || usage
    ensure
    printf '%s\n' "$STATE"
    ;;
  stamp)
    [ $# -eq 4 ] || usage
    segment phase "$3"
    segment stage "$4"
    ensure
    printf '%s %s\n' "$4" "$(date -u +%s)" >> "$STATE/phase-$3.times"
    ;;
  probe-run)
    [ $# -eq 3 ] || usage
    segment milestone "$3"
    ensure
    probes="$STATE/probes/milestone-$3"
    r=1
    while [ -e "$probes/run-$r" ]; do r=$((r + 1)); done
    mkdir -p "$probes/run-$r"
    printf '%s\n' "$probes/run-$r"
    ;;
  *) usage ;;
esac
