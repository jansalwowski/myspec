#!/usr/bin/env bash
# verify-before-stop.sh
# Stop hook — runs verification checks before agent completes.
# Reads commands from .claude/verification.json (requires jq).
# Outputs {"decision": "block", "reason": "..."} on failure or {"decision": "approve"} on success.
# The checks run in each checkout of this repository where the session wrote
# code since the last run (the ledger mark-code-changed.sh keeps), a linked
# worktree edited from a main-checkout cwd included. A failure that names only
# files another session left uncommitted there becomes a non-blocking
# systemMessage warning. Requirements behind each rule: docs/stop-gate.md in
# the plugin repository.
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
# report, not a reason to block a stop. Only errors block (the doctor exits 1
# on errors alone): a duplicate ID that lives only on stale branches is a
# warning, since no change in this session can fix it (issue #124).
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

# Whether to verify, and which checkouts. mark-code-changed.sh (PostToolUse)
# appends every file the session writes to a per-session ledger, keyed by the
# physical root of the checkout holding it (docs/stop-gate.md in the plugin
# repo). A checkout is armed when a `code` line for its root comes after its
# last `verified` line. Each armed checkout of this repository (same git common
# dir as the cwd's) is verified, once: the harness cwd is not necessarily where
# the edits are, and verifying an untouched main checkout while the session
# edited a linked worktree reports a green that describes the wrong tree. A
# research session over a dirty tree, and a session whose writes all landed in
# another repository, run no checks. The empty marker the ledger replaced
# (/tmp/.myspec-code-changed-<id>, written by an older hook) arms the cwd's
# checkout, with attribution off: it carries no list of what the session wrote.
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
LEDGER="/tmp/.myspec-session-writes-${SESSION_ID}"
LEGACY_MARKER="/tmp/.myspec-code-changed-${SESSION_ID}"
ORIG_ROOT=$(cd "$REPO_ROOT" && pwd -P)
VERIFY_ROOTS=()
ATTRIBUTE=1

# physical_common_dir <dir> -> the physical git common dir of the checkout.
physical_common_dir() {
  local d
  d=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$1" && cd "$d" && pwd -P)
}

add_verify_root() {
  local r
  for r in ${VERIFY_ROOTS[@]+"${VERIFY_ROOTS[@]}"}; do
    [ "$r" = "$1" ] && return 0
  done
  VERIFY_ROOTS+=("$1")
}

# armed_roots -> each root with a `code` line after its last `verified` line,
# in first-written order.
armed_roots() {
  awk -F'\t' '
    $1 == "verified" { armed[$2] = 0; next }
    $1 == "code" {
      if (!($2 in seen)) { seen[$2] = 1; roots[++n] = $2 }
      armed[$2] = 1
    }
    END { for (i = 1; i <= n; i++) if (armed[roots[i]]) print roots[i] }' "$LEDGER"
}

# same_repo <root> -> 0 when <root> is a checkout of the cwd's repository (the
# cwd's own root, for a project without git).
ORIG_COMMON=$(physical_common_dir "$ORIG_ROOT" 2>/dev/null || printf '')
same_repo() {
  if [ -n "$ORIG_COMMON" ]; then
    [ "$(physical_common_dir "$1" 2>/dev/null || printf '')" = "$ORIG_COMMON" ]
  else
    [ "$1" = "$ORIG_ROOT" ]
  fi
}

