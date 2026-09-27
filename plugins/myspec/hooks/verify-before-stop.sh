#!/usr/bin/env bash
# verify-before-stop.sh
# Stop hook — runs verification checks before agent completes.
# Reads commands from .claude/verification.json (requires jq).
# Outputs {"decision": "block", "reason": "..."} on failure or {"decision": "approve"} on success.
# During feature-implement (.claude/state/implement-in-progress.json, at most
# 8h old) check failures become a non-blocking systemMessage warning instead.
# Before any check runs, blocks when a dependency directory (each guarded
# isolation.provision.symlink entry, plus node_modules, vendor, .venv, venv)
# is a symlink into a checkout whose lockfiles for it differ from this tree.

set -euo pipefail

# Read stdin JSON (Stop hook receives session context)
INPUT=$(cat)

# Prevent infinite loop on re-entry. The harness signals this via
# stop_hook_active in the stdin JSON (the continuation after a prior block);
# env vars kept as a fallback for hosts that set them instead.
if command -v jq >/dev/null 2>&1; then
  if [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    echo '{"decision": "approve"}'
    exit 0
  fi
fi
if [ "${CLAUDE_STOP_HOOK_ACTIVE:-}" = "1" ] || [ "${MYSPEC_STOP_HOOK_ACTIVE:-}" = "1" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

resolve_repo_root() {
  local candidate resolved

  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if resolved=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
        printf '%s\n' "$resolved"
        return 0
      fi
      if [ -f "$candidate/.myspec.json" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done <<EOF
$(printf '%s' "$INPUT" | jq -r '
  [
    .cwd,
    .workdir,
    .workspace.cwd,
    .session.cwd,
    .tool_input.cwd,
    .tool_input.workdir
  ] | map(select(type == "string" and . != "")) | .[]
' 2>/dev/null)
EOF
  fi

  if resolved=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if resolved=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

if ! REPO_ROOT="$(resolve_repo_root)"; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Memory conformance. The index tables are generated and the ID allocator
# refuses on drift, so drift a session leaves behind (an unregenerated index, a
# memory without hook:, a duplicate ID) should surface here, in the session that
# caused it, not in the next session's claim. Gated on uncommitted changes under
# the memory tree: pre-existing drift the agent never touched is bootstrap's to
# report, not a reason to block a stop.
DOCTOR="$REPO_ROOT/.claude/lib/memory-doctor.mjs"
if [ -f "$DOCTOR" ] && [ -f "$REPO_ROOT/.myspec.json" ] && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # aiDir is required since 2.0; .ai is the documented default when absent,
  # the same resolution memory-files.mjs uses.
  MEMORY_AI_DIR=$(jq -r '.aiDir // empty' "$REPO_ROOT/.myspec.json" 2>/dev/null | sed 's#/*$##')
  MEMORY_AI_DIR="${MEMORY_AI_DIR:-.ai}"
  if [ -n "$MEMORY_AI_DIR" ] && git -C "$REPO_ROOT" status --porcelain -- "$MEMORY_AI_DIR/memory" 2>/dev/null | grep -q .; then
    if ! DOCTOR_OUT=$(cd "$REPO_ROOT" && node "$DOCTOR" --quiet 2>&1); then
      REASON=$(printf 'Memory conformance check failed for changes under %s/memory. Fix these before stopping (node .claude/lib/memory-index.mjs regenerates the tables; the doctor names the rest):\n\n%s' "$MEMORY_AI_DIR" "$(printf '%s' "$DOCTOR_OUT" | tail -30)" | jq -Rs .)
      echo "{\"decision\": \"block\", \"reason\": $REASON}"
      exit 0
    fi
  fi
fi

# Setup conformance. Only the wiring and schema groups: a hook that is
# registered but missing, not executable, or fails bash -n is silently inert,
# and an unparseable .myspec.json or verification.json degrades this very gate
# to approve — all of them are damage the session just did and can undo now.
# Framework drift is deliberately excluded: its usual cause is a pending
# /myspec:update, and blocking on that would halt every commit made between a
# plugin release and the next update run. The features group is excluded too —
# it reads a file under the aiDir, outside the trigger below, so including it
# would block a stop over something this session never touched. Gated on
# uncommitted changes to the harness config, for the same reason the memory
# check above is gated.
SETUP_DOCTOR="$REPO_ROOT/.claude/lib/setup-doctor.mjs"
if [ -f "$SETUP_DOCTOR" ] && [ -f "$REPO_ROOT/.myspec.json" ] && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" status --porcelain -- .claude .myspec.json 2>/dev/null | grep -q .; then
    if ! SETUP_OUT=$(cd "$REPO_ROOT" && node "$SETUP_DOCTOR" --quiet wiring schema 2>&1); then
      REASON=$(printf 'Setup conformance check failed for changes under .claude/ or .myspec.json. Each of these makes a hook or a gate silently stop working, so fix them before stopping:\n\n%s' "$(printf '%s' "$SETUP_OUT" | tail -30)" | jq -Rs .)
      echo "{\"decision\": \"block\", \"reason\": $REASON}"
      exit 0
    fi
  fi
fi

CONFIG_FILE="$REPO_ROOT/.claude/verification.json"

# If no config file, skip (graceful degradation)
if [ ! -f "$CONFIG_FILE" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check if jq is available
if ! command -v jq &>/dev/null; then
  echo '{"decision": "approve"}'
  exit 0
fi

# Check if this session actually changed code files.
# mark-code-changed.sh (PostToolUse) touches a marker file when the agent edits code.
# This avoids running verification for brainstorming/planning sessions with pre-existing changes.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
MARKER_FILE="/tmp/.myspec-code-changed-${SESSION_ID}"

if [ -z "$SESSION_ID" ] || [ ! -f "$MARKER_FILE" ]; then
  # No code files changed by Claude this session — skip verification
  echo '{"decision": "approve"}'
  exit 0
fi

# A symlinked dependency directory (node_modules, vendor, .venv, ...) makes
# every check below run against ANOTHER checkout dependency tree, so the gate
# reports a green that describes the wrong tree. That silent false pass is
# worse than no gate at all, so block. The marker is deliberately left in
# place (the EXIT trap is registered below) so the block persists until a
# real install exists.
# Checked: every isolation.provision.symlink entry, plus each built-in
# dependency directory at the root (DEP_DIRS) the config does not list, so a
# hand-made link into another checkout of this repo is caught too (one into a
# central virtualenv store is left alone). An entry is guarded by the
# lockfiles the map below gives it; an entry with none (an .env file) is not
# checked. A tree that loads the project's own source from the other checkout
# (tree_loads_checkout) blocks whatever its lockfiles say.
# Accepted without config when the link points into a checkout whose copies of
# those lockfiles are byte-identical to this tree (committed and uncommitted
# state alike): both trees then resolve the same dependencies, which is
# exactly the case worktree-provision.sh links (it skips the link when the
# branch changes a lockfile against --base). Comparing contents rather than
# re-running the ref diff also holds when the main checkout is not at the base
# ref. At least one lockfile must exist; without one there is no evidence the
# trees match.
# Deliberate link otherwise: isolation.allowLinkedModules: true in .myspec.json
# (project-wide, for repos whose worktrees share the main checkout
# dependencies by construction) or MYSPEC_ALLOW_LINKED_MODULES=1. Both cover
# every dependency directory, not only node_modules.
# BEGIN dependency-lockfile map
# Byte-identical in hooks/verify-before-stop.sh and lib/worktree-provision.sh
# (the two ship separately, so neither can source the other); a test in
# lib/tests/worktree-provision.test.sh fails when they drift.
#
# An isolation.provision.symlink entry is a string ("vendor") or an object
# ({"path": "vendor", "lockfiles": ["composer.lock"]}). An object with
# "lockfiles" names the files that pin that tree, repo-relative, globs allowed
# (a * stays within one directory, as in the shell); "lockfiles": [] declares
# it unguarded. A string, or an object without a usable "lockfiles", takes the
# lockfiles of a well-known dependency directory from dep_lockfiles below and
# matches them both beside the project that owns the entry and at the repo
# root (a nested apps/web/node_modules is pinned by either). Anything else (an
# .env file, a cache) is unguarded: it pins no dependency set, and guarding it
# would block every stop that links one.
DEP_DIRS="node_modules vendor vendor/bundle .venv venv"

# dep_lockfiles <path> -> the lockfile names that pin that directory.
# vendor is shared by Composer, Bundler and Go modules, so it lists all three;
# only the lockfiles that exist take part in a comparison. vendor/bundle is
# Bundler's own install path, keyed by path because "bundle" alone is generic.
dep_lockfiles() {
  case "$1" in
    vendor/bundle|*/vendor/bundle) printf '%s\n' Gemfile.lock; return ;;
  esac
  case "${1##*/}" in
    node_modules) printf '%s\n' package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock ;;
    vendor) printf '%s\n' composer.lock Gemfile.lock go.sum ;;
    .venv|venv) printf '%s\n' poetry.lock Pipfile.lock uv.lock pdm.lock 'requirements*.txt' ;;
  esac
}

# infer_entry <path> -> "path<TAB>lockfile<TAB>..." from the built-in map.
infer_entry() {
  local path="$1" parent lock line
  case "$path" in
    vendor/bundle|*/vendor/bundle) parent=$(dirname "$(dirname "$path")") ;;
    *) parent=$(dirname "$path") ;;
  esac
  line="$path"
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    [ "$parent" = "." ] || line="$line"$'\t'"$parent/$lock"
    line="$line"$'\t'"$lock"
  done < <(dep_lockfiles "$path")
  printf '%s\n' "$line"
}

