#!/usr/bin/env bash
# require-reuse-audit.sh
# PostToolUse hook (Write|Edit matcher) — blocks any write/edit to a
# `.../features/*/tech-spec.md` whose content lacks a valid `## Reuse audit`
# (or `### Reuse audit`) section.
#
# Policy: every tech-spec must enumerate reuse candidates from the project's
# shared surfaces before introducing new code (prevents reinvention). The
# `feature-tech-spec` skill produces the section; this hook is the mechanical
# gate. `feature-tech-spec-review` is the second pass.
#
# Validation (all must hold):
#   - a `## Reuse audit` / `### Reuse audit` heading exists
#   - a markdown table follows it with >= 1 data row
#   - every row has 4 cells; Decision in {reuse, skip}; skip rows have a Reason
#
# Fires on every Write/Edit (no "newly-added" gating) so the section cannot be
# silently deleted in a later edit. The check is a cheap regex/awk pass.
#
# Opt-out: `.myspec.json` with `reuseAudit.enabled == false` disables it.
# Fail-open: missing / unparseable `.myspec.json`, or absent key → validate.
#
# Output contract: emit `{"decision":"block","reason":"..."}` on failure.

set -euo pipefail

# The hook and its libs ship as a set: hooks/ + lib/ in the plugin,
# .claude/hooks/ + .claude/lib/ in a project. A missing jq or lib fails open
# rather than block on an infra error.
command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for HOOK_CORE in "$HOOK_DIR/../lib/hook-core.sh" "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/lib/hook-core.sh"; do
  [ -f "$HOOK_CORE" ] && break
done
if [ ! -f "$HOOK_CORE" ] || [ ! -f "$(dirname "$HOOK_CORE")/markdown-section-check.sh" ]; then
  exit 0
fi
# shellcheck source=lib/hook-core.sh
. "$HOOK_CORE"
# shellcheck source=lib/markdown-section-check.sh
. "$HOOK_LIB/markdown-section-check.sh"

payload_parse "$(cat)" FILE_PATH=.tool_input.file_path
[ -n "$FILE_PATH" ] || exit 0

# Only tech-spec.md files under a features/ tree (any aiDir prefix, allows
# sub-feature nesting).
case "$FILE_PATH" in
  */features/*tech-spec.md) : ;;
  *) exit 0 ;;
esac

# Edit that removed the file (or never created it) — nothing to validate.
[ -f "$FILE_PATH" ] || exit 0

# Opt-out: reuseAudit.enabled === false in the .myspec.json of the file's
# checkout (best effort). Any other state (missing file, missing key, parse
# error, true) → validate (fail-open).
REPO_ROOT=""
checkout_facts "$FILE_PATH" && REPO_ROOT="$CF_ROOT"
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.myspec.json" ]; then
  # NOTE: do not use `// empty` — jq's `//` treats boolean false as absent,
  # so `.reuseAudit.enabled // empty` would yield "" for an explicit false.
  ENABLED=$(jq -r '.reuseAudit.enabled' "$REPO_ROOT/.myspec.json" 2>/dev/null || true)
  if [ "$ENABLED" = "false" ]; then
    exit 0
  fi
fi

HEADING="Reuse audit"
DIAG=""

if ! out=$(assert_section_present "$FILE_PATH" "$HEADING"); then
  DIAG="${DIAG}${out}
"
elif ! out=$(assert_table_after_heading "$FILE_PATH" "$HEADING" 1); then
  DIAG="${DIAG}${out}
"
elif ! out=$(assert_reuse_audit_rows "$FILE_PATH" "$HEADING"); then
  DIAG="${DIAG}${out}
"
fi

if [ -z "$DIAG" ]; then
  exit 0
fi

REASON=$(cat <<EOF
BLOCKED: ${FILE_PATH} is missing a valid "## Reuse audit" section.

Every tech-spec must enumerate reuse candidates from the shared surfaces of
this project (see the topology file named in .myspec.json, or the shared
library/utility directories) before introducing new code. Add a
"### Reuse audit" section with a table:

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| {existing component} | {shared surface} | reuse | matches need in REQ-12 |
| {existing helper} | {shared surface} | skip | needs multi-step state |

Decision must be "reuse" or "skip"; every "skip" row needs a Reason.

Findings:
${DIAG}
To opt a project out entirely, set "reuseAudit": { "enabled": false } in .myspec.json.
EOF
)

printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$REASON" | jq -Rs .)"
exit 0
