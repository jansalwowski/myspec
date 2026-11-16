#!/usr/bin/env bash
# bootstrap-scan.sh
# The mechanical half of /myspec:bootstrap: counts, health checks and
# comparisons that need no judgement. Each step prints at most one summary
# line in the form the bootstrap summary uses ("**Label**: value"), so the
# skill pastes the output as printed. Read-only: it moves, stages and fixes
# nothing (stale session logs are counted for /myspec:session-clean, #511).
#
# Steps:
#   memory     Layer 1 entries in <aiDir>/memory/index.md (list lines and
#              table rows) and the row count of each Layer 2 index
#   health     memory-doctor.mjs --quiet and setup-doctor.mjs --quiet, the
#              summary line of each
#   sessions   live logs (*.md) in the session directory: under 6h listed
#              as active (id prefix and topic), 1-6h also counted as
#              possibly dangling, over 6h counted as stale
#   worktrees  non-main worktrees whose path is gone (orphaned, what
#              `git worktree prune` would remove) or whose last commit is
#              older than 3 days (stale)
#   lag        only with --integration and --release (the topology file's
#              branches.integration and branches.release, when they differ)
#   version    .myspec.json frameworkVersion against this plugin's manifest
#
# aiDir and frameworkVersion are read through the settings reader
# (lib/hook-core.sh ai_dir, read_setting), never from a shell variable the
# caller must set (#509).
#
# Usage:
#   bootstrap-scan.sh [--integration <branch> --release <branch>] [--no-fetch]
#
# Exit 0 when the scan ran (a step that could not run says so in its line),
# 2 on bad usage or outside a project (no git work tree and no .myspec.json).
#
# bash 3.2 compatible (macOS /bin/bash).

set -uo pipefail

INTEGRATION=""
RELEASE=""
FETCH=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --integration) [ "$#" -ge 2 ] || { echo "bootstrap-scan: --integration needs a value" >&2; exit 2; }
                   INTEGRATION="$2"; shift 2 ;;
    --release)     [ "$#" -ge 2 ] || { echo "bootstrap-scan: --release needs a value" >&2; exit 2; }
                   RELEASE="$2"; shift 2 ;;
    --no-fetch)    FETCH=0; shift ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
    *)             echo "bootstrap-scan: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(dirname "$LIB")
# shellcheck source=lib/hook-core.sh
. "$LIB/hook-core.sh"
# shellcheck source=lib/session-event.sh
. "$LIB/session-event.sh"

GIT=0
if HERE=$(git rev-parse --show-toplevel 2>/dev/null); then
  GIT=1
else
  HERE=$(session_home "$PWD") || { echo "bootstrap-scan: not inside a git repository or a myspec project" >&2; exit 2; }
fi
HOME_DIR=$(session_home "$HERE") || HOME_DIR="$HERE"
SESSIONS=$(session_dir "$HOME_DIR")
AI=$(ai_dir "$HERE" 2>/dev/null) || AI=".ai"
NOW=$(date +%s)

# mtime_of <path> -> epoch seconds, or 0 (GNU stat first: BSD's -f means
# --file-system to GNU and succeeds with text).
mtime_of() {
  local t
  t=$(stat -c %Y "$1" 2>/dev/null) || t=""
  case "$t" in ''|*[!0-9]*) t=$(stat -f %m "$1" 2>/dev/null) || t="" ;; esac
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  printf '%s' "$t"
}

# --- memory -----------------------------------------------------------------
# grep -c prints 0 itself on no match and exits 1; a missing file prints
# nothing, so the count falls back to 0.
count_rows() {
  local c
  c=$(grep -ciE "$1" "$2" 2>/dev/null) || true
  printf '%s' "${c:-0}"
}

step_memory() {
  local mem="$HERE/$AI/memory" l1 p s e
  l1=$(count_rows '^(- +[^ <]|\| *\[[pse][0-9]+)' "$mem/index.md")
  p=$(count_rows '^\| *\[[pse][0-9]+' "$mem/procedural/index.md")
  s=$(count_rows '^\| *\[[pse][0-9]+' "$mem/semantic/index.md")
  e=$(count_rows '^\| *\[[pse][0-9]+' "$mem/episodic/index.md")
  echo "**Memory**: Layer 1 $l1 entries | Layer 2 $p procedural, $s semantic, $e episodic rows"
  if [ "$l1" -eq 0 ] && [ $((p + s + e)) -gt 0 ]; then
    echo "**Layer 1**: empty while Layer 2 has $((p + s + e)) rows; promote the few critical entries with /myspec:memory-optimize"
  fi
}

# --- health -----------------------------------------------------------------
step_health() {  # step_health <label> <script>
  local out
  if ! command -v node >/dev/null 2>&1; then
    echo "**$1**: not checked, node not found"
    return
  fi
  # Exit 1 means findings, which is a result: the last line is the summary.
  out=$(cd "$HERE" && node "$LIB/$2" --quiet 2>/dev/null | tail -n 1)
  case "$out" in
    *': clean') echo "**$1**: clean" ;;
    *' error(s)'*) echo "**$1**: ${out#*: }, run \`node \"$LIB/$2\"\` for details" ;;
    *' doctor: '*) echo "**$1**: ${out#*: }" ;;
    *) echo "**$1**: not checked, $2 gave no summary" ;;
  esac
}