# symlink_entries <.myspec.json> -> one "path<TAB>lockfile<TAB>..." line per
# configured entry; a line with no lockfile is an unguarded entry. A missing
# config means the default ["node_modules"]; an unreadable one means none. A
# malformed entry is dropped on its own, never taking the others with it, and
# a "lockfiles" that is not a list falls back to the built-in map.
symlink_entries() {
  local raw line path mode rest
  if [ -f "$1" ] && command -v jq >/dev/null 2>&1; then
    raw=$(jq -r '(.isolation.provision.symlink // ["node_modules"])
      | if type == "array" then .[] elif type == "string" then . else empty end
      | if type == "string" then [., "-"]
        elif type == "object" and (.path | type) == "string" then
          (.lockfiles | if type == "array" then . elif type == "string" then [.] else null end) as $l
          | if $l == null then [.path, "-"]
            else [.path, "="] + [$l[] | select(type == "string" and . != "")] end
        else empty end
      | @tsv' "$1" 2>/dev/null) || raw=""
  else
    raw=$'node_modules\t-'
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    mode="${rest%%$'\t'*}"
    while [ "${path#./}" != "$path" ]; do path="${path#./}"; done
    path="${path%/}"
    [ -n "$path" ] || continue
    if [ "$mode" = "-" ]; then
      infer_entry "$path"
    elif [ "$rest" = "=" ]; then
      printf '%s\n' "$path"
    else
      printf '%s\t%s\n' "$path" "${rest#=$'\t'}"
    fi
  done <<< "$raw"
}

# tree_loads_checkout <tree> <checkout> -> 0 when the dependency tree at
# <tree> loads the project's OWN source from <checkout> (a physical path).
# A link to such a tree runs that checkout's code, not this one's, however
# identical the lockfiles are. Composer writes the root package's autoload
# rules against $baseDir, which PHP resolves through the link; an editable
# Python install (poetry, uv, pip -e) records its source in direct_url.json.
tree_loads_checkout() {
  local tree="$1" checkout="$2" f url dir
  grep -qsF '$baseDir . ' "$tree"/composer/autoload_*.php && return 0
  for f in "$tree"/lib/python*/site-packages/*.dist-info/direct_url.json; do
    [ -f "$f" ] || continue
    url=$(jq -r 'select(.dir_info.editable == true) | .url // empty' "$f" 2>/dev/null) || continue
    case "$url" in file://*) ;; *) continue ;; esac
    dir=$(cd "${url#file://}" 2>/dev/null && pwd -P) || continue
    case "$dir/" in "$checkout"/*) return 0 ;; esac
  done
  return 1
}
# END dependency-lockfile map

# link_source <entry> -> the checkout <entry> links into: the link target
# with <entry> removed. Fails when the target is not <checkout>/<entry>, or is
# this tree.
link_source() {
  local target src
  target=$(cd "$REPO_ROOT/$1" 2>/dev/null && pwd -P) || return 1
  case "$target" in
    */"$1") src="${target%/"$1"}" ;;
    *) return 1 ;;
  esac
  [ "$src" != "$REPO_ROOT" ] || return 1
  printf '%s\n' "$src"
}

