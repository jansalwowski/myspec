#!/usr/bin/env bash
# Regression fixture for lib/settings-unwire.mjs (#262 review).
#
# update's 3.0.0-plugin-hooks migration removes the framework's hook entries
# from .claude/settings.json; this helper performs the rewrite so no prose
# describes it. The fixture is a consumer's real shape: the eight framework
# hooks in three spellings ("$CLAUDE_PROJECT_DIR"/…, bare, `bash "…"`), the
# PostToolUse matcher split in two, a project guard sharing the PreToolUse
# array, a project linter inside a framework matcher group, a project cleanup
# on Stop, SessionEnd present, and keys beside `hooks` that must survive
# untouched. Exactly the 12 framework entries go; the 3 project entries, their
# matchers and every other key stay; an emptied group, event and `hooks` key
# are dropped; the file keeps its 2-space layout; a second run removes nothing.
#
# Usage: settings-unwire.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../settings-unwire.mjs}"
PLUGIN=$(cd "$HERE/../.." && pwd)

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
SETTINGS="$REPO/.claude/settings.json"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

run() {  # run <args...>: sets OUTPUT and STATUS
  OUTPUT=$(node "$SCRIPT" --root "$REPO" --plugin-root "$PLUGIN" "$@" 2>&1); STATUS=$?
}
q() { jq -r "$1" "$SETTINGS"; }

build_fixture() {
  rm -rf "$REPO"
  mkdir -p "$REPO/.claude"
  (cd "$REPO" && git init -q -b main .)
  # shellcheck disable=SC2016 # literal settings text, not an expansion
  cat > "$SETTINGS" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(npm test)"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-worktree-context.sh" },
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-release-branch.sh\"" }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/require-isolation-decision.sh" },
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/lint-on-edit.sh\"" }
        ]
      },
      {
        "matcher": "MultiEdit|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/require-isolation-decision.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/validate-frontmatter.sh" },
          { "type": "command", "command": "./.claude/hooks/mark-code-changed.sh" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/no-absolute-paths.sh" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/require-reuse-audit.sh" }
        ]
      },
      {
        "matcher": "MultiEdit|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "bash .claude/hooks/validate-frontmatter.sh" },
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/mark-code-changed.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/mark-code-changed.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/verify-before-stop.sh", "timeout": 330 },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/cleanup-worktrees.sh" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/record-session-metrics.sh" }
        ]
      }
    ]
  },
  "enabledPlugins": {
    "myspec@myspec-marketplace": true
  }
}
JSON
}

# --- 1. the dry run plans the 12 removals and writes nothing -----------------
build_fixture
BEFORE=$(cat "$SETTINGS")
run --dry-run
[ "$STATUS" -eq 0 ] && ok || fail "dry run exits 0 (got $STATUS: $OUTPUT)"
[ "$(cat "$SETTINGS")" = "$BEFORE" ] && ok || fail "dry run writes nothing"
[ "$(printf '%s\n' "$OUTPUT" | grep -c '^removed: ')" -eq 12 ] && ok || fail "dry run plans exactly the 12 framework entries (got $(printf '%s\n' "$OUTPUT" | grep -c '^removed: '))"
printf '%s\n' "$OUTPUT" | grep -q '12 framework entries would be removed, 3 project entries kept (dry run' && ok || fail "the dry-run summary counts 12 removed and 3 kept (got: $(printf '%s\n' "$OUTPUT" | tail -1))"
printf '%s\n' "$OUTPUT" | grep -q 'guard-release-branch\|lint-on-edit\|cleanup-worktrees' && fail "no project entry is planned for removal" || ok

