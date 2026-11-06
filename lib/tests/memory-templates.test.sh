#!/usr/bin/env bash
# Regression fixture for framework-files/templates/memory-{procedural,semantic,episodic}.md.
#
# memory-create drafts every new memory from these templates, and
# memory-index.mjs refuses to regenerate the indexes while any memory lacks
# `hook:`. The templates shipped without `hook:` (#393), so a memory filled in
# field by field was refused, and only two of three named `anchors:`.
#
# Each template is filled the way memory-create fills it (placeholders
# substituted, the hook set) and must pass `memory-index.mjs --check`. The
# same copy with the hook left empty must be refused, or the refusal could
# never fire for a memory drafted from the template.
#
# Usage: memory-templates.test.sh [path-to-repo-root]

set -uo pipefail

REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/lib/memory-index.mjs"
FILES="$REPO_ROOT/lib/memory-files.mjs"
TEMPLATES="$REPO_ROOT/framework-files/templates"
SCAFFOLD="$REPO_ROOT/scaffolding/memory"

for path in "$SCRIPT" "$FILES" "$TEMPLATES" "$SCAFFOLD"; do
  if [ ! -e "$path" ]; then
    echo "FATAL: not found: $path" >&2
    exit 1
  fi
done

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }

fail() {  # fail <description> [detail]
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '      %s\n' "$2" >&2
}

# fixture <name> -> a fresh repo at $ROOT/<name> with empty index scaffolding
fixture() {
  local repo="$ROOT/$1" kind
  mkdir -p "$repo"
  git -C "$repo" init -q .
  printf '{ "aiDir": ".ai" }\n' > "$repo/.myspec.json"
  for kind in procedural semantic episodic; do
    mkdir -p "$repo/.ai/memory/$kind"
    cp "$SCAFFOLD/$kind/index.md" "$repo/.ai/memory/$kind/index.md"
  done
}

# fill <template> <hook> -> the template with its placeholders substituted
fill() {
  sed -e 's/{NNN}/001/' -e 's/YYYY-MM-DD/2026-01-01/g' \
    -e "s/^hook: \"\"\$/hook: \"$2\"/" "$1"
}

HOOK="widget, cache, flush — keyword summary"

for kind in procedural semantic episodic; do
  template="$TEMPLATES/memory-$kind.md"
  prefix=$(printf '%s' "$kind" | cut -c1 | tr '[:lower:]' '[:upper:]')
  name="${prefix}001-template-check.md"

  if grep -q '^hook:' "$template"; then ok; else fail "$kind template has a hook: field"; fi
  if grep -q '^anchors:' "$template"; then ok; else fail "$kind template has an anchors: field"; fi
  if grep -q '^anchor:' "$template"; then fail "$kind template uses anchors:, not anchor:"; else ok; fi

  form=$(node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { frontmatterOf, parseAnchors } from '$FILES';
    console.log(parseAnchors(frontmatterOf(readFileSync('$template', 'utf8'))).form);
  " 2>&1)
  if [ "$form" = empty ]; then ok; else fail "$kind template anchors parse as empty" "form=$form"; fi

  # Filled: accepted, and the hook reaches the index row unchanged.
  fixture "filled-$kind"
  repo="$ROOT/filled-$kind"
  fill "$template" "$HOOK" > "$repo/.ai/memory/$kind/$name"
  out=$(cd "$repo" && node "$SCRIPT" 2>&1)
  code=$?
  if [ "$code" -eq 0 ]; then ok; else fail "filled $kind template regenerates the index" "exit=$code: $out"; fi
  out=$(cd "$repo" && node "$SCRIPT" --check 2>&1)
  code=$?
  if [ "$code" -eq 0 ]; then ok; else fail "filled $kind template passes --check" "exit=$code: $out"; fi
  if grep -qF -- "| $HOOK |" "$repo/.ai/memory/$kind/index.md"; then ok; else
    fail "filled $kind hook reaches the index row" "$(grep -F "${prefix}001" "$repo/.ai/memory/$kind/index.md")"
  fi

  # Hook left empty: refused.
  fixture "empty-$kind"
  repo="$ROOT/empty-$kind"
  fill "$template" "" > "$repo/.ai/memory/$kind/$name"
  out=$(cd "$repo" && node "$SCRIPT" --check 2>&1)
  code=$?
  if [ "$code" -ne 0 ]; then ok; else fail "$kind template with an empty hook is refused" "exit=0: $out"; fi
  case "$out" in
    *"missing hook"*) ok ;;
    *) fail "$kind empty-hook refusal names the missing hook" "$out" ;;
  esac
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
