#!/usr/bin/env bash
# Regression fixture for framework-files/manifest.json and hooks.json (#262).
#
#   710b715  command-scan.sh, branch-cleanup.sh and memory-claim-id.sh were
#            referenced as .claude/lib/<name> by hooks, skills and shipped rules
#            but had no manifest entry, so init/update never copied them. The
#            branch guard sources command-scan.sh and fails open without it:
#            every command was approved with no error.
#   4788851  memory-index.mjs, the fourth such helper, was missed the same way.
#   #262     3.0 stopped copying hooks and lib into projects: the hooks run
#            from the plugin's hooks.json and every helper is reached through
#            CLAUDE_PLUGIN_ROOT. The failure mode inverts: shipped content
#            that still names .claude/lib/<x> or .claude/hooks/<x> points at a
#            file no 3.0 project has, and a hook missing from hooks.json
#            never runs anywhere.
#
# The rules:
#   1. The manifest has no hooks or lib group, and every hook and lib helper
#      the 2.x manifest copied is a `removed` entry since 3.0.0, so update
#      retires the copy.
#   2. Every hooks/*.sh the plugin ships is a command in hooks.json, and every
#      hooks.json command names a shipped hook.
#   3. No shipped content names a .claude/lib/<x> or .claude/hooks/<x> that
#      the plugin has as lib/<x> or hooks/<x>. Paths the plugin does not ship
#      (a placeholder x.sh, a project hook in an example) are out of scope.
#   4. Every lib the hooks or hook-core source through $HOOK_LIB exists.
#
# Usage: manifest-regression.test.sh [plugin-root]

set -uo pipefail

PLUGIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MANIFEST="$PLUGIN/framework-files/manifest.json"
HOOKS_JSON="$PLUGIN/hooks.json"

if [ ! -f "$MANIFEST" ]; then
  echo "FATAL: manifest not found: $MANIFEST" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# --- 1. the manifest copies no hook or lib; each is retired ------------------
if [ "$(jq -r 'has("hooks") or has("lib")' "$MANIFEST")" = false ]; then ok; else fail "the manifest still has a hooks or lib group: 3.0 copies neither"; fi
if jq -e '.migrations | index("3.0.0-plugin-hooks")' "$MANIFEST" >/dev/null; then ok; else fail "the manifest lists the 3.0.0-plugin-hooks migration"; fi
# The registry normalisation (#266 review): memory-claim-id.sh reads only the
# one-line registry since 3.0, so update must rewrite a pre-1.28 one first.
if jq -e '.migrations | index("3.0.0-memory-registry")' "$MANIFEST" >/dev/null; then ok; else fail "the manifest lists the 3.0.0-memory-registry migration"; fi

