#!/usr/bin/env bash
# Regression fixture: no shipped hook command is cwd-relative (#216, #217, #218).
#
# A hook command that names its script by a relative path (`.claude/hooks/x.sh`,
# `./hooks/x.sh`) resolves against the session's cwd. Once a session cd's into a
# subdirectory the shell exits 127, and a failing Stop or PreToolUse hook is
# non-blocking, so the gate it carries is skipped with no warning. Consumer
# hooks must run through "$CLAUDE_PROJECT_DIR", plugin hooks through
# "${CLAUDE_PLUGIN_ROOT}".
#
# Scope: every `command` value in a JSON file under templates/ or
# framework-files/, the plugin's hooks.json, and every `"command": "..."` line
# in the Markdown of those trees and of the init, update and doctor skills,
# which show settings snippets a model copies.
#
# Usage: hook-commands-absolute.test.sh [plugin-root]

set -uo pipefail

PLUGIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# relative(command): the hooks/ script tokens of a command that are named by
# neither an absolute path nor a variable.
SCAN='
const relative = (command) => command.trim().split(/\s+/)
  .map((token) => token.replace(/["\x27]/g, ""))
  .filter((token) => /(^|\/)hooks\/[^\s\/]+$/.test(token))
  .filter((token) => !token.startsWith("$") && !token.startsWith("/"));
'

# Every command value in the JSON files, as "<file>\t<command>".
JSON_COMMANDS=$(cd "$PLUGIN" && find templates framework-files -name '*.json' -print 2>/dev/null; echo hooks.json)
# shellcheck disable=SC2016 # literal text, not an expansion
COMMANDS=$(cd "$PLUGIN" && printf '%s\n' "$JSON_COMMANDS" | node -e '
const fs = require("fs");
const files = fs.readFileSync(0, "utf8").split("\n").filter(Boolean);
const out = [];
const walk = (file, n) => {
  if (Array.isArray(n)) { n.forEach((x) => walk(file, x)); return; }
  if (!n || typeof n !== "object") { return; }
  if (typeof n.command === "string") { out.push(`${file}\t${n.command}`); }
  Object.values(n).forEach((x) => walk(file, x));
};
files.forEach((file) => {
  // A JSONC template (comments) is not settings wiring; it is skipped.
  try { walk(file, JSON.parse(fs.readFileSync(file, "utf8"))); } catch { /* not strict JSON */ }
});
console.log(out.join("\n"));
')

# "command": "..." lines in Markdown, JSON-unescaped, as "<file>:<line>\t<command>".
# shellcheck disable=SC2016 # literal text, not an expansion
MD_COMMANDS=$(cd "$PLUGIN" && grep -rnE '"command"[[:space:]]*:[[:space:]]*"' --include='*.md' \
  templates framework-files skills/init skills/update skills/doctor 2>/dev/null | node -e '
const lines = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean);
lines.forEach((line) => {
  const [, where, value] = line.match(/^([^:]+:\d+):.*"command"\s*:\s*("(?:[^"\\]|\\.)*")/) || [];
  if (!where) { return; }
  try { console.log(`${where}\t${JSON.parse(value)}`); } catch { /* not a JSON string */ }
});
')

HOOK_COMMANDS=$(printf '%s\n%s\n' "$COMMANDS" "$MD_COMMANDS" | grep -E 'hooks/[^[:space:]]+' || true)

# The scan must see the shipped wiring, or an empty result would pass vacuously.
# The plugins/myspec mirror ships no templates/, so that check needs the file.
[ ! -f "$PLUGIN/templates/settings-hooks.json" ] ||
if printf '%s\n' "$HOOK_COMMANDS" | grep -q '^templates/settings-hooks.json	'; then ok; else fail "the scan reads templates/settings-hooks.json"; fi
if printf '%s\n' "$HOOK_COMMANDS" | grep -q '^hooks.json	'; then ok; else fail "the scan reads the plugin hooks.json"; fi

# shellcheck disable=SC2016 # literal text, not an expansion
OFFENDERS=$(printf '%s\n' "$HOOK_COMMANDS" | node -e "$SCAN"'
require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean).forEach((line) => {
  const [where, command] = line.split("\t");
  if (relative(command).length > 0) { console.log(`${where}: ${command}`); }
});
')

if [ -z "$OFFENDERS" ]; then
  ok
else
  while IFS= read -r line; do
    fail "cwd-relative hook command (prefix \"\$CLAUDE_PROJECT_DIR\"/ or \"\${CLAUDE_PLUGIN_ROOT}\"/): $line"
  done <<< "$OFFENDERS"
fi

# The scanner itself: each relative spelling is caught, each portable one passes.
# shellcheck disable=SC2016 # literal text, not an expansion
SELF=$(node -e "$SCAN"'
const cases = [
  [".claude/hooks/verify-before-stop.sh", 1],
  ["./.claude/hooks/verify-before-stop.sh", 1],
  ["./hooks/verify-before-stop.sh", 1],
  ["bash .claude/hooks/x.sh --flag", 1],
  ["\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/verify-before-stop.sh", 0],
  ["\"${CLAUDE_PLUGIN_ROOT}\"/hooks/verify-before-stop.sh", 0],
  ["bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh\"", 0],
  ["/opt/hooks/x.sh", 0],
  ["npm test", 0],
];
cases.forEach(([command, want]) => {
  if ((relative(command).length > 0 ? 1 : 0) !== want) { console.log(command); }
});
')
if [ -z "$SELF" ]; then ok; else fail "the scanner misjudges: $SELF"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
