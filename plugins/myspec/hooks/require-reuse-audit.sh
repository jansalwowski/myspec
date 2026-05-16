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

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

# Only tech-spec.md files under a features/ tree (any aiDir prefix, allows
# sub-feature nesting).
case "$FILE_PATH" in
  */features/*tech-spec.md) : ;;
  *) exit 0 ;;
esac

# Edit that removed the file (or never created it) — nothing to validate.
[ -f "$FILE_PATH" ] || exit 0

# Resolve repo root (best effort) for the opt-out lookup + lib resolution.
REPO_ROOT=""
if R=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null); then
  REPO_ROOT="$R"
fi

# Opt-out: reuseAudit.enabled === false in .myspec.json. Any other state
# (missing file, missing key, parse error, true) → validate (fail-open).
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.myspec.json" ]; then
  # NOTE: do not use `// empty` — jq's `//` treats boolean false as absent,
  # so `.reuseAudit.enabled // empty` would yield "" for an explicit false.
  ENABLED=$(jq -r '.reuseAudit.enabled' "$REPO_ROOT/.myspec.json" 2>/dev/null || true)
  if [ "$ENABLED" = "false" ]; then
    exit 0
  fi
fi

# Locate the shared validator. The hook + lib ship as a pair:
#   myspec repo:      hooks/require-reuse-audit.sh  + lib/markdown-section-check.sh
#   adopting project: .claude/hooks/...             + .claude/lib/...
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=""
for cand in \
  "$SCRIPT_DIR/../lib/markdown-section-check.sh" \
  "${REPO_ROOT:-}/.claude/lib/markdown-section-check.sh" \
  "${REPO_ROOT:-}/lib/markdown-section-check.sh"; do
  if [ -n "$cand" ] && [ -f "$cand" ]; then
    LIB="$cand"
    break
  fi
done

if [ -z "$LIB" ]; then
  # Helper missing — fail open rather than block on infra error.
  exit 0
fi

# shellcheck source=/dev/null
. "$LIB"

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

Every tech-spec must enumerate reuse candidates from the shared surfaces in
this project (packages/*, app lib/, app composables/) before introducing new
code. Add a "### Reuse audit" section with a table:

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| BaseDialog | packages/uikit | reuse | matches modal need in REQ-12 |
| useFormState | apps/web/src/composables | skip | needs multi-step state |

Decision must be "reuse" or "skip"; every "skip" row needs a Reason.

Findings:
${DIAG}
To opt a project out entirely, set "reuseAudit": { "enabled": false } in .myspec.json.
EOF
)

printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$REASON" | jq -Rs .)"
exit 0