RETIRED=$(jq -r '.removed | to_entries[] | select(.value.since == "3.0.0") | select(.key | startswith("hooks/") or startswith("lib/")) | "\(.key)\t\(.value.dest)"' "$MANIFEST")
for h in "$PLUGIN"/hooks/*.sh; do
  name=$(basename "$h")
  if printf '%s\n' "$RETIRED" | grep -qxF -- "hooks/$name"$'\t'".claude/hooks/$name"; then ok; else fail "hooks/$name has no removed entry since 3.0.0 with dest .claude/hooks/$name"; fi
done
for key in path-normalize.sh markdown-section-check.sh command-scan.sh glob-regex.sh hook-core.sh session-event.sh \
    stop-gate/arm.sh stop-gate/provision.sh stop-gate/run.sh stop-gate/attribute.sh stop-gate/report.sh \
    branch-cleanup.sh memory-claim-id.sh memory-index.mjs memory-files.mjs memory-doctor.mjs setup-doctor.mjs \
    set-isolation.sh worktree-provision.sh promote-to-worktree.sh task-worktree.sh myspec-config.sh myspec-config.mjs \
    myspec-config.schema.json plan-checkbox.sh friction-scan/scan.mjs friction-scan/metrics.mjs; do
  if printf '%s\n' "$RETIRED" | grep -qxF -- "lib/$key"$'\t'".claude/lib/$key"; then ok; else fail "lib/$key (copied by 2.x) has no removed entry since 3.0.0 with dest .claude/lib/$key"; fi
done

# --- 1b. the memory index headers are scaffolding, not framework files -------
# 2.x installed templates/index-{procedural,semantic,episodic}.md to
# ${aiDir}/.templates/ and nothing read them: init copies the header once
# (scaffolding/memory/<type>/index.md) and lib/memory-index.mjs keeps the
# table. 3.0 retires the copies (#266).
for kind in procedural semantic episodic; do
  key="templates/index-$kind.md"
  if [ "$(jq -r --arg k "$key" '.files | has($k)' "$MANIFEST")" = false ]; then ok; else fail "$key is still a files entry: update would keep installing it"; fi
  # shellcheck disable=SC2016 # the dest holds a literal ${aiDir} placeholder
  if [ "$(jq -r --arg k "$key" '.removed[$k] | "\(.since) \(.dest)"' "$MANIFEST")" = "3.0.0 \${aiDir}/.templates/index-$kind.md" ]; then ok; else fail "$key has no removed entry since 3.0.0 with dest \${aiDir}/.templates/index-$kind.md"; fi
  if [ ! -e "$PLUGIN/framework-files/$key" ] && [ -f "$PLUGIN/scaffolding/memory/$kind/index.md" ]; then ok; else fail "$key did not move to scaffolding/memory/$kind/index.md"; fi
done

# --- 2. hooks.json runs every shipped hook, and nothing else -----------------
if [ -f "$HOOKS_JSON" ]; then ok; else fail "hooks.json is missing: the plugin declares its hooks there"; fi
WIRED=$(jq -r '.. | objects | select(has("command")) | .command' "$HOOKS_JSON" 2>/dev/null | sed -E 's#.*/hooks/##; s/"//g' | sort -u)
for h in "$PLUGIN"/hooks/*.sh; do
  name=$(basename "$h")
  if printf '%s\n' "$WIRED" | grep -qxF -- "$name"; then ok; else fail "hooks/$name is not a command in hooks.json, so it runs nowhere"; fi
done
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -f "$PLUGIN/hooks/$name" ]; then ok; else fail "hooks.json runs hooks/$name, which the plugin does not ship"; fi
done <<< "$WIRED"
if jq -e '.. | objects | select(has("command")) | .command | select(startswith("\"${CLAUDE_PLUGIN_ROOT}\"/hooks/") | not)' "$HOOKS_JSON" >/dev/null 2>&1; then
  fail "a hooks.json command does not start with \"\${CLAUDE_PLUGIN_ROOT}\"/hooks/"
else
  ok
fi
# shellcheck disable=SC2016 # literal text, not an expansion
if jq -e '.hooks.SessionEnd[].hooks[] | select(.command | endswith("record-session-metrics.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then ok; else fail "SessionEnd runs record-session-metrics.sh"; fi
if [ "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$HOOKS_JSON")" = 330 ]; then ok; else fail "the Stop entry keeps its 330 s timeout (docs/stop-gate.md R13)"; fi

# --- 3. shipped content names no project-local copy of a shipped file --------
SHIPPED=()
for d in skills framework-files templates blueprints hooks lib; do
  [ -d "$PLUGIN/$d" ] && SHIPPED+=("$PLUGIN/$d")
done
REFS=$(grep -rnoE '\.claude/(lib|hooks)/[A-Za-z0-9._/-]+' \
    --exclude-dir=tests --exclude=manifest.json "${SHIPPED[@]}" 2>/dev/null \
  | sed -E 's/[.]+$//' | sort -u)
CHECKED=0
OFFENDERS=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  ref="${line##*:}"
  rel="${ref#.claude/}"            # lib/<name> or hooks/<name>
  [ -f "$PLUGIN/$rel" ] || continue
  CHECKED=$((CHECKED + 1))
  OFFENDERS="$OFFENDERS$line"$'\n'
done <<< "$REFS"
if [ -z "$OFFENDERS" ]; then
  ok
else
  while IFS= read -r line; do
    [ -n "$line" ] && fail "shipped content names a project-local copy the plugin no longer installs: ${line#"$PLUGIN"/}"
  done <<< "$OFFENDERS"
fi
[ "$CHECKED" -eq 0 ] && ok || fail "$CHECKED reference(s) to retired copies remain"

# --- 4. every lib a hook sources exists --------------------------------------
# shellcheck disable=SC2016 # a literal $HOOK_LIB, matched in the scripts' text
SOURCED=$(grep -hoE '\$HOOK_LIB/[A-Za-z0-9._/-]+' "$PLUGIN"/hooks/*.sh "$PLUGIN"/lib/hook-core.sh "$PLUGIN"/lib/stop-gate/*.sh 2>/dev/null \
  | sed -E 's#^\$HOOK_LIB/##; s/[.]+$//' | sort -u)
N=0
while IFS= read -r lib; do
  [ -n "$lib" ] || continue
  N=$((N + 1))
  if [ -f "$PLUGIN/lib/$lib" ]; then ok; else fail "a hook sources \$HOOK_LIB/$lib, which the plugin does not ship"; fi
done <<< "$SOURCED"
[ "$N" -gt 0 ] && ok || fail "the scan found at least one sourced lib"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
