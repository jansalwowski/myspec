#!/usr/bin/env bash
# Regression fixture for framework-files/retired-hashes.json (#262 review).
#
# update's 3.0.0-plugin-hooks migration tells a hand-patched 2.x hook or lib
# copy from the one 2.x installed by comparing its SHA-256 with this file,
# which holds each retired file as it was at the 3.0 upgrade floor, v2.12.0.
# Compared against the 3.0 plugin copies instead, every moved file reads as
# hand-patched (this release rewrote them all). So the shipped file must be
# exactly what scripts/retired-hashes.mjs regenerates from the tag, and must
# cover every hook and lib entry retired since 3.0.
#
# Usage: scripts/tests/retired-hashes.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIPPED="$ROOT/framework-files/retired-hashes.json"
TAG=v2.12.0

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# A shallow CI checkout may lack the tag; fetch just that ref.
if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  git -C "$ROOT" fetch -q --no-tags --depth=1 origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
fi
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then ok; else fail "tag $TAG is available (fetch it: git fetch origin tag $TAG)"; printf '%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; fi

[ -f "$SHIPPED" ] && ok || fail "framework-files/retired-hashes.json is shipped"
[ "$(jq -r .tag "$SHIPPED")" = "$TAG" ] && ok || fail "the shipped file is pinned to $TAG (got $(jq -r .tag "$SHIPPED"))"

GENERATED=$(node "$ROOT/scripts/retired-hashes.mjs" --tag "$TAG"); STATUS=$?
[ "$STATUS" -eq 0 ] && ok || fail "the generator runs against $TAG (exit $STATUS)"
if [ "$GENERATED" = "$(cat "$SHIPPED")" ]; then ok; else fail "the shipped file matches a fresh generation from $TAG (run: node scripts/retired-hashes.mjs --write)"; diff <(printf '%s\n' "$GENERATED") "$SHIPPED" | head -10 >&2; fi

# Every hook and lib entry retired since 3.0 is either hashed or listed as
# unreleased at the tag, and nothing else is.
RETIRED=$(jq -r '.removed | to_entries[] | select(.value.since | test("^([3-9]|[0-9]{2,})\\.")) | select(.key | startswith("hooks/") or startswith("lib/")) | .key' "$ROOT/framework-files/manifest.json" | sort)
COVERED=$(jq -r '(.files | keys[]), .unreleased[]' "$SHIPPED" | sort)
[ "$RETIRED" = "$COVERED" ] && ok || fail "the hashed plus unreleased keys are exactly the manifest's retired hooks and lib since 3.0"
[ "$(jq -r '.files | length' "$SHIPPED")" -ge 30 ] && ok || fail "the hashed set covers the 2.x hooks and lib (got $(jq -r '.files | length' "$SHIPPED"))"
if jq -e '.files | to_entries | all(.value | test("^[0-9a-f]{64}$"))' "$SHIPPED" >/dev/null; then ok; else fail "every hash is a 64-hex sha256"; fi
# lib/stop-gate/* landed after v2.12.0 (#257), so no 2.x release installed it.
if jq -e '.unreleased | index("lib/stop-gate/run.sh")' "$SHIPPED" >/dev/null; then ok; else fail "a file added after the tag is listed as unreleased, not hashed"; fi
for key in $(jq -r '.unreleased[]' "$SHIPPED"); do
  if git -C "$ROOT" cat-file -e "$TAG:$key" 2>/dev/null; then fail "$key is listed unreleased but has a blob at $TAG"; else ok; fi
done

# The hash is of the tag's blob, so a 2.x copy on disk matches it and the
# 3.0 plugin copy (rewritten by #262) does not: the signal the migration reads.
H_OLD=$(git -C "$ROOT" show "$TAG:hooks/verify-before-stop.sh" | shasum -a 256 | cut -d' ' -f1)
[ "$(jq -r '.files["hooks/verify-before-stop.sh"]' "$SHIPPED")" = "$H_OLD" ] && ok || fail "the shipped hash of verify-before-stop.sh is the $TAG blob's"
H_NEW=$(shasum -a 256 < "$ROOT/hooks/verify-before-stop.sh" | cut -d' ' -f1)
[ "$H_NEW" != "$H_OLD" ] && ok || fail "the 3.0 copy differs from the $TAG one, so the 3.0 copy is not a usable reference"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
