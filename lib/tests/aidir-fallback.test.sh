#!/usr/bin/env bash
# Regression fixture for aiDir resolution.
#
# Since 2.0 aiDir is a required key in .myspec.json. The setup doctor reports
# its absence and the 2.0.0-schema migration in `update` writes it, so the
# shipped code no longer reads the disk to guess: with no key, every consumer
# resolves the documented default `.ai` — even when only ai/ exists on disk.
# In 1.x five consumers each carried their own detection and disagreed, which
# is the bug this fixture was written against. (Since 2.0 the session hook
# writes under .claude/state/ and no longer reads aiDir at all; the remaining
# consumers are the library, memory-claim-id.sh, verify-before-stop.sh and
# validate-frontmatter.sh.) The thing to prove is that the library and the
# frontmatter hook agree, that a configured value wins, and that a trailing
# slash never reaches a derived pattern.
#
# Usage: aidir-fallback.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect_eq() {  # expect_eq <got> <want> <description>
  if [ "$1" = "$2" ]; then ok; else fail "$3 (got '$1', want '$2')"; fi
}

# build <name> <dirs-to-create...> — a repo whose .myspec.json has no aiDir
build() {
  local name="$1"; shift
  REPO="$ROOT/$name"
  rm -rf "$REPO"
  mkdir -p "$REPO/.claude/hooks"
  (cd "$REPO" && git init -q -b main .)
  printf '{"frameworkVersion":"0.0.0","project":{"name":"fx"}}\n' > "$REPO/.myspec.json"
  for d in "$@"; do mkdir -p "$REPO/$d"; done
  cp "$PLUGIN/hooks/validate-frontmatter.sh" "$REPO/.claude/hooks/"
  chmod +x "$REPO/.claude/hooks/"*.sh
}

# What memory-files.mjs resolves for this repo.
lib_resolves() {
  node --input-type=module -e "
import { aiDirFor } from '$PLUGIN/lib/memory-files.mjs';
process.stdout.write(aiDirFor('$REPO'));
" 2>/dev/null
}

# Whether validate-frontmatter.sh polices a file at <dir>/notes.md. It blocks
# on missing frontmatter, so a non-zero decision means it claimed that tree.
frontmatter_polices() {  # frontmatter_polices <dir>
  local dir="$1"
  mkdir -p "$REPO/$dir"
  printf 'no frontmatter here\n' > "$REPO/$dir/notes.md"
  local out
  out=$(printf '{"cwd":"%s","tool_input":{"file_path":"%s/%s/notes.md"}}' "$REPO" "$REPO" "$dir" \
    | bash "$REPO/.claude/hooks/validate-frontmatter.sh" 2>&1)
  case "$out" in
    *block*|*BLOCKED*|*frontmatter*) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

# --- no key, only ai/ on disk: the default is not a guess -------------------

build plain-ai ai/memory
expect_eq "$(lib_resolves)" ".ai" "memory-files.mjs resolves the .ai default, not the ai/ tree on disk"
expect_eq "$(frontmatter_polices ai)" "no" "validate-frontmatter.sh does not police the unconfigured ai/ tree"
expect_eq "$(frontmatter_polices .ai)" "yes" "validate-frontmatter.sh polices the default tree"

# --- no key, nothing on disk ---------------------------------------------------

build neither
expect_eq "$(lib_resolves)" ".ai" "with no tree the documented .ai default is used"
expect_eq "$(frontmatter_polices .ai)" "yes" "validate-frontmatter.sh agrees with the library on the default"

# --- no key is a doctor error, so the default never hides a misconfiguration --

build keyless
OUT=$(node "$PLUGIN/lib/setup-doctor.mjs" --root "$REPO" --plugin-root "$PLUGIN" schema 2>&1)
if printf '%s\n' "$OUT" | grep -Eq '^ERROR myspec-missing-key: .*aiDir'; then ok
else fail "the setup doctor reports a missing aiDir as an error"; fi

# --- a configured value wins over anything on disk ----------------------------

build configured .ai/memory
printf '{"aiDir":"docs/ai","frameworkVersion":"0.0.0"}\n' > "$REPO/.myspec.json"
mkdir -p "$REPO/docs/ai"
expect_eq "$(lib_resolves)" "docs/ai" "a configured aiDir wins"
expect_eq "$(frontmatter_polices .ai)" "no" "validate-frontmatter.sh honours the configured value, not the .ai tree"
expect_eq "$(frontmatter_polices docs/ai)" "yes" "validate-frontmatter.sh polices the configured tree"

# --- a configured trailing slash does not break derived patterns -------------

build trailing
printf '{"aiDir":"ai/","frameworkVersion":"0.0.0"}\n' > "$REPO/.myspec.json"
expect_eq "$(lib_resolves)" "ai" "the library strips a configured trailing slash"
expect_eq "$(frontmatter_polices ai)" "yes" "validate-frontmatter.sh strips it too, so its glob still matches"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
