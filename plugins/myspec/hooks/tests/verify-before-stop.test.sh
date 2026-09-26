#!/usr/bin/env bash
# Regression fixture for the linked node_modules gate in verify-before-stop.sh
# (issue #94).
#
# worktree-provision.sh links node_modules only when the branch leaves the
# lockfile alone, so a link it made must pass the Stop hook with default
# config. A link whose lockfiles differ from the checkout it points into, or a
# link with no lockfile to compare, must still block unless
# isolation.allowLinkedModules is set.
#
# Usage: verify-before-stop.test.sh [path-to-hook]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${1:-$HERE/../verify-before-stop.sh}"
PROVISION="$HERE/../../lib/worktree-provision.sh"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
SID="vbs-$$"
trap 'rm -rf "$ROOT"; rm -f /tmp/.myspec-code-changed-'"$SID"'-*' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# new_repo <name> <with-lockfile:0|1> -> prints main checkout path
new_repo() {
  local main="$ROOT/$1"
  mkdir -p "$main/.claude" "$main/node_modules/dep"
  git init -q -b main "$main"
  git -C "$main" config user.email t@t
  git -C "$main" config user.name t
  printf '{"checks":[{"name":"ok","command":"true","required":true}]}\n' > "$main/.claude/verification.json"
  printf 'node_modules\n' > "$main/.gitignore"
  [ "$2" = 1 ] && printf '{"lockfileVersion":3}\n' > "$main/package-lock.json"
  git -C "$main" add -A
  git -C "$main" commit -q -m init
  printf '%s\n' "$main"
}

# stop <sid-suffix> <cwd> -> prints the decision
stop() {
  touch "/tmp/.myspec-code-changed-$SID-$1"
  printf '{"session_id":"%s-%s","cwd":%s}' "$SID" "$1" "$(printf '%s' "$2" | jq -Rs .)" \
    | bash "$HOOK" 2>/dev/null | jq -r '.decision'
}

expect() {  # expect <want> <got> <desc>
  if [ "$1" = "$2" ]; then ok; else fail "$3 (want $1, got $2)"; fi
}

# --- provisioned link, lockfile unchanged: accepted ------------------------
MAIN=$(new_repo a 1)
WT="$ROOT/a-wt"
git -C "$MAIN" worktree add -q -b feat "$WT" main
bash "$PROVISION" "$WT" --base main >/dev/null
[ -L "$WT/node_modules" ] && ok || fail "provision links node_modules when the lockfile is unchanged"
expect approve "$(stop 1 "$WT")" "linked node_modules with identical lockfile is accepted"

# --- uncommitted lockfile edit under the link: blocked ---------------------
printf '{"lockfileVersion":3,"x":1}\n' > "$WT/package-lock.json"
expect block "$(stop 2 "$WT")" "uncommitted lockfile change under a link blocks"
[ -f "/tmp/.myspec-code-changed-$SID-2" ] && ok || fail "block leaves the marker in place"

# --- committed lockfile change, stale link: blocked -------------------------
git -C "$WT" commit -q -am "bump lock"
expect block "$(stop 3 "$WT")" "committed lockfile change under a link blocks"

# --- provision declines to link a changed-lockfile branch -------------------
WT2="$ROOT/a-wt2"
git -C "$MAIN" worktree add -q -b feat2 "$WT2" feat
bash "$PROVISION" "$WT2" --base main >/dev/null
[ ! -e "$WT2/node_modules" ] && ok || fail "provision skips the link when the lockfile changed"

# --- allowLinkedModules still overrides a mismatch --------------------------
printf '{"isolation":{"allowLinkedModules":true}}\n' > "$WT/.myspec.json"
expect approve "$(stop 4 "$WT")" "allowLinkedModules accepts a mismatched link"
rm -f "$WT/.myspec.json"

# --- no lockfile anywhere: no evidence, blocked -----------------------------
MAIN_B=$(new_repo b 0)
WT_B="$ROOT/b-wt"
git -C "$MAIN_B" worktree add -q -b feat "$WT_B" main
bash "$PROVISION" "$WT_B" --base main >/dev/null
expect block "$(stop 5 "$WT_B")" "link with no lockfile to compare blocks"

# --- a real install is untouched by the gate --------------------------------
rm "$WT_B/node_modules"
mkdir "$WT_B/node_modules"
expect approve "$(stop 6 "$WT_B")" "a real node_modules directory is accepted"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
