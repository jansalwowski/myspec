#!/usr/bin/env bash
# Regression fixture for the aiDir fallback.
#
# When .myspec.json carries no aiDir, five pieces of shipped code have to agree
# on where the docs live. They did not: memory-files.mjs, memory-claim-id.sh
# and verify-before-stop.sh assumed ".ai" while validate-frontmatter.sh and
# mark-code-changed.sh assumed "ai". A keyless project therefore had its
# session logs written to one tree and its memories read from the other, with
# nothing reporting the mismatch.
#
# The fix is detection rather than a better guess, so the thing to prove is
# behavioural and in both directions: with only ai/ on disk every consumer
# resolves ai, with only .ai/ every consumer resolves .ai, and a configured
# value still wins over both. A grep for a shared constant would not catch a
# consumer that stopped calling the resolver.
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
  cp "$PLUGIN/hooks/validate-frontmatter.sh" "$PLUGIN/hooks/mark-code-changed.sh" "$REPO/.claude/hooks/"
  chmod +x "$REPO/.claude/hooks/"*.sh
}

# What memory-files.mjs resolves for this repo.
lib_resolves() {
  node --input-type=module -e "
import { aiDirFor } from '$PLUGIN/lib/memory-files.mjs';
process.stdout.write(aiDirFor('$REPO'));
" 2>/dev/null
}

# Where mark-code-changed.sh puts a session log — it creates the tree it picks.
hook_resolves() {
  printf '{"session_id":"aidirtest","cwd":"%s","tool_input":{"file_path":"%s/src/app.ts"}}' "$REPO" "$REPO" \
    | bash "$REPO/.claude/hooks/mark-code-changed.sh" >/dev/null 2>&1
  if   [ -d "$REPO/.ai/memory/sessions/active" ]; then printf '.ai'
  elif [ -d "$REPO/ai/memory/sessions/active" ];  then printf 'ai'
  else printf 'none'; fi
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

# --- only ai/ on disk --------------------------------------------------------

build plain-ai ai/memory
expect_eq "$(lib_resolves)" "ai" "memory-files.mjs follows an existing ai/ tree"
expect_eq "$(hook_resolves)" "ai" "mark-code-changed.sh writes into the same tree"
expect_eq "$(frontmatter_polices ai)" "yes" "validate-frontmatter.sh polices the same tree"

# --- only .ai/ on disk -------------------------------------------------------

build dot-ai .ai/memory
expect_eq "$(lib_resolves)" ".ai" "memory-files.mjs follows an existing .ai/ tree"
expect_eq "$(hook_resolves)" ".ai" "mark-code-changed.sh writes into the same tree"
expect_eq "$(frontmatter_polices .ai)" "yes" "validate-frontmatter.sh polices the same tree"

# --- neither on disk: the documented default ---------------------------------

build neither
expect_eq "$(lib_resolves)" ".ai" "with no tree the documented .ai default is used"
expect_eq "$(hook_resolves)" ".ai" "the hook agrees with the library on the default"

# --- both on disk: ambiguous, .ai wins, doctor names it ----------------------

build both ai/memory .ai/memory
expect_eq "$(lib_resolves)" ".ai" "with both trees .ai wins"
expect_eq "$(hook_resolves)" ".ai" "the hook agrees with the library when both exist"
if node "$PLUGIN/lib/memory-doctor.mjs" --root "$REPO" 2>/dev/null | grep -q 'second-ai-tree'; then ok
else fail "memory-doctor reports the ambiguity as second-ai-tree"; fi

# --- a configured value still wins over what is on disk ----------------------

build configured .ai/memory
printf '{"aiDir":"docs/ai","frameworkVersion":"0.0.0"}\n' > "$REPO/.myspec.json"
mkdir -p "$REPO/docs/ai"
expect_eq "$(lib_resolves)" "docs/ai" "a configured aiDir beats detection"
expect_eq "$(hook_resolves)" "none" "the hook honours the configured value, not the .ai tree"

# --- a configured trailing slash does not break derived patterns -------------

build trailing
printf '{"aiDir":"ai/","frameworkVersion":"0.0.0"}\n' > "$REPO/.myspec.json"
expect_eq "$(lib_resolves)" "ai" "the library strips a configured trailing slash"
expect_eq "$(frontmatter_polices ai)" "yes" "validate-frontmatter.sh strips it too, so its glob still matches"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