# A checkout nested inside the cwd's tree that is not a checkout of this
# repository (a submodule, whose common dir is .git/modules/<name>) is
# verified through the cwd's checkout, whose checks may build or test it. Its
# root still gets its `verified` line (NESTED_ROOTS).
NESTED_ROOTS=()
if [ -n "$SESSION_ID" ]; then
  if [ -f "$LEDGER" ]; then
    while IFS= read -r root; do
      [ -d "$root" ] || continue
      if same_repo "$root"; then
        add_verify_root "$root"
      else
        case "$root/" in
          "$ORIG_ROOT"/*)
            add_verify_root "$ORIG_ROOT"
            NESTED_ROOTS+=("$root")
            ;;
        esac
      fi
    done < <(armed_roots)
  fi
  if [ -f "$LEGACY_MARKER" ]; then
    ATTRIBUTE=0
    add_verify_root "$ORIG_ROOT"
  fi
fi

if [ "${#VERIFY_ROOTS[@]}" -eq 0 ]; then
  # No code written in this repository since the last run — skip verification
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

for REPO_ROOT in "${VERIFY_ROOTS[@]}"; do
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
done

# Once the checks run (success or failure), the ledger gets a `verified` line
# for each verified checkout, so only a later code write re-arms it, and a
# legacy marker is removed. The ledger itself stays: it is the list of what
# this session wrote, which attribution below needs on every later run.
finish_run() {
  local r
  rm -f "$LEGACY_MARKER"
  if [ -f "$LEDGER" ]; then
    for r in "${VERIFY_ROOTS[@]}" ${NESTED_ROOTS[@]+"${NESTED_ROOTS[@]}"}; do
      printf 'verified\t%s\t-\n' "$r" >> "$LEDGER"
    done
  fi
}
trap 'finish_run' EXIT

# Per-check time cap. A check that outlives it is killed and reported as
# timed out: the result is unknown, which is not a failure, and the report must
# say which one it is (a green suite killed at the cap once read as a red one).
# MYSPEC_CHECK_CAP_SECONDS may lower the cap (the hook tests use it); a value
# above the default is ignored, so it can never raise it.
CHECK_CAP_SECONDS=120
if [[ "${MYSPEC_CHECK_CAP_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] && [ "$MYSPEC_CHECK_CAP_SECONDS" -lt "$CHECK_CAP_SECONDS" ]; then
  CHECK_CAP_SECONDS=$MYSPEC_CHECK_CAP_SECONDS
fi
# A check's cleanup command (below) gets its own cap, lowered with the check
# cap and never above 30 s.
CLEANUP_CAP_SECONDS=30
[ "$CHECK_CAP_SECONDS" -lt "$CLEANUP_CAP_SECONDS" ] && CLEANUP_CAP_SECONDS=$CHECK_CAP_SECONDS
CAP_SENTINEL=$(mktemp "${TMPDIR:-/tmp}/.myspec-cap.XXXXXX")
rm -f "$CAP_SENTINEL"
CHECK_LOG=""
CHECK_RUN_LOG=""
trap 'finish_run; rm -f "$CAP_SENTINEL" ${CHECK_LOG:+"$CHECK_LOG"} ${CHECK_RUN_LOG:+"$CHECK_RUN_LOG"} ${FAILED_LOGS[@]+"${FAILED_LOGS[@]}"}' EXIT

# run_with_cap <seconds> <command>: runs it under the cap and kills the whole
# process group at the deadline. Killing only the direct child is not enough:
# a test runner's workers would keep running (measured: 456 s under a 120 s
# cap). perl is in the macOS base system and in nearly every Linux image; it
# puts the command in its own process group, SIGTERMs the group at the
# deadline (SIGKILL once the command exits, at most 5 s later) and touches
# $CAP_SENTINEL so the caller knows the exit was the cap's, not the command's
# own. When the command exits on its own, whatever it left in its group (a
# server started with &, workers that did not exit) is killed too: nothing
# will read their output. Without perl, GNU timeout also signals the group at
# the deadline (it leads the group it runs in), and kill_group reaps the rest
# after it returns; its exit 124 is ambiguous, so the caller also checks the
# elapsed time. With neither, the command runs uncapped and its leftovers
# are not reaped.
# The group kill reaches only processes on this machine that stay in the
# group. Work a command runs in a container or on another host (docker exec,
# kubectl exec, ssh) outlives its client; the check's cleanup command is how
# the project stops it.
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
      my $rc = ($? & 127) ? 128 + ($? & 127) : $? >> 8;
      if (kill 0, -$pid) {
        kill "TERM", -$pid;
        for (1 .. 20) { last unless kill 0, -$pid; select(undef, undef, undef, 0.1) }
        kill "KILL", -$pid;
      }
      exit $rc;
    ' "$1" "$CAP_SENTINEL" bash -c "$2"
  elif command -v gtimeout &>/dev/null || command -v timeout &>/dev/null; then
    local bin pid rc=0
    bin=$(command -v gtimeout || command -v timeout)
    "$bin" "$1" bash -c "$2" &
    pid=$!
    wait "$pid" || rc=$?
    kill_group "$pid"
    return "$rc"
  else
    bash -c "$2"
  fi
}

# kill_group <pgid>: TERM what is left of the process group, KILL after 2 s.
# A group that no longer exists (or a timeout that did not lead one) is a
# no-op.
kill_group() {
  local n
  kill -TERM -- "-$1" 2>/dev/null || return 0
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 -- "-$1" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$1" 2>/dev/null || true
}

# capped <exit code> <elapsed> <cap> -> 0 when the exit was the cap's.
capped() {
  [ -f "$CAP_SENTINEL" ] || { [ "$1" -eq 124 ] && [ "$2" -ge "$3" ]; }
}

# run_capped <seconds> <command> <run id> [keep]: runs <command> from the repo
# root under run_with_cap. Sets RUN_EXIT, RUN_ELAPSED and RUN_OUTPUT. With
# keep, the output file stays and RUN_LOG names it: the caller removes it, or
# keeps a failed check's log for attribution to read.
# Output goes to a file, not a $(...) capture: a process that escapes the
# group kill (it called setsid, or it is a detaching daemon) would otherwise
# hold the pipe open and keep the hook waiting until it exits on its own,
# whatever the cap says. Each run gets its own file, removed after reading,
# because such a process keeps writing to it: a shared file would put its
# output into the next check's report.
run_capped() {
  local start
  rm -f "$CAP_SENTINEL"
  CHECK_LOG=$(mktemp "${TMPDIR:-/tmp}/.myspec-check.XXXXXX")
  start=$(date +%s)
  (cd "$REPO_ROOT" && MYSPEC_STOP_HOOK_ACTIVE=1 MYSPEC_CHECK_RUN_ID="$3" run_with_cap "$1" "$2") \
    >"$CHECK_LOG" 2>&1 </dev/null && RUN_EXIT=0 || RUN_EXIT=$?
  RUN_ELAPSED=$(( $(date +%s) - start ))
  RUN_OUTPUT=$(cat "$CHECK_LOG")
  RUN_LOG=""
  if [ -n "${4:-}" ]; then
    RUN_LOG="$CHECK_LOG"
  else
    rm -f "$CHECK_LOG"
  fi
  CHECK_LOG=""
}

# Attribution (docs/stop-gate.md, R4). When several sessions share one
# checkout, a red check may come from another session's uncommitted work
# (#198). T is the files this session wrote here (the ledger). F is the
# uncommitted and untracked files outside T. A failure is this session's when
# its output names a file in T, matched by basename, which errs toward
# blocking. The stop warns instead of blocking only when every failed check
# names a file in F and none names one in T, and nothing timed out. F is
# matched by its full repo-relative path, which errs toward blocking too: a
# package-relative path in a monorepo tool's output does not match.

# session_files -> repo-relative paths this session wrote in this checkout,
# including those in a checkout nested inside it (a submodule).
session_files() {
  R="$ROOT_KEY" awk -F'\t' '
    $1 != "code" && $1 != "file" { next }
    $2 == ENVIRON["R"] { print $3; next }
    index($2, ENVIRON["R"] "/") == 1 { print substr($2, length(ENVIRON["R"]) + 2) "/" $3 }' "$LEDGER" | sort -u
}

# changed_files -> uncommitted and untracked paths, both sides of a rename.
changed_files() {
  local entry second=0
  while IFS= read -r -d '' entry; do
    if [ "$second" -eq 1 ]; then
      second=0
      printf '%s\n' "$entry"
      continue
    fi
    printf '%s\n' "${entry:3}"
    case "${entry:0:2}" in
      *R*|*C*) second=1 ;;
    esac
  done < <(git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
}

# names_in <base|full> <paths file> <output file> -> the listed paths the output
# names. The output is split into runs of path characters, and each run is
# looked up: by basename in base mode; in full mode as a repo-relative path,
# once a leading ./ or this checkout's root is dropped. A lookup, not a
# substring scan per path, keeps a multi-megabyte test log under a second.
names_in() {
  MODE="$1" ROOT="$ROOT_KEY/" awk '
    FILENAME == ARGV[1] {
      key = $0
      if (ENVIRON["MODE"] == "base") sub(/.*\//, "", key)
      if (key == "") next
      if (key in want) want[key] = want[key] "\n" $0
      else want[key] = $0
      next
    }
    {
      gsub(/[^A-Za-z0-9_.@\/-]+/, " ")
      n = split($0, tok, " ")
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t in seen) continue
        seen[t] = 1
        sub(/\.+$/, "", t)
        if (ENVIRON["MODE"] == "base") {
          sub(/.*\//, "", t)
        } else {
          r = ENVIRON["ROOT"]
          if (substr(t, 1, length(r)) == r) t = substr(t, length(r) + 1)
          while (substr(t, 1, 2) == "./") t = substr(t, 3)
        }
        if ((t in want) && !(t in hit)) {
          hit[t] = 1
          print want[t]
        }
      }
    }' "$2" "$3"
}

# join_lines <max> -> the first <max> lines of stdin joined with ", ". It
# reads all of stdin: `head` would exit early, and under pipefail the
# writer's SIGPIPE would become the hook's own exit, with no decision printed.
join_lines() {
  awk -v max="$1" 'NR <= max { printf "%s%s", (NR > 1 ? ", " : ""), $0 }'
}

# short_list <file> <max> -> "a, b, c and N more"
short_list() {
  local total list
  total=$(grep -c . "$1" || true)
  list=$(join_lines "$2" < "$1")
  if [ "$total" -gt "$2" ]; then
    list="$list and $((total - $2)) more"
  fi
  printf '%s' "$list"
}

# attribute_failures: for the checks of the checkout at ROOT_KEY (from index
# ROOT_FAILED_START on), sets ATTRIBUTION (a paragraph for the report, empty
# when every uncommitted change there is this session's) and ATTRIBUTION_WARN=1
# when its failures should warn instead of block.
attribute_failures() {
  local tfile ffile i own foreign where lines="" unknown=0 owned=0
  ATTRIBUTION=""
  ATTRIBUTION_WARN=0
  tfile=$(mktemp "${TMPDIR:-/tmp}/.myspec-attr.XXXXXX")
  ffile=$(mktemp "${TMPDIR:-/tmp}/.myspec-attr.XXXXXX")
  session_files > "$tfile"
  # .claude/state/ is per-checkout hook state, not anyone's work. At most 1000
  # paths take part: past that, a failure matches nothing, which blocks.
  changed_files | grep -v '^\.claude/state/' | sort -u | grep -vxF -f "$tfile" | awk 'NR <= 1000' > "$ffile" || true
  if [ ! -s "$ffile" ]; then
    rm -f "$tfile" "$ffile"
    return 0
  fi
  for ((i = ROOT_FAILED_START; i < ${#FAILED_CHECKS[@]}; i++)); do
    own=$(names_in base "$tfile" "${FAILED_LOGS[$i]}" | join_lines 5)
    if [ -n "$own" ]; then
      owned=1
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names files this session wrote: $own"
      continue
    fi
    foreign=$(names_in full "$ffile" "${FAILED_LOGS[$i]}" | join_lines 5)
    if [ -n "$foreign" ]; then
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names only files changed outside this session: $foreign"
    else
      unknown=1
      lines="$lines"$'\n'"- ${FAILED_CHECKS[$i]} names none of the changed files"
    fi
  done
  if [ "$owned" -eq 0 ] && [ "$unknown" -eq 0 ] && [ ${#TIMED_OUT_CHECKS[@]} -eq "$ROOT_TIMED_START" ]; then
    ATTRIBUTION_WARN=1
  fi
  where="This checkout"
  [ "$ROOT_KEY" = "$ORIG_ROOT" ] || where="The checkout at $ROOT_KEY"
  ATTRIBUTION="$where has uncommitted changes this session did not write ($(short_list "$ffile" 10)), so a failure may not be yours.$lines"
  rm -f "$tfile" "$ffile"
}

# Run each required check, once per checkout to verify.
FAILED_CHECKS=()
# The output file of each failed check, parallel to FAILED_CHECKS, for
# attribution to read; removed on exit.
FAILED_LOGS=()
TIMED_OUT_CHECKS=()
FAILED_OUTPUT=()
# A failure blocks unless its checkout carries a live feature-implement marker
# or attribution clears it (above). Notes say which, for the report.
BLOCKING_FAILURE=0
WARN_NOTES=()
BLOCK_NOTES=()

for REPO_ROOT in "${VERIFY_ROOTS[@]}"; do
ROOT_CONFIG="$REPO_ROOT/.claude/verification.json"
[ -f "$ROOT_CONFIG" ] || ROOT_CONFIG="$CONFIG_FILE"
# Names a check by its checkout when that is not the cwd checkout.
ROOT_LABEL=""
[ "$REPO_ROOT" = "$ORIG_ROOT" ] || ROOT_LABEL=" [in $REPO_ROOT]"
ROOT_FAILURES=${#FAILED_OUTPUT[@]}
ROOT_FAILED_START=${#FAILED_CHECKS[@]}
ROOT_TIMED_START=${#TIMED_OUT_CHECKS[@]}
ROOT_KEY="$REPO_ROOT"
# The files this session wrote in this checkout, one repo-relative path per
# line, for a check that scopes itself to them (a per-file linter). Empty
# when a legacy marker armed the gate.
MYSPEC_SESSION_FILES=""
if [ "$ATTRIBUTE" -eq 1 ] && [ -f "$LEDGER" ]; then
  MYSPEC_SESSION_FILES=$(session_files)
fi
export MYSPEC_SESSION_FILES

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

CHECKS_COUNT=$(jq '.checks | length' "$ROOT_CONFIG")

for i in $(seq 0 $((CHECKS_COUNT - 1))); do
  REQUIRED=$(jq -r ".checks[$i].required" "$ROOT_CONFIG")
  if [ "$REQUIRED" != "true" ]; then
    continue
  fi

  NAME=$(jq -r ".checks[$i].name" "$ROOT_CONFIG")$ROOT_LABEL
  COMMAND=$(jq -r ".checks[$i].command" "$ROOT_CONFIG")
  DIFF_COMMAND=$(jq -r ".checks[$i].diffCommand // \"\"" "$ROOT_CONFIG")
  CLEANUP=$(jq -r ".checks[$i].cleanup // \"\"" "$ROOT_CONFIG")

  if [ -n "${DIFF_COMMAND// /}" ] && [ -n "$MYSPEC_BASE_REF" ]; then
    COMMAND="$DIFF_COMMAND"
  fi

  # Exported to the check and to its cleanup, so a wrapper that starts work
  # the group kill cannot reach can tag it and the cleanup can find it.
  RUN_ID="myspec-$(date +%s)-$$-$i"
  run_capped "$CHECK_CAP_SECONDS" "$COMMAND" "$RUN_ID" keep
  CHECK_RUN_LOG=$RUN_LOG
  EXIT_CODE=$RUN_EXIT
  OUTPUT=$RUN_OUTPUT

  if [ "$EXIT_CODE" -ne 0 ]; then
    # Keep the end of the output: it names the result (a summary line, the
    # last error). The first 2000 characters of the last 50 lines cut that
    # end off mid-line.
    TRUNCATED=$(printf '%s\n' "$OUTPUT" | tail -50 | tail -c 2000)
    if capped "$EXIT_CODE" "$RUN_ELAPSED" "$CHECK_CAP_SECONDS"; then
      # Cleanup runs only here: a check that exited on its own took its
      # remote work with it (the client returns when that work ends).
      if [ -n "${CLEANUP// /}" ]; then
        run_capped "$CLEANUP_CAP_SECONDS" "$CLEANUP" "$RUN_ID"
        if [ "$RUN_EXIT" -eq 0 ]; then
          CLEANUP_NOTE="Cleanup ran ($CLEANUP)."
        elif capped "$RUN_EXIT" "$RUN_ELAPSED" "$CLEANUP_CAP_SECONDS"; then
          CLEANUP_NOTE="Cleanup timed out after ${CLEANUP_CAP_SECONDS}s ($CLEANUP): work this check started in a container, on another host or detached may still be running. Confirm it stopped before running the check again."
        else
          CLEANUP_NOTE="Cleanup failed (exit $RUN_EXIT) ($CLEANUP): work this check started in a container, on another host or detached may still be running. Confirm it stopped before running the check again. Cleanup output: $(printf '%s\n' "$RUN_OUTPUT" | tail -10 | tail -c 600)"
        fi
      else
        CLEANUP_NOTE="No cleanup declared. The kill reaches only processes on this machine that stay in the check's process group: work it runs in a container or on another host (docker exec, kubectl exec, ssh) or detaches keeps running. Confirm that stopped before running the check again, or give the check a cleanup command in .claude/verification.json."
      fi
      TIMED_OUT_CHECKS+=("$NAME")
      FAILED_OUTPUT+=("[$NAME timed out after ${CHECK_CAP_SECONDS}s] $COMMAND was killed before it finished, so its result is unknown. This is not a test failure. $CLEANUP_NOTE Then run the check directly and report its real exit code; if it passes but is slow, reduce its runtime (narrow what it runs). Do not raise the cap. Output so far:"$'\n'"$TRUNCATED")
    else
      FAILED_CHECKS+=("$NAME")
      FAILED_LOGS+=("$CHECK_RUN_LOG")
      CHECK_RUN_LOG=""
      FAILED_OUTPUT+=("[$NAME] $COMMAND failed:"$'\n'"$TRUNCATED")
    fi
  fi
  # A passed or timed-out check's log is not needed any more.
  if [ -n "$CHECK_RUN_LOG" ]; then
    rm -f "$CHECK_RUN_LOG"
    CHECK_RUN_LOG=""
  fi
done
if [ "${#FAILED_OUTPUT[@]}" -gt "$ROOT_FAILURES" ]; then
  if [ "$IMPLEMENT_ACTIVE" -eq 1 ]; then
    WARN_NOTES+=("Failing${ROOT_LABEL} during feature-implement orchestration; not blocking (marker .claude/state/implement-in-progress.json). The final verification step still gates.")
  else
    ATTRIBUTION=""
    ATTRIBUTION_WARN=0
    if [ "$ATTRIBUTE" -eq 1 ] && [ "${#FAILED_CHECKS[@]}" -gt "$ROOT_FAILED_START" ]; then
      attribute_failures
    fi
    if [ "$ATTRIBUTION_WARN" -eq 1 ]; then
      # The failures are real, but they name only files another session left
      # uncommitted.
      WARN_NOTES+=("Not blocking: every failure${ROOT_LABEL} names only files changed outside this session. $ATTRIBUTION"$'\n'"A worktree per session keeps each session's gate to its own changes.")
    else
      BLOCKING_FAILURE=1
      if [ -n "$ATTRIBUTION" ]; then
        BLOCK_NOTES+=("$ATTRIBUTION")
      fi
    fi
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
  NOTES=""
  for ENTRY in ${WARN_NOTES[@]+"${WARN_NOTES[@]}"}; do
    NOTES+="${ENTRY}"$'\n\n'
  done
  if [ "$BLOCKING_FAILURE" -eq 0 ]; then
    # Non-blocking: no decision block, so the stop proceeds; systemMessage
    # surfaces the failure to the user.
    MESSAGE=$(printf "Verification failing (%s).\n\n%s%s" "$NAMES" "$NOTES" "$DETAILS" | jq -Rs .)
    echo "{\"decision\": \"approve\", \"systemMessage\": $MESSAGE}"
    exit 0
  fi
  if [ "${#BLOCK_NOTES[@]}" -gt 0 ]; then
    for ENTRY in "${BLOCK_NOTES[@]}"; do
      NOTES+="${ENTRY}"$'\n\n'
    done
    NOTES+="Fix what your changes broke. Do not edit files changed outside this session to make a check pass: another session sharing this checkout may be working on them. If a failure comes from those changes, say so and stop. A Bash side effect (an install, code generation) is not recorded as this session's write, so if you made one of those changes, it is yours."$'\n\n'
  fi
  # Escape for JSON
  REASON=$(printf "Verification did not pass (%s). Fix the failures your changes caused before completing; for a timeout, get the real result first.\n\n%s%s" "$NAMES" "$NOTES" "$DETAILS" | jq -Rs .)
  echo "{\"decision\": \"block\", \"reason\": $REASON}"
  exit 0
fi

echo '{"decision": "approve"}'