# --- sessions ---------------------------------------------------------------
step_sessions() {
  local f age id topic active=0 dangling=0 stale=0 list=""
  if [ -d "$SESSIONS" ]; then
    for f in "$SESSIONS"/*.md; do
      [ -f "$f" ] || continue
      age=$(( NOW - $(mtime_of "$f") ))
      if [ "$age" -gt 21600 ]; then
        stale=$((stale + 1))
        continue
      fi
      [ "$age" -gt 3600 ] && dangling=$((dangling + 1))
      active=$((active + 1))
      id=$(basename "$f" .md | cut -c1-8)
      topic=$(awk 'NR == 1 && $0 == "---" { fm = 1; next }
        fm && $0 == "---" { exit }
        fm && sub(/^topic: */, "") { gsub(/"/, ""); print; exit }' "$f" 2>/dev/null)
      list="$list${list:+, }$id (${topic:-no topic})"
    done
  fi
  if [ "$active" -gt 0 ]; then
    echo "**Active sessions**: $active: $list"
  else
    echo "**Active sessions**: 0"
  fi
  [ "$dangling" -eq 0 ] || echo "**Dangling**: $dangling session(s) 1-6h stale, run /myspec:session-clean"
  [ "$stale" -eq 0 ] || echo "**Stale sessions**: $stale log(s) older than 6h, run /myspec:session-clean"
}

# --- worktrees --------------------------------------------------------------
step_worktrees() {
  local line path="" first=1 bare=0 total=0 bad=0 ct
  [ "$GIT" -eq 1 ] || return
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }"; bare=0 ;;
      bare) bare=1 ;;
      "")
        if [ -n "$path" ]; then
          if [ "$first" -eq 1 ] || [ "$bare" -eq 1 ]; then
            first=0
          else
            total=$((total + 1))
            if [ ! -d "$path" ]; then
              bad=$((bad + 1))
            else
              ct=$(git -C "$path" log -1 --format=%ct 2>/dev/null) || ct=""
              case "$ct" in ''|*[!0-9]*) ;; *) [ $(( NOW - ct )) -gt 259200 ] && bad=$((bad + 1)) ;; esac
            fi
          fi
        fi
        path=""
        ;;
    esac
  done < <(git -C "$HERE" worktree list --porcelain 2>/dev/null; echo)
  [ "$total" -gt 0 ] || return
  if [ "$bad" -gt 0 ]; then
    echo "**Worktree health**: WARNING, $bad of $total stale or orphaned; use the worktree-clean skill"
  else
    echo "**Worktree health**: clean ($total active)"
  fi
}

# --- branch lag -------------------------------------------------------------
step_lag() {
  local rc n
  [ -n "$INTEGRATION" ] && [ -n "$RELEASE" ] && [ "$INTEGRATION" != "$RELEASE" ] || return
  [ "$GIT" -eq 1 ] || { echo "**Branch lag**: not checked, not a git repository"; return; }
  if [ "$FETCH" -eq 1 ]; then
    git -C "$HERE" fetch --quiet origin "$RELEASE" "$INTEGRATION" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || { echo "**Branch lag**: not checked, git fetch exited $rc"; return; }
  fi
  git -C "$HERE" merge-base --is-ancestor "origin/$RELEASE" "origin/$INTEGRATION" 2>/dev/null
  rc=$?
  case "$rc" in
    0) ;;
    1) n=$(git -C "$HERE" rev-list --count "origin/$INTEGRATION..origin/$RELEASE" 2>/dev/null) || n="?"
       echo "**Branch lag**: $INTEGRATION is missing $n commit(s) from $RELEASE, merge $RELEASE into $INTEGRATION before planning" ;;
    *) echo "**Branch lag**: not checked, git merge-base exited $rc" ;;
  esac
}

# --- version ----------------------------------------------------------------
# semver_cmp <a> <b> -> prints -1, 0 or 1; fails when either is not X.Y.Z.
semver_cmp() {
  local a="$1" b="$2" x y i
  case "$a$b" in *[!0-9.]*) return 1 ;; esac
  [ "$(printf '%s' "$a" | tr -cd . | wc -c | tr -d ' ')" = 2 ] || return 1
  [ "$(printf '%s' "$b" | tr -cd . | wc -c | tr -d ' ')" = 2 ] || return 1
  for i in 1 2 3; do
    x=$(printf '%s' "$a" | cut -d. -f"$i"); y=$(printf '%s' "$b" | cut -d. -f"$i")
    [ -n "$x" ] && [ -n "$y" ] || return 1
    if [ "$((10#$x))" -gt "$((10#$y))" ]; then echo 1; return 0; fi
    if [ "$((10#$x))" -lt "$((10#$y))" ]; then echo -1; return 0; fi
  done
  echo 0
}

step_version() {
  local proj="" plug="" cmp
  if read_setting frameworkVersion "$HERE" 2>/dev/null; then
    proj=$(json_string "$SETTING")
  fi
  if command -v jq >/dev/null 2>&1; then
    plug=$(jq -r '.frameworkVersion // empty' "$PLUGIN/framework-files/manifest.json" 2>/dev/null) || plug=""
  else
    plug=$(awk -F'"' '$2 == "frameworkVersion" { print $4; exit }' "$PLUGIN/framework-files/manifest.json" 2>/dev/null)
  fi
  [ -n "$proj" ] && [ -n "$plug" ] || return
  if cmp=$(semver_cmp "$plug" "$proj"); then
    case "$cmp" in
      1)  echo "**myspec version**: plugin v$plug ahead of project v$proj, run /myspec:update" ;;
      -1) echo "**myspec version**: plugin v$plug behind project v$proj, update your plugin" ;;
    esac
  elif [ "$plug" != "$proj" ]; then
    echo "**myspec version**: project on v$proj, plugin has v$plug"
  fi
}

step_memory
step_health "Memory health" memory-doctor.mjs
step_health "Setup health" setup-doctor.mjs
step_sessions
step_worktrees
step_lag
step_version
exit 0
