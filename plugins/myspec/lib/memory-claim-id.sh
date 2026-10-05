#!/usr/bin/env bash
# memory-claim-id.sh
# Hands out the next free memory ID for a type, atomically across every
# checkout of this repo on this machine.
#
# THE RACE IT CLOSES
# Memory IDs are sequential (P001…). Allocation used to mean "read the index,
# take the next number" — so two sessions branched from the same base both
# pick P053, both write it, and the tables auto-merge without a conflict
# because the rows land on different lines. tests/unit/memoryIndexIntegrity.spec.js
# catches it after the fact; this closes it at the source.
#
# HOW
#   0. Run the conformance check (memory-doctor.mjs). A tree the tooling
#      cannot read — duplicate IDs, missing hooks — is not a tree to allocate
#      into; refusing here is cheaper than a collision found by hand.
#   1. Take a lock in the MAIN checkout (mkdir is atomic even over NFS).
#   2. High-water = max(IDs on disk in the main checkout AND every linked
#      worktree, IDs at the tip of every local and remote-tracking ref,
#      registry high-water).
#   3. Record high-water+1 in the registry, release, print the ID.
#
# The registry makes a claim durable BEFORE the file exists, which is the gap a
# pure filesystem scan leaves open. The scan makes the registry self-healing: a
# fresh clone, a deleted registry, or hand-added files all recover, because the
# registry is only ever a floor, never the sole authority. Unused claims leave
# harmless gaps in the sequence.
#
# WHAT THE AUDIT FOUND (2026-09), and why the scans look the way they do
#   - Names are matched case-insensitively. A project that writes p001-slug.md
#     got HIGH=0 from a case-sensitive glob and was handed P001 over it.
#   - Refs are scanned, not just checkouts. A memory committed on a pushed
#     branch that nobody has checked out (origin/poc/wizard-v2 carrying p004.md)
#     was invisible, its number was reused on the mainline, and the lesson was
#     lost when the branch merged. Unique tips only, so 100+ refs stay fast.
#   - No jq. Every registry read/write used to be gated on `command -v jq`, so
#     without it two claims with no file written in between returned the same
#     ID. The registry is three integers and aiDir is one string; sed reads
#     both, printf writes the registry.
#   - One lock for all three prefixes. Per-prefix locks let a P claim and an S
#     claim rewrite the whole registry at the same moment and lose one update.
#
# Scope: this machine. The registry is per-checkout state, so it does not
# serialise against a session running elsewhere.
#
# Usage: memory-claim-id.sh <procedural|semantic|episodic>
#        memory-claim-id.sh --normalize
#
# Prints exactly one line on success — the claimed ID (P053). Everything else
# goes to stderr.
#
# --normalize rewrites .claude/state/memory-ids.json in the one-line form the
# claim reads, from either form: versions before 1.28 wrote it jq
# pretty-printed, one key per line, which the strict reader (section 3) sees
# as zeros, and a claim would then rewrite the floors away. update's
# 3.0.0-memory-registry migration runs it once; it takes the lock, keeps
# every floor, is idempotent, prints one line, and does nothing without a
# registry.
#
# Exit codes
#   0  claimed
#   1  could not acquire the lock within 10 s
#   2  usage error, or not inside a git repository
#   3  conformance refusal — memory-doctor.mjs reported errors; fix them
#      and retry
#
# MYSPEC_SKIP_MEMORY_DOCTOR=1 skips step 0. It exists for the test fixture and
# as an escape hatch when the doctor itself is broken; the scans still run.

set -euo pipefail

TYPE="${1:-}"
MODE=claim

case "$TYPE" in
  procedural) PREFIX=P; PREFIX_RE='[Pp]' ;;
  semantic)   PREFIX=S; PREFIX_RE='[Ss]' ;;
  episodic)   PREFIX=E; PREFIX_RE='[Ee]' ;;
  --normalize) MODE=normalize; PREFIX=""; PREFIX_RE="" ;;
  *)
    echo "usage: memory-claim-id.sh <procedural|semantic|episodic> | --normalize" >&2
    exit 2
    ;;
esac

# The main checkout owns the lock and the registry: worktrees each have their
# own .ai/memory, so per-worktree state would not serialise anything.
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "memory-claim-id: not inside a git repository" >&2
  exit 2
}
MAIN_ROOT=$(dirname "$COMMON_DIR")

# aiDir comes from .myspec.json through the one settings reader beside this
# script: the Node one (lib/myspec-config.mjs) first, since the conformance
# gate below needs node anyway and this script keeps jq optional; the shell
# one (lib/myspec-config.sh, jq) when node is absent. The reader's schema
# holds the default, so no value here is a guess from disk; `.ai/` (trailing
# slash) occurs in the wild and is normalised here as memory-files.mjs does.
LIB_DIR=$(dirname "$0")
READER=()
if command -v node >/dev/null 2>&1 && [ -f "$LIB_DIR/myspec-config.mjs" ]; then
  READER=(node "$LIB_DIR/myspec-config.mjs")
