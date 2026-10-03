#!/usr/bin/env bash
# Regression fixture for framework-files/manifest.json completeness.
#
#   710b715  command-scan.sh, branch-cleanup.sh and memory-claim-id.sh were
#            referenced as .claude/lib/<name> by hooks, skills and shipped rules
#            but had no manifest entry, so init/update never copied them. The
#            branch guard sources command-scan.sh and fails open without it:
#            every command was approved with no error.
#   4788851  memory-index.mjs, the fourth such helper, was missed the same way.
#
# The rule: every .claude/lib/<name> or .claude/hooks/<name> that shipped
# content points at, and that this plugin has as lib/<name> or hooks/<name>,
# must be the dest of a manifest entry. Paths the plugin does not ship (a
# placeholder x.sh, a retired hook named in a migration) are out of scope.
#
# Usage: manifest-regression.test.sh [plugin-root]

set -uo pipefail

PLUGIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MANIFEST="$PLUGIN/framework-files/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "FATAL: manifest not found: $MANIFEST" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# Every dest the manifest installs, one per line (the removed block excluded).
DESTS=$(jq -r 'to_entries[] | select(.key != "removed") | .value
  | objects | to_entries[] | .value | objects | .dest // empty' "$MANIFEST")

[ -n "$DESTS" ] && ok || fail "the manifest lists at least one dest"

# Shipped content: what init/update copy or a downstream model reads.
# Test fixtures are excluded; they name hooks that exist only in a temp repo.
SHIPPED=()
for d in skills framework-files templates blueprints hooks lib; do
  [ -d "$PLUGIN/$d" ] && SHIPPED+=("$PLUGIN/$d")
done

REFS=$(grep -rhoE '\.claude/(lib|hooks)/[A-Za-z0-9._-]+' \
    --exclude-dir=tests --exclude=manifest.json "${SHIPPED[@]}" 2>/dev/null \
  | sed -E 's/[.]+$//' | sort -u)

# A hook that sources a sibling lib by relative path ships with the same need,
# and so does a lib the hooks or hook-core reach through $HOOK_LIB (the
# directory hook-core.sh was found in).
# shellcheck disable=SC2016 # a literal $HOOK_LIB, matched in the scripts' text
REL_REFS=$(grep -hoE '(\.\./lib|\$HOOK_LIB)/[A-Za-z0-9._-]+' "$PLUGIN"/hooks/*.sh "$PLUGIN"/lib/hook-core.sh 2>/dev/null \
  | sed -E 's#^(\.\./lib|\$HOOK_LIB)/#.claude/lib/#; s/[.]+$//' | sort -u)

CHECKED=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  rel="${ref#.claude/}"            # lib/<name> or hooks/<name>
  [ -f "$PLUGIN/$rel" ] || continue
  CHECKED=$((CHECKED + 1))
  if printf '%s\n' "$DESTS" | grep -qxF -- "$ref"; then
    ok
  else
    fail "$ref is referenced by shipped content but has no manifest entry, so init/update never install it"
  fi
done <<EOF
$(printf '%s\n%s\n' "$REFS" "$REL_REFS" | sort -u)
EOF

[ "$CHECKED" -gt 0 ] && ok || fail "the scan found at least one shipped helper reference"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