# --- 2. the rewrite ----------------------------------------------------------
run
[ "$STATUS" -eq 0 ] && ok || fail "the rewrite exits 0 (got $STATUS: $OUTPUT)"
printf '%s\n' "$OUTPUT" | grep -q '12 framework entries removed, 3 project entries kept$' && ok || fail "the summary counts 12 removed and 3 kept (got: $(printf '%s\n' "$OUTPUT" | tail -1))"
[ "$(q '[.. | objects | select(has("command")) | .command] | length')" = 3 ] && ok || fail "three commands remain"
for name in guard-worktree-context require-isolation-decision validate-frontmatter mark-code-changed no-absolute-paths require-reuse-audit verify-before-stop record-session-metrics; do
  [ "$(q "[.. | objects | select(has(\"command\")) | .command | select(test(\"$name\"))] | length")" = 0 ] && ok || fail "every $name.sh entry is gone, whatever its spelling"
done
# shellcheck disable=SC2016 # literal settings text, not an expansion
[ "$(q '.hooks.PreToolUse[0].matcher')" = Bash ] && [ "$(q '.hooks.PreToolUse[0].hooks[0].command')" = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/guard-release-branch.sh"' ] && ok || fail "the project guard keeps its place in the PreToolUse Bash group"
# shellcheck disable=SC2016 # literal settings text, not an expansion
[ "$(q '.hooks.PreToolUse[1].matcher')" = 'Write|Edit' ] && [ "$(q '.hooks.PreToolUse[1].hooks[0].command')" = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/lint-on-edit.sh"' ] && ok || fail "the project linter keeps its framework matcher group"
[ "$(q '.hooks.PreToolUse | length')" = 2 ] && ok || fail "the emptied MultiEdit|NotebookEdit group is dropped"
[ "$(q '.hooks | has("PostToolUse")')" = false ] && ok || fail "an event array left empty is dropped"
[ "$(q '.hooks | has("SessionEnd")')" = false ] && ok || fail "SessionEnd, framework-only, is dropped"
# shellcheck disable=SC2016 # literal settings text, not an expansion
[ "$(q '.hooks.Stop[0].hooks | length')" = 1 ] && [ "$(q '.hooks.Stop[0].hooks[0].command')" = '"$CLAUDE_PROJECT_DIR"/scripts/cleanup-worktrees.sh' ] && ok || fail "the project Stop cleanup stays, the plugin-root spelling of the stop gate goes"
[ "$(q '.permissions.allow[0]')" = 'Bash(npm test)' ] && [ "$(q '.enabledPlugins["myspec@myspec-marketplace"]')" = true ] && ok || fail "keys beside hooks are untouched"
[ "$(q 'keys | join(",")')" = 'enabledPlugins,hooks,permissions' ] && ok || fail "no key is added or lost"
head -2 "$SETTINGS" | tail -1 | grep -q '^  "permissions"' && ok || fail "the file keeps its 2-space layout"
[ "$(tail -c 1 "$SETTINGS" | od -An -c | tr -d ' ')" = '\n' ] && ok || fail "the file ends with a newline"

# --- 3. a second run is a no-op ---------------------------------------------
AFTER=$(cat "$SETTINGS")
run
[ "$STATUS" -eq 0 ] && ok || fail "the second run exits 0"
[ "$(cat "$SETTINGS")" = "$AFTER" ] && ok || fail "the second run changes nothing"
printf '%s\n' "$OUTPUT" | grep -q '0 framework entries removed, 3 project entries kept (nothing to write)' && ok || fail "the second run reports nothing to remove (got: $(printf '%s\n' "$OUTPUT" | tail -1))"

# --- 4. framework-only settings lose the hooks key, nothing else ------------
build_fixture
# shellcheck disable=SC2016 # literal settings text, not an expansion
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/verify-before-stop.sh","timeout":330}]}]},"permissions":{"allow":[]}}' > "$SETTINGS"
run
[ "$(q 'has("hooks")')" = false ] && [ "$(q 'has("permissions")')" = true ] && ok || fail "a hooks key left empty is removed and the rest of the file stays"

# --- 5. --json, a missing file, an unparseable file, a missing plugin -------
build_fixture
run --dry-run --json
[ "$(printf '%s' "$OUTPUT" | jq -r '.removed | length')" = 12 ] && [ "$(printf '%s' "$OUTPUT" | jq -r '.kept | length')" = 3 ] && [ "$(printf '%s' "$OUTPUT" | jq -r .written)" = false ] && ok || fail "--json carries removed, kept and written"
[ "$(printf '%s' "$OUTPUT" | jq -r '.removed[0].event + "/" + .removed[0].matcher')" = 'PreToolUse/Bash' ] && ok || fail "--json entries name the event and matcher"
rm "$SETTINGS"
run
[ "$STATUS" -eq 0 ] && printf '%s' "$OUTPUT" | grep -q 'nothing to unwire' && ok || fail "a missing settings file is not an error"
printf 'not json' > "$SETTINGS"
run
[ "$STATUS" -eq 2 ] && printf '%s' "$OUTPUT" | grep -q 'not valid JSON' && ok || fail "an unparseable settings file exits 2 and is left alone"
[ "$(cat "$SETTINGS")" = 'not json' ] && ok || fail "an unparseable file is not overwritten"
OUTPUT=$(node "$SCRIPT" --root "$REPO" --plugin-root "$ROOT/no-plugin" 2>&1); STATUS=$?
[ "$STATUS" -eq 2 ] && printf '%s' "$OUTPUT" | grep -q 'no hooks.json' && ok || fail "a plugin root without hooks.json exits 2 rather than remove nothing on a guess"

# --- 6. the names come from hooks.json, not a list in the script ------------
FAKE="$ROOT/plugin-extra"
mkdir -p "$FAKE"
jq '.hooks.Stop[0].hooks += [{type: "command", command: "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/extra-gate.sh"}]' "$PLUGIN/hooks.json" > "$FAKE/hooks.json"
build_fixture
# shellcheck disable=SC2016 # literal settings text, not an expansion
jq '.hooks.Stop[0].hooks += [{type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/extra-gate.sh"}]' "$SETTINGS" > "$SETTINGS.new" && mv "$SETTINGS.new" "$SETTINGS"
OUTPUT=$(node "$SCRIPT" --root "$REPO" --plugin-root "$FAKE" --dry-run 2>&1); STATUS=$?
printf '%s\n' "$OUTPUT" | grep -q 'extra-gate.sh' && ok || fail "a hook added to hooks.json is matched without a code change"
[ "$(printf '%s\n' "$OUTPUT" | grep -c '^removed: ')" -eq 13 ] && ok || fail "the extra hook is one more removal (got $(printf '%s\n' "$OUTPUT" | grep -c '^removed: '))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
