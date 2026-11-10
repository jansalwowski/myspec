#!/usr/bin/env bash
# Tests for lib/markdown.mjs (tableCells, frontmatterBlock, frontmatterText)
# and lib/plugin-root.mjs, the helpers #429 shares between memory-files,
# delivery-metrics, setup-doctor and mockup-config-check.
#
# Usage: markdown.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/.."
ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

check() {           # check <description> <expected> <js expression>
  local got
  got=$(cd "$LIB" && node --input-type=module -e "
    import * as md from './markdown.mjs';
    import { pluginRoot } from './plugin-root.mjs';
    import { frontmatterOf } from './memory-files.mjs';
    const r = await (async () => $3)();
    process.stdout.write(JSON.stringify(r));
  " 2>&1)
  if [ "$got" = "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      want %s\n      got  %s\n' "$1" "$2" "$got" >&2; fi
}

# --- tableCells ---------------------------------------------------------------

check "piped row" '["a","b"]' "md.tableCells('| a | b |')"
check "no outer pipes" '["a","b"]' "md.tableCells('a | b')"
check "escaped pipe kept by default" '["a \\| b","c"]' "md.tableCells('| a \\\\| b | c |')"
check "escaped pipe unescaped on request" '["a | b","c"]' "md.tableCells('| a \\\\| b | c |', { unescape: true })"
check "trailing escaped pipe is cell text" '["a","b \\|"]' "md.tableCells('| a | b \\\\|')"
check "empty cells kept" '["Q1","","x"]' "md.tableCells('| Q1 |  | x |')"
check "delimiter row" '["---",":-:"]' "md.tableCells('|---|:-:|')"

# --- frontmatterBlock / frontmatterText ---------------------------------------

check "LF block" '"a: 1\nb: 2"' "md.frontmatterText('---\\na: 1\\nb: 2\\n---\\nbody')"
check "CRLF block" '"a: 1"' "md.frontmatterText('---\\r\\na: 1\\r\\n---\\r\\nbody')"
check "BOM block" '"a: 1"' "md.frontmatterText('\\uFEFF---\\na: 1\\n---\\n')"
check "BOM kept apart" '65279' "md.frontmatterBlock('\\uFEFF---\\na: 1\\n---\\n').bom.charCodeAt(0)"
check "closing line with a trailing space" '"a: 1"' "md.frontmatterText('---\\na: 1\\n--- \\nbody')"
check "a ---- line does not close" '"a: 1\n---- x\nb: 2"' "md.frontmatterText('---\\na: 1\\n---- x\\nb: 2\\n---\\n')"
check "unclosed block" '""' "md.frontmatterText('---\\na: 1\\nbody')"
check "not on line 1" '""' "md.frontmatterText('\\n---\\na: 1\\n---\\n')"
check "no frontmatter" '-1' "md.frontmatterBlock('# Title\\n').close"
check "horizontal rules read as a block by default" '3' "md.frontmatterBlock('---\\n\\nSome intro\\n---\\n').close"
check "yamlOnly rejects horizontal rules" '-1' "md.frontmatterBlock('---\\n\\nSome intro\\n---\\n', { yamlOnly: true }).close"
check "yamlOnly accepts lists, comments, nesting" '4' "md.frontmatterBlock('---\\ntags:\\n  - x\\n# note\\n---\\n', { yamlOnly: true }).close"

# memory-files frontmatterOf now goes through frontmatterText.
check "frontmatterOf LF" '"id: P001"' "frontmatterOf('---\\nid: P001\\n---\\n# x')"
check "frontmatterOf CRLF (was empty before #429)" '"id: P001"' "frontmatterOf('---\\r\\nid: P001\\r\\n---\\r\\n')"
check "frontmatterOf no block" '""' "frontmatterOf('# x\\n')"

# --- pluginRoot -----------------------------------------------------------------

mkdir -p "$ROOT/plug/framework-files" "$ROOT/plug/lib/sub" "$ROOT/other"
printf '{}\n' > "$ROOT/plug/framework-files/manifest.json"
check "explicit path wins" "\"$ROOT/other\"" "pluginRoot('file://$ROOT/plug/lib/x.mjs', { explicit: '$ROOT/other', env: {} })"
check "CLAUDE_PLUGIN_ROOT when it is a plugin" "\"$ROOT/plug\"" "pluginRoot('file://$ROOT/other/x.mjs', { env: { CLAUDE_PLUGIN_ROOT: '$ROOT/plug' } })"
check "CLAUDE_PLUGIN_ROOT ignored when not a plugin" "\"$ROOT/plug\"" "pluginRoot('file://$ROOT/plug/lib/sub/x.mjs', { env: { CLAUDE_PLUGIN_ROOT: '$ROOT/other' } })"
check "walks up from the script" "\"$ROOT/plug\"" "pluginRoot('file://$ROOT/plug/lib/sub/x.mjs', { env: {} })"
check "none found" 'null' "pluginRoot('file://$ROOT/other/x.mjs', { env: {} })"

printf '\nmarkdown: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
