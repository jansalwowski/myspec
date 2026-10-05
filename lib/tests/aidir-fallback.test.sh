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
  mkdir -p "$REPO/.claude"
  (cd "$REPO" && git init -q -b main .)
  printf '{"frameworkVersion":"0.0.0","project":{"name":"fx"}}\n' > "$REPO/.myspec.json"
  for d in "$@"; do mkdir -p "$REPO/$d"; done
}

# The hook runs from the plugin, which the harness names in CLAUDE_PLUGIN_ROOT.
export CLAUDE_PLUGIN_ROOT="$PLUGIN"

# What memory-files.mjs resolves for this repo.
lib_resolves() {
  node --input-type=module -e "
import { aiDirFor } from '$PLUGIN/lib/memory-files.mjs';
process.stdout.write(aiDirFor('$REPO'));
" 2>/dev/null
}

# Whether validate-frontmatter.sh polices a Write to <dir>/notes.md. It denies
# a frontmatter-less content (PreToolUse since #263, so the content travels in
# the payload), so a deny means it claimed that tree.
frontmatter_polices() {  # frontmatter_polices <dir>
  local dir="$1"
  mkdir -p "$REPO/$dir"
  local out
  out=$(printf '{"cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/%s/notes.md","content":"no frontmatter here\\n"}}' "$REPO" "$REPO" "$dir" \
    | bash "$PLUGIN/hooks/validate-frontmatter.sh" 2>&1)
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

# --- every reader honours a non-default aiDir through the one reader (#265) --
# Schema v2 routed the raw readers (jq, sed, fs) through lib/myspec-config.
# Each consumer below is driven with aiDir "knowledge": the configured tree
# is treated as the doc tree, and the .ai default is not.

build routed knowledge/features .ai/features knowledge/memory/procedural
printf '{"aiDir":"knowledge","frameworkVersion":"3.0.0","isolation":{"worktreeRoot":"wt"}}\n' > "$REPO/.myspec.json"
(cd "$REPO" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init)

# require-isolation-decision.sh: a doc under the aiDir never prompts for an
# isolation decision; the same doc under .ai is source and does. The block
# names the configured worktreeRoot.
isolation() {  # isolation <repo-relative file> -> block|allow
  local out
  out=$(printf '{"cwd":%s,"session_id":"aidir-sess","tool_input":{"file_path":%s}}' \
    "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s/%s' "$REPO" "$1" | jq -Rs .)" \
    | bash "$PLUGIN/hooks/require-isolation-decision.sh" 2>/dev/null)
  case "$out" in *'"permissionDecision": "deny"'*) printf 'block' ;; *) printf 'allow' ;; esac
  ISOLATION_OUT="$out"
}
expect_eq "$(isolation knowledge/features/x/spec.md)" "allow" "require-isolation-decision.sh exempts the configured aiDir"
isolation .ai/features/x/spec.md >/dev/null
expect_eq "$(isolation .ai/features/x/spec.md)" "block" "require-isolation-decision.sh does not exempt the .ai default when aiDir is knowledge"
case "$ISOLATION_OUT" in
  *'Isolated branch in wt/'*) ok ;;
  *) fail "require-isolation-decision.sh names the configured isolation.worktreeRoot in its block" ;;
esac

# no-absolute-paths.sh: a non-doc file under the aiDir is in scope, the same
# file under .ai is not.
nap() {  # nap <repo-relative file> -> deny|allow
  local out
  out=$(printf '{"cwd":%s,"tool_name":"Write","tool_input":{"file_path":%s,"content":"home: /Users/someone/x\\n"}}' \
    "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s/%s' "$REPO" "$1" | jq -Rs .)" \
    | bash "$PLUGIN/hooks/no-absolute-paths.sh" 2>/dev/null)
  case "$out" in *'"deny"'*) printf 'deny' ;; *) printf 'allow' ;; esac
}
expect_eq "$(nap knowledge/seed.yaml)" "deny" "no-absolute-paths.sh scopes the configured aiDir"
expect_eq "$(nap .ai/seed.yaml)" "allow" "no-absolute-paths.sh does not scope the .ai default when aiDir is knowledge"

# The stop gate's content check scopes files through the same function
# (lib/stop-gate/content.sh -> absolute_paths_scope in lib/content-checks.sh).
scope() {  # scope <repo-relative file> -> in|out
  (
    set +e
    HOOK_LIB="$PLUGIN/lib"
    # shellcheck source=lib/hook-core.sh
    . "$PLUGIN/lib/hook-core.sh"
    # shellcheck source=lib/content-checks.sh
    . "$PLUGIN/lib/content-checks.sh"
    if absolute_paths_scope "$REPO" "$1"; then printf 'in'; else printf 'out'; fi
  ) 2>/dev/null
}
expect_eq "$(scope knowledge/seed.yaml)" "in" "the stop gate's content scope covers the configured aiDir"
expect_eq "$(scope .ai/seed.yaml)" "out" "the stop gate's content scope leaves the .ai default out when aiDir is knowledge"

# memory-claim-id.sh: the highest ID is scanned in the configured tree.
printf -- '---\nid: P003\n---\n# x\n' > "$REPO/knowledge/memory/procedural/P003-x.md"
(cd "$REPO" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m mem)
CLAIMED=$(cd "$REPO" && MYSPEC_SKIP_MEMORY_DOCTOR=1 bash "$PLUGIN/lib/memory-claim-id.sh" procedural 2>/dev/null)
expect_eq "$CLAIMED" "P004" "memory-claim-id.sh scans the configured aiDir"

# feature-status-audit reads the same key through the same reader.
printf 'features: []\n' > "$REPO/knowledge/features/index.yaml"
AUDIT=$(cd "$REPO" && node "$PLUGIN/lib/feature-status-audit/audit.mjs" 2>/dev/null | grep -E '^ai dir:' | tr -s ' ')
expect_eq "$AUDIT" "ai dir: knowledge" "feature-status-audit resolves the configured aiDir"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
