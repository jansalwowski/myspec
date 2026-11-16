#!/usr/bin/env bash
# Regression fixture for bootstrap-scan.sh, the mechanical half of
# /myspec:bootstrap (#508).
#
# It must read the configured aiDir without a caller-set shell variable
# (#509), count stale session logs without moving them (#511), and print one
# summary line per finding: memory counts, both doctors, sessions, worktree
# health, branch lag only when asked and lagging, and the version line only
# when the versions differ. Also under macOS's bash 3.2 (lib/tests/old-bash.sh).
#
# Usage: bootstrap-scan.test.sh [path-to-script]

set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../bootstrap-scan.sh}"
[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }
# shellcheck source=lib/tests/old-bash.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/old-bash.sh"
PLUGIN_VERSION=$(jq -r .frameworkVersion "$(dirname "$SCRIPT")/../framework-files/manifest.json")

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
has()  { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

# ago <seconds> -> a touch -t stamp that long ago (BSD date, then GNU)
ago() { date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M 2>/dev/null || date -d "@$(( $(date +%s) - $1 ))" +%Y%m%d%H%M; }
git_() { git -c user.email=t@t -c user.name=t "$@"; }

mkdir -p "$REPO"
cd "$REPO" || exit 1
git_ init -q -b main .
printf '.claude/state/\n' > .gitignore
printf '{ "aiDir": "docs-ai", "frameworkVersion": "%s" }\n' "$PLUGIN_VERSION" > .myspec.json
M=docs-ai/memory
mkdir -p "$M/procedural" "$M/semantic" "$M/episodic"
printf '# Memory Index\n\n## Critical Procedural (What NOT to Do)\n- [P001](procedural/P001-x.md) never x\n- [S001](semantic/S001-y.md) y holds\n' > "$M/index.md"
printf '| ID | Hook | Anchor |\n|----|------|--------|\n| [P001](P001-x.md) | x | a |\n| [P002](P002-z.md) | z | a |\n' > "$M/procedural/index.md"
printf '| ID | Hook | Anchor |\n|----|------|--------|\n| [S001](S001-y.md) | y | a |\n' > "$M/semantic/index.md"
printf '| ID | Hook | Date |\n|----|------|------|\n' > "$M/episodic/index.md"
git_ add -A && git_ commit -q -m init

S="$REPO/.claude/state/sessions"
mkdir -p "$S"
printf -- '---\nstatus: active\ntopic: fresh-work\n---\n' > "$S/aaaaaaaa1111.md"
printf -- '---\nstatus: active\ntopic: midway\n---\n' > "$S/bbbbbbbb2222.md"
printf -- '---\nstatus: active\ntopic: old\n---\n' > "$S/cccccccc3333.md"
touch -t "$(ago 10800)" "$S/bbbbbbbb2222.md"
touch -t "$(ago 172800)" "$S/cccccccc3333.md"

# --- the main checkout, under every bash at hand --------------------------------
old_bash_dirs "$ROOT"
for dir in "${TEST_BASH_DIRS[@]}"; do
  label="main checkout${dir:+ under /bin/bash}"
  OUT=$(PATH="${dir:+$dir:}$PATH" "$SCRIPT" 2>"$ROOT/stderr"); STATUS=$?
  ERR=$(cat "$ROOT/stderr")
  [ "$STATUS" -eq 0 ] && ok || fail "$label: exits 0 (got $STATUS): $OUT $ERR"
  [ -z "$ERR" ] && ok || fail "$label: stderr is empty (got: $ERR)"
  has '**Memory**: Layer 1 2 entries | Layer 2 2 procedural, 1 semantic, 0 episodic rows' && ok \
    || fail "$label: memory counts read from the configured aiDir (got: $OUT)"
  has '**Active sessions**: 2: aaaaaaaa (fresh-work), bbbbbbbb (midway)' && ok || fail "$label: active sessions listed (got: $OUT)"
  has '**Dangling**: 1 session(s) 1-6h stale, run /myspec:session-clean' && ok || fail "$label: the 1-6h log is dangling (got: $OUT)"
  has '**Stale sessions**: 1 log(s) older than 6h, run /myspec:session-clean' && ok || fail "$label: the old log is counted (got: $OUT)"
  has '**Memory health**: ' && has '**Setup health**: ' && ok || fail "$label: both doctors report (got: $OUT)"
  has 'myspec version' && fail "$label: equal versions print no version line (got: $OUT)" || ok
  has 'Worktree health' && fail "$label: no worktrees, no worktree line (got: $OUT)" || ok
  has 'Branch lag' && fail "$label: no branch flags, no lag line (got: $OUT)" || ok
done
[ -f "$S/cccccccc3333.md" ] && ok || fail "the stale log is not moved (#511)"
[ ! -e "$REPO/$M/sessions" ] && ok || fail "nothing is archived"
[ -z "$(git_ status --porcelain)" ] && ok || fail "the scan writes nothing tracked"

# --- versions -------------------------------------------------------------------
printf '{ "aiDir": "docs-ai", "frameworkVersion": "0.0.1" }\n' > .myspec.json
OUT=$("$SCRIPT" 2>/dev/null)
has "**myspec version**: plugin v$PLUGIN_VERSION ahead of project v0.0.1, run /myspec:update" && ok || fail "plugin ahead (got: $OUT)"
printf '{ "aiDir": "docs-ai", "frameworkVersion": "999.0.0" }\n' > .myspec.json
OUT=$("$SCRIPT" 2>/dev/null)
has "**myspec version**: plugin v$PLUGIN_VERSION behind project v999.0.0, update your plugin" && ok || fail "plugin behind (got: $OUT)"
printf '{ "aiDir": "docs-ai", "frameworkVersion": "next" }\n' > .myspec.json
OUT=$("$SCRIPT" 2>/dev/null)
has "**myspec version**: project on vnext, plugin has v$PLUGIN_VERSION" && ok || fail "non-semver (got: $OUT)"
git_ checkout -q -- .myspec.json

# --- without jq: the Node reader's aiDir is used, not .ai --------------------
# nojq_path -> a PATH holding every command on this one but jq, in a
# directory of symlinks (jq can sit in /usr/bin, so dropping PATH entries is
# not enough).
nojq_path() {
  local bin="$ROOT/nojq-bin" d f
  if [ ! -d "$bin" ]; then
    mkdir -p "$bin"
    local IFS=:
    for d in $PATH; do
      for f in "$d"/*; do
        [ -x "$f" ] && [ ! -d "$f" ] || continue
        [ "${f##*/}" != jq ] || continue
        [ -e "$bin/${f##*/}" ] || ln -s "$f" "$bin/${f##*/}"
      done
    done
  fi
  printf '%s' "$bin"
}
if command -v node >/dev/null 2>&1; then
  OUT=$(PATH="$(nojq_path)" "$SCRIPT" 2>/dev/null)
  has '**Memory**: Layer 1 2 entries | Layer 2 2 procedural, 1 semantic, 0 episodic rows' && ok \
    || fail "without jq, memory counts read from the configured aiDir (got: $OUT)"