elif command -v jq >/dev/null 2>&1 && [ -f "$LIB_DIR/myspec-config.sh" ]; then
  READER=(bash "$LIB_DIR/myspec-config.sh")
else
  echo "memory-claim-id: reading aiDir from .myspec.json needs node with $LIB_DIR/myspec-config.mjs, or jq with $LIB_DIR/myspec-config.sh" >&2
  exit 2
fi
READER_ERR=$(mktemp "${TMPDIR:-/tmp}/.myspec-claim.XXXXXX")
AI_DIR=$("${READER[@]}" get aiDir --root "$MAIN_ROOT" 2>"$READER_ERR") || {
  echo "memory-claim-id: cannot read aiDir: $(cat "$READER_ERR")" >&2
  rm -f "$READER_ERR"
  exit 2
}
[ ! -s "$READER_ERR" ] || sed 's/^/memory-claim-id: /' "$READER_ERR" >&2
rm -f "$READER_ERR"
AI_DIR=$(printf '%s' "$AI_DIR" | sed -n 's/^"\(.*\)"$/\1/p' | sed 's#^\./##; s#/*$##')
# An empty string is unset, as hook-core's ai_dir and memory-files.mjs read
# it: the schema default, which the reader returns for a root with no
# .myspec.json.
if [ -z "$AI_DIR" ]; then
  EMPTY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/.myspec-claim-root.XXXXXX")
  AI_DIR=$("${READER[@]}" get aiDir --root "$EMPTY_ROOT" 2>/dev/null | sed -n 's/^"\(.*\)"$/\1/p') || AI_DIR=""
  rmdir "$EMPTY_ROOT"
fi
if [ -z "$AI_DIR" ]; then
  echo "memory-claim-id: aiDir is empty in .myspec.json and the reader gave no default" >&2
  exit 2
fi

# Repo-relative path of this type's memory dir; doubles as the ls-tree pathspec.
MEM_REL="$AI_DIR/memory/$TYPE"
MEM_REL="${MEM_REL#./}"

STATE_DIR="$MAIN_ROOT/.claude/state"
REGISTRY="$STATE_DIR/memory-ids.json"
LOCK="$STATE_DIR/memory-id.lock"

# --- 0. Conformance gate ----------------------------------------------------
# Before the lock, so a refusal never holds it and a slow doctor never blocks
# a sibling claim. Contract: the doctor prints `ERROR …` lines plus a summary
# and exits 1 on errors, 0 otherwise.
DOCTOR="$(dirname "$0")/memory-doctor.mjs"
if [ "${MYSPEC_SKIP_MEMORY_DOCTOR:-}" = "1" ] || [ "$MODE" = normalize ]; then
  # --normalize is what update runs before the health checks; it allocates
  # nothing, so the doctor has nothing to gate.
  :
elif command -v node >/dev/null 2>&1 && [ -f "$DOCTOR" ]; then
  if ! DOCTOR_OUT=$(node "$DOCTOR" --quiet --root "$MAIN_ROOT" 2>&1); then
    printf '%s\n' "$DOCTOR_OUT" >&2
    echo "memory-claim-id: refusing to allocate — fix the errors above (or run /myspec:update)" >&2
    exit 3
  fi
else
  echo "memory-claim-id: conformance check skipped (node or memory-doctor.mjs not found)" >&2
fi

mkdir -p "$STATE_DIR"

# --- 1. Lock ----------------------------------------------------------------
# The trap goes in BEFORE the acquire loop: a crash between acquire and trap
# used to wedge the repo for 60 s. LOCKED keeps the trap from removing a lock
# some other process holds when this one gives up waiting.
LOCKED=0
cleanup() {
  if [ "$LOCKED" = 1 ]; then
    rmdir "$LOCK" 2>/dev/null || true
  fi
  rmdir "$LOCK.stale.$$" 2>/dev/null || true
  rm -f "$REGISTRY.tmp.$$" 2>/dev/null || true
}
trap cleanup EXIT

lock_age() {
  local mtime
  mtime=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)
  # GNU stat accepts -f (filesystem mode) and may print a non-number for %m;
  # fall through to the GNU form rather than feeding garbage to arithmetic.
  case "$mtime" in
    ''|*[!0-9]*) mtime=$(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ;;
  esac
  case "$mtime" in
    ''|*[!0-9]*) mtime=0 ;;
  esac
  echo $(( $(date +%s) - mtime ))
}

ATTEMPTS=0
until mkdir "$LOCK" 2>/dev/null; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -gt 100 ]; then
    echo "memory-claim-id: could not acquire $LOCK after 10s" >&2
    exit 1
  fi

  # Stale-lock breaking, so a crashed claim cannot wedge the repo. The rename
  # is the atomic step: exactly one waiter wins it and removes the directory,
  # every other waiter fails the mv and just retries.
  if [ "$(lock_age)" -gt 60 ] && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
    rmdir "$LOCK.stale.$$" 2>/dev/null || true
    continue
  fi

  sleep 0.1
done
LOCKED=1