# common_dir <dir> -> the physical git common dir of the checkout at <dir>.
common_dir() {
  local d
  d=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$1" && cd "$d" && pwd -P)
}

# lockfiles_match <src> <lockfile-pattern>... -> 0 when checkout <src> holds
# byte-identical copies of every matching lockfile, and at least one exists.
lockfiles_match() {
  local src="$1" pat f rel seen=0
  shift
  for pat in "$@"; do
    for f in "$REPO_ROOT"/$pat "$src"/$pat; do
      [ -e "$f" ] || continue
      case "$f" in
        "$REPO_ROOT"/*) rel="${f#"$REPO_ROOT"/}" ;;
        *) rel="${f#"$src"/}" ;;
      esac
      cmp -s "$REPO_ROOT/$rel" "$src/$rel" || return 1
      seen=1
    done
  done
  [ "$seen" -eq 1 ]
}

# guarded_entries -> "configured|inferred<TAB>path<TAB>lockfile..." for the
# configured entries, then the built-in directories the config does not name.
guarded_entries() {
  local configured paths dir l
  configured=$(symlink_entries "$REPO_ROOT/.myspec.json")
  paths=$'\n'$(printf '%s\n' "$configured" | cut -f1)$'\n'
  while IFS= read -r l; do
    [ -n "$l" ] && printf 'configured\t%s\n' "$l"
  done <<< "$configured"
  for dir in $DEP_DIRS; do
    case "$paths" in
      *$'\n'"$dir"$'\n'*) ;;
      *) printf 'inferred\t%s\n' "$(infer_entry "$dir")" ;;
    esac
  done
}

ALLOW_LINKED=$(jq -r '.isolation.allowLinkedModules // false' "$REPO_ROOT/.myspec.json" 2>/dev/null || printf 'false')
if [ "$ALLOW_LINKED" != "true" ] && [ "${MYSPEC_ALLOW_LINKED_MODULES:-}" != "1" ]; then
  STALE_LINKS=""
  while IFS= read -r line; do
    kind="${line%%$'\t'*}"
    line="${line#*$'\t'}"
    entry="${line%%$'\t'*}"
    [ -n "$entry" ] && [ "$line" != "$entry" ] || continue
    [ -L "$REPO_ROOT/$entry" ] || continue
    src=$(link_source "$entry") || src=""
    # An unlisted directory is only this gate's business when it links into
    # another checkout of this repo. node_modules keeps its stricter rule.
    if [ "$kind" = inferred ] && [ "$entry" != node_modules ] \
        && { [ -z "$src" ] || [ "$(common_dir "$src")" != "$(common_dir "$REPO_ROOT")" ]; }; then
      continue
    fi
    IFS=$'\t' read -ra LOCKS <<< "${line#*$'\t'}"
    if [ -z "$src" ] || ! lockfiles_match "$src" "${LOCKS[@]}" \
        || tree_loads_checkout "$REPO_ROOT/$entry" "$src"; then
      STALE_LINKS="${STALE_LINKS:+$STALE_LINKS, }$entry"
    fi
  done < <(guarded_entries)
  if [ -n "$STALE_LINKS" ]; then
    REASON=$(printf 'Symlinked dependency directory in %s: %s. The lockfiles that pin it differ from the checkout it points into (or none exists), or the tree loads the project source from that checkout, so lint, type-check and test results here describe a different dependency tree. Run a real install in this worktree before reporting any result as verified (or, if this repo shares one tree by design, set isolation.allowLinkedModules: true in .myspec.json).' "$REPO_ROOT" "$STALE_LINKS" | jq -Rs .)
    echo "{\"decision\": \"block\", \"reason\": $REASON}"
    exit 0
  fi
fi

# Clean up marker after verification runs (success or failure)
trap 'rm -f "$MARKER_FILE"' EXIT

# Per-check time cap. A check that outlives it is killed and reported as
# timed out: the result is unknown, which is not a failure, and the report must
# say which one it is (a green suite killed at the cap once read as a red one).
# MYSPEC_CHECK_CAP_SECONDS may lower the cap (the hook tests use it); a value
# above the default is ignored, so it can never raise it.
CHECK_CAP_SECONDS=120
if [[ "${MYSPEC_CHECK_CAP_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] && [ "$MYSPEC_CHECK_CAP_SECONDS" -lt "$CHECK_CAP_SECONDS" ]; then
  CHECK_CAP_SECONDS=$MYSPEC_CHECK_CAP_SECONDS
fi
CAP_SENTINEL=$(mktemp "${TMPDIR:-/tmp}/.myspec-cap.XXXXXX")
rm -f "$CAP_SENTINEL"

# run_with_cap <command>: runs it under the cap and kills the whole process
# group at the deadline. Killing only the direct child is not enough: a test
# runner's workers inherit the output pipe, the $(...) capture waits for them,
# and the hook then waits for the full run anyway (measured: 456 s under a
# 120 s cap). perl is in the macOS base system and in nearly every Linux
# image; it puts the check in its own process group, SIGTERMs the group at the
# deadline (SIGKILL once the check exits, at most 5 s later) and touches $CAP_SENTINEL so the caller knows
# the exit was the cap's, not the command's own. Without perl, GNU timeout
# also signals the group; its exit 124 is ambiguous, so the caller also checks
# the elapsed time. With neither, the check runs uncapped.
run_with_cap() {
  if command -v perl &>/dev/null; then
    perl -e '
      my ($cap, $sentinel) = (shift, shift);
      my $pid = fork() // exit 127;
      if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
      setpgrp($pid, $pid);
      local $SIG{ALRM} = sub {
        open(my $fh, ">", $sentinel); close($fh);
        kill "TERM", -$pid;
        for (1 .. 50) { last if waitpid($pid, 1) > 0; select(undef, undef, undef, 0.1) }
        kill "KILL", -$pid; waitpid($pid, 0); exit 124;
      };
      alarm $cap;
      waitpid($pid, 0);
      alarm 0;
      exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
    ' "$CHECK_CAP_SECONDS" "$CAP_SENTINEL" bash -c "$1"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$CHECK_CAP_SECONDS" bash -c "$1"
  elif command -v timeout &>/dev/null; then
    timeout "$CHECK_CAP_SECONDS" bash -c "$1"
  else
    bash -c "$1"
  fi
}

# Base ref for diff-scoped checks. A repo whose lint or type-check is already
# red on the default branch cannot use a whole-repo command as a gate — it
# blocks every stop over debt this session did not create, and the block is
# indistinguishable from a real regression. Such a check declares a
# `diffCommand` instead, and this is the ref it measures against: the merge
# base with the default branch, so the range is "what this branch changed"
# on a feature branch and "what is uncommitted" when HEAD is that branch.
# Left empty when no default branch resolves (a repo with no remote and no
# main/master); the loop below then falls back to the whole-repo command
# rather than skipping the check.
MYSPEC_BASE_REF=""
DEFAULT_REF=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
if [ -z "$DEFAULT_REF" ]; then
  for CANDIDATE in origin/main origin/master main master; do
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "$CANDIDATE" >/dev/null 2>&1; then
      DEFAULT_REF="$CANDIDATE"
      break
    fi
  done
fi
if [ -n "$DEFAULT_REF" ]; then
  MYSPEC_BASE_REF=$(git -C "$REPO_ROOT" merge-base HEAD "$DEFAULT_REF" 2>/dev/null || printf '')
fi
export MYSPEC_BASE_REF

# Orchestration marker. While /myspec:feature-implement runs, the controller
# ends many turns on a tree that is red by design: a barrier accepted with a
# recorded failure, a fix round in flight in a subagent, a failing test owned
# by the next phase. Blocking there forces a turn the controller cannot use
# (it may not fix code itself), so failures downgrade to a non-blocking
# warning. The skill writes the marker at setup and removes it before its
# final verification; feature-complete removes it too. It lives in the
# checkout the session works in, not the primary one: it describes this tree,
# and a concurrent run in another worktree must keep its own gate. A marker
# older than IMPLEMENT_MARKER_TTL (8h, the isolation-decision TTL) or without
# a readable started_at is a crashed run: it is deleted and the gate blocks.
# Only the verification.json checks are downgraded; the conformance and
# symlink blocks above are session damage, not expected red.
IMPLEMENT_MARKER="$REPO_ROOT/.claude/state/implement-in-progress.json"
IMPLEMENT_MARKER_TTL=28800
IMPLEMENT_ACTIVE=0
if [ -f "$IMPLEMENT_MARKER" ]; then
  STARTED_AT=$(jq -r '.started_at // empty' "$IMPLEMENT_MARKER" 2>/dev/null || printf '')
  case "$STARTED_AT" in
    ''|*[!0-9]*) STARTED_AT="" ;;
  esac
  if [ -n "$STARTED_AT" ]; then
    MARKER_AGE=$(( $(date +%s) - STARTED_AT ))
    if [ "$MARKER_AGE" -ge 0 ] && [ "$MARKER_AGE" -le "$IMPLEMENT_MARKER_TTL" ]; then
      IMPLEMENT_ACTIVE=1
    fi
  fi
  if [ "$IMPLEMENT_ACTIVE" -eq 0 ]; then
    rm -f "$IMPLEMENT_MARKER"
  fi
fi

# Run each required check
FAILED_CHECKS=()
TIMED_OUT_CHECKS=()
FAILED_OUTPUT=()

CHECKS_COUNT=$(jq '.checks | length' "$CONFIG_FILE")

for i in $(seq 0 $((CHECKS_COUNT - 1))); do
  REQUIRED=$(jq -r ".checks[$i].required" "$CONFIG_FILE")
  if [ "$REQUIRED" != "true" ]; then
    continue
  fi

  NAME=$(jq -r ".checks[$i].name" "$CONFIG_FILE")
  COMMAND=$(jq -r ".checks[$i].command" "$CONFIG_FILE")
  DIFF_COMMAND=$(jq -r ".checks[$i].diffCommand // \"\"" "$CONFIG_FILE")

  if [ -n "${DIFF_COMMAND// /}" ] && [ -n "$MYSPEC_BASE_REF" ]; then
    COMMAND="$DIFF_COMMAND"
  fi

  rm -f "$CAP_SENTINEL"
  CHECK_START=$(date +%s)
  OUTPUT=$(cd "$REPO_ROOT" && MYSPEC_STOP_HOOK_ACTIVE=1 run_with_cap "$COMMAND" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
  CHECK_ELAPSED=$(( $(date +%s) - CHECK_START ))

  if [ "$EXIT_CODE" -ne 0 ]; then
    # Keep the end of the output: it names the result (a summary line, the
    # last error). The first 2000 characters of the last 50 lines cut that
    # end off mid-line.
    TRUNCATED=$(printf '%s\n' "$OUTPUT" | tail -50 | tail -c 2000)
    TIMED_OUT=0
    if [ -f "$CAP_SENTINEL" ]; then
      TIMED_OUT=1
    elif [ "$EXIT_CODE" -eq 124 ] && [ "$CHECK_ELAPSED" -ge "$CHECK_CAP_SECONDS" ]; then
      TIMED_OUT=1
    fi
    if [ "$TIMED_OUT" -eq 1 ]; then
      TIMED_OUT_CHECKS+=("$NAME")
      FAILED_OUTPUT+=("[$NAME timed out after ${CHECK_CAP_SECONDS}s] $COMMAND was killed before it finished, so its result is unknown. This is not a test failure. Run the check directly and report its real exit code; if it passes but is slow, reduce its runtime (narrow what it runs). Do not raise the cap. Output so far:"$'\n'"$TRUNCATED")
    else
      FAILED_CHECKS+=("$NAME")
      FAILED_OUTPUT+=("[$NAME] $COMMAND failed:"$'\n'"$TRUNCATED")
    fi
  fi
done
rm -f "$CAP_SENTINEL"

if [ ${#FAILED_CHECKS[@]} -gt 0 ] || [ ${#TIMED_OUT_CHECKS[@]} -gt 0 ]; then
  # The headline separates the two outcomes: "failed" is a result, "timed
  # out" is the absence of one.
  NAMES=""
  if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
    NAMES=$(printf '%s, ' "${FAILED_CHECKS[@]}"); NAMES="failed: ${NAMES%, }"
  fi
  if [ ${#TIMED_OUT_CHECKS[@]} -gt 0 ]; then
    TIMED=$(printf '%s, ' "${TIMED_OUT_CHECKS[@]}"); TIMED="timed out after ${CHECK_CAP_SECONDS}s, result unknown: ${TIMED%, }"
    if [ -n "$NAMES" ]; then
      NAMES="$NAMES; $TIMED"
    else
      NAMES="$TIMED"
    fi
  fi
  # Join with real newline-delimited separators (multi-char IFS joins only
  # use the first character, so the old IFS="\n---\n" emitted literal '\')
  DETAILS=""
  for ENTRY in "${FAILED_OUTPUT[@]}"; do
    DETAILS+="${ENTRY}"$'\n---\n'
  done
  DETAILS=${DETAILS%$'\n---\n'}
  if [ "$IMPLEMENT_ACTIVE" -eq 1 ]; then
    # Non-blocking: no decision block, so the stop proceeds; systemMessage
    # surfaces the failure to the user.
    MESSAGE=$(printf "Verification failing (%s) during feature-implement orchestration; not blocking (marker %s). The final verification step still gates.\n\n%s" "$NAMES" ".claude/state/implement-in-progress.json" "$DETAILS" | jq -Rs .)
    echo "{\"decision\": \"approve\", \"systemMessage\": $MESSAGE}"
    exit 0
  fi
  # Escape for JSON
  REASON=$(printf "Verification did not pass (%s). Fix failures before completing; for a timeout, get the real result first.\n\n%s" "$NAMES" "$DETAILS" | jq -Rs .)
  echo "{\"decision\": \"block\", \"reason\": $REASON}"
  exit 0
fi

echo '{"decision": "approve"}'