fi

# --- worktrees ------------------------------------------------------------------
git_ worktree add -q -b fresh "$ROOT/fresh" >/dev/null 2>&1
OUT=$("$SCRIPT" 2>/dev/null)
has '**Worktree health**: clean (1 active)' && ok || fail "a fresh worktree is clean (got: $OUT)"
git_ -C "$ROOT/fresh" commit -q --allow-empty -m old --date "@$(( $(date +%s) - 864000 ))"
GIT_COMMITTER_DATE="@$(( $(date +%s) - 864000 ))" git_ -C "$ROOT/fresh" commit -q --amend --no-edit --allow-empty
git_ worktree add -q -b gone "$ROOT/gone" >/dev/null 2>&1
rm -rf "$ROOT/gone"
OUT=$("$SCRIPT" 2>/dev/null)
has '**Worktree health**: WARNING, 2 of 2 stale or orphaned; use the worktree-clean skill' && ok \
  || fail "an old and a missing worktree are flagged (got: $OUT)"
git_ worktree prune

# --- from a linked worktree: the main checkout's sessions ---------------------
OUT=$(cd "$ROOT/fresh" && "$SCRIPT" 2>/dev/null)
has '**Active sessions**: 2: ' && ok || fail "a linked worktree reads the main checkout's session logs (got: $OUT)"

# --- branch lag -------------------------------------------------------------------
git_ clone -q --bare "$REPO" "$ROOT/origin.git"
git_ remote add origin "$ROOT/origin.git"
git_ branch develop
git_ commit -q --allow-empty -m hotfix
git_ push -q origin main develop
OUT=$("$SCRIPT" --integration develop --release main 2>/dev/null)
has '**Branch lag**: develop is missing 1 commit(s) from main, merge main into develop before planning' && ok \
  || fail "the lag is reported with its count (got: $OUT)"
git_ push -q origin main:develop
OUT=$("$SCRIPT" --integration develop --release main 2>/dev/null)
has 'Branch lag' && fail "no lag, no line (got: $OUT)" || ok
OUT=$("$SCRIPT" --integration develop --release nosuch 2>/dev/null)
has '**Branch lag**: not checked, git fetch exited' && ok || fail "a failed fetch is reported (got: $OUT)"

# --- usage and outside a project ------------------------------------------------
"$SCRIPT" --bogus >/dev/null 2>&1; STATUS=$?
[ "$STATUS" -eq 2 ] && ok || fail "an unknown flag exits 2 (got $STATUS)"
mkdir -p "$ROOT/nowhere"
(cd "$ROOT/nowhere" && "$SCRIPT" >/dev/null 2>&1); STATUS=$?
[ "$STATUS" -eq 2 ] && ok || fail "outside git and any project exits 2 (got $STATUS)"

printf '\nbootstrap-scan: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