# --- 1b. --normalize ----------------------------------------------------------
# Under the lock, so a concurrent claim never reads half a rewrite. Each
# value is read with jq when it is on PATH, else with the tolerant pattern
# (the integer after `"<key>":` anywhere in the file), so both the one-line
# and the pre-1.28 pretty-printed form give their floors.
if [ "$MODE" = normalize ]; then
  if [ ! -f "$REGISTRY" ]; then
    echo "memory-ids.json: no registry, nothing to normalize"
    exit 0
  fi
  normalize_value() {
    local v=""
    if command -v jq >/dev/null 2>&1; then
      v=$(jq -r --arg k "$1" '.[$k] // 0 | numbers | floor' "$REGISTRY" 2>/dev/null || printf '')
    fi
    if [ -z "$v" ]; then
      v=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$REGISTRY" | tail -1)
    fi
    case "$v" in
      ''|*[!0-9]*) v=0 ;;
    esac
    printf '%s' "$v"
  }
  NORMALIZED=$(printf '{"P": %d, "S": %d, "E": %d}' "$(normalize_value P)" "$(normalize_value S)" "$(normalize_value E)")
  if [ "$(<"$REGISTRY")" = "$NORMALIZED" ]; then
    echo "memory-ids.json: already one line: $NORMALIZED"
    exit 0
  fi
  printf '%s\n' "$NORMALIZED" > "$REGISTRY.tmp.$$"
  mv "$REGISTRY.tmp.$$" "$REGISTRY"
  echo "memory-ids.json: normalized to one line: $NORMALIZED"
  exit 0
fi

# --- 2. High-water ----------------------------------------------------------
# Each collector emits candidate basenames, one per line; max_from_names keeps
# the highest number among those that parse as <prefix><digits>[-slug].md,
# case-insensitively. P002.md (no slug) counts; P012abc.md counts as 12.
max_from_names() {
  sed -nE "s/^${PREFIX_RE}0*([0-9]+)([^0-9].*)?$/\1/p" | sort -n | tail -1
}

# Files on disk in one checkout — committed or not.
collect_disk() {
  local dir="$1/$MEM_REL"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -iname "${PREFIX}[0-9]*.md" | sed 's#.*/##'
}

# Files at the tip of every local and remote-tracking ref, whether or not
# anything has it checked out. Two levels of de-duplication keep this fast
# with hundreds of refs: unique tips first, then one cat-file call resolves
# every tip to the tree object of the memory dir, and ls-tree runs once per
# distinct tree — most branches share one, so that is usually a handful.
collect_refs() {
  local tree
  { git -C "$MAIN_ROOT" for-each-ref --format='%(objectname)' refs/heads refs/remotes 2>/dev/null || true; } \
    | sort -u \
    | awk -v p=":$MEM_REL" 'NF { print $0 p }' \
    | { git -C "$MAIN_ROOT" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null || true; } \
    | awk '$2 == "tree" { print $1 }' \
    | sort -u \
    | while IFS= read -r tree; do
        git -C "$MAIN_ROOT" ls-tree -r --name-only "$tree" 2>/dev/null || true
      done \
    | sed 's#.*/##'
}

collect_all() {
  local wt
  collect_disk "$MAIN_ROOT"
  { git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null || true; } \
    | awk '/^worktree /{sub(/^worktree /, ""); print}' \
    | while IFS= read -r wt; do
        [ -n "$wt" ] && collect_disk "$wt"
      done
  collect_refs
}

HIGH=$(collect_all | max_from_names)
case "$HIGH" in
  ''|*[!0-9]*) HIGH=0 ;;
esac

# --- 3. Registry ------------------------------------------------------------
# One line, `{"P": n, "S": n, "E": n}`, as this script writes it (below): the
# value for a key is the integer after `"<key>":` on that line. The jq
# pretty-printed registry of versions before 1.28 is not read (#266).
registry_value() {
  local v=""
  if [ -f "$REGISTRY" ]; then
    v=$(sed -n "1s/^{.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$REGISTRY")
  fi
  case "$v" in
    ''|*[!0-9]*) v=0 ;;
  esac
  printf '%s' "$v"
}

P_VAL=$(registry_value P)
S_VAL=$(registry_value S)
E_VAL=$(registry_value E)

case "$PREFIX" in
  P) RECORDED=$P_VAL ;;
  S) RECORDED=$S_VAL ;;
  E) RECORDED=$E_VAL ;;
esac
if [ "$RECORDED" -gt "$HIGH" ]; then
  HIGH="$RECORDED"
fi

NEXT=$((HIGH + 1))

case "$PREFIX" in
  P) P_VAL=$NEXT ;;
  S) S_VAL=$NEXT ;;
  E) E_VAL=$NEXT ;;
esac

# Whole-object rewrite via a same-directory temp file, so the rename is atomic
# and a reader never sees a half-written registry.
printf '{"P": %d, "S": %d, "E": %d}\n' "$P_VAL" "$S_VAL" "$E_VAL" > "$REGISTRY.tmp.$$"
mv "$REGISTRY.tmp.$$" "$REGISTRY"

printf '%s%03d\n' "$PREFIX" "$NEXT"
