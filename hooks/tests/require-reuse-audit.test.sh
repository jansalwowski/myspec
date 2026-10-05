#!/usr/bin/env bash
# Regression fixture for require-reuse-audit.sh (#263).
#
# Until 3.0 the hook rescanned the whole tech-spec after every Write or Edit,
# so a tech-spec written before the hook existed blocked every later edit to
# it, and the only opt-out was the repo-global reuseAudit.enabled. Now it runs
# at PreToolUse and judges the call: (a) a Write that creates a tech-spec is
# denied when its content lacks a valid `## Reuse audit` section; (b) a Write
# or Edit that changes the section, or the marker, is denied when the result
# is not valid; (c) an edit elsewhere in a tech-spec is never judged, so a
# pre-hook tech-spec takes unrelated edits; the per-file marker
# `<!-- myspec:reuse-audit skip: <reason> -->` counts as a skip decision.
#
# Usage: require-reuse-audit.test.sh [path-to-hook]

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../require-reuse-audit.sh}"
# The hooks find their lib through CLAUDE_PLUGIN_ROOT, as the harness exports it.
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$HOOK")/.." && pwd)}"

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not executable: $HOOK" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
mkdir -p "$REPO/.ai/features/pay"
git init -q -b main "$REPO"
printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

SPEC="$REPO/.ai/features/pay/tech-spec.md"

VALID_SECTION='### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| BaseDialog | packages/uikit | reuse | matches REQ-12 |
| useFormState | composables | skip | needs multi-step state |
'
HEADER='---
title: "Pay -- Technical Specification"
status: draft
created: 2026-01-01
last_updated: 2026-01-01
---

### Architecture
Fits in.

'
FOOTER='
### Implementation Steps
1. Step one
'

write() {  # write <file> <content> -> OUT, RC
  OUT=$(jq -nc --arg c "$REPO" --arg f "$1" --arg b "$2" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: $b}}' | bash "$HOOK" 2>/dev/null); RC=$?
}
edit() {  # edit <file> <old> <new> -> OUT, RC
  OUT=$(jq -nc --arg c "$REPO" --arg f "$1" --arg o "$2" --arg n "$3" '{cwd: $c, tool_name: "Edit", tool_input: {file_path: $f, old_string: $o, new_string: $n}}' | bash "$HOOK" 2>/dev/null); RC=$?
}
reason() { printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null; }
expect_deny() {
  if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] \
      && [ "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" = block ]; then ok; else fail "$1 (exit $RC, output: ${OUT:0:200})"; fi
}
expect_quiet() {
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else fail "$1 (exit $RC, output: ${OUT:0:200})"; fi
}

# --- (a) creation -----------------------------------------------------------------
rm -f "$SPEC"
write "$SPEC" "${HEADER}${FOOTER}"
expect_deny "creating a tech-spec without the section is denied"
[ ! -e "$SPEC" ] && ok || fail "the hook writes nothing"
reason | grep -qF 'is missing a valid "## Reuse audit" section' && ok || fail "the deny keeps the friction-scan signature"
reason | grep -qF 'myspec:reuse-audit skip:' && ok || fail "the deny names the per-file marker"
reason | grep -qF 'reuseAudit' && fail "the deny no longer names the removed repo-global setting" || ok

write "$SPEC" "${HEADER}${VALID_SECTION}${FOOTER}"
expect_quiet "creating a tech-spec with a valid section passes"

write "$SPEC" "${HEADER}"'### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| Foo | lib | maybe | - |
'"${FOOTER}"
expect_deny "creating a tech-spec whose Decision is not reuse|skip is denied"
reason | grep -q 'Decision must be reuse|skip' && ok || fail "the deny names the bad decision"

write "$SPEC" "${HEADER}"'### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| Foo | lib | skip | - |
'"${FOOTER}"
expect_deny "creating a tech-spec with a skip row without a Reason is denied"

write "$SPEC" "${HEADER}"'### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
'"${FOOTER}"
expect_deny "creating a tech-spec with an empty table is denied"

edit "$REPO/.ai/features/typo/tech-spec.md" "### Architecture" "### Architecture v2"
expect_quiet "an Edit to a tech-spec path that does not exist is left to the tool's own error (PR #274 review)"
edit "$REPO/.ai/features/typo/tech-spec.md" "" "${HEADER}${FOOTER}"
expect_deny "an Edit with an empty old_string that creates a tech-spec without the section is denied"

write "$REPO/.ai/features/pay/spec.md" "${HEADER}${FOOTER}"
expect_quiet "a spec.md is not a tech-spec"

write "$REPO/.ai/features/pay/tech-spec.md.bak" "x"
expect_quiet "only tech-spec.md is in scope"

# --- the marker ------------------------------------------------------------------
write "$SPEC" "${HEADER}"'<!-- myspec:reuse-audit skip: greenfield service, no shared surfaces yet -->
'"${FOOTER}"
expect_quiet "the skip marker with a reason stands in for the section"

write "$SPEC" "${HEADER}"'<!--myspec:reuse-audit skip:   -->
'"${FOOTER}"
expect_deny "a marker without a reason is denied"
reason | grep -qF 'marker needs a reason' && ok || fail "the deny says the marker needs a reason"

# The 2.x repo-global switch no longer opts out: a project that still has it
# gets the per-file rule like any other.
printf '{"aiDir":".ai","reuseAudit":{"enabled":false}}\n' > "$REPO/.myspec.json"
rm -f "$SPEC"
write "$SPEC" "${HEADER}${FOOTER}"
expect_deny "reuseAudit.enabled=false in .myspec.json no longer disables the gate"
printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"

# --- (c) a pre-hook tech-spec takes unrelated edits ------------------------------
printf '%s' "${HEADER}${FOOTER}" > "$SPEC"
edit "$SPEC" "Fits in." "Fits in well."
expect_quiet "an edit to another section of a tech-spec without the section is allowed (regression #263)"
edit "$SPEC" "1. Step one" "1. Step one
2. Step two"
expect_quiet "an edit to the implementation steps of a pre-hook tech-spec is allowed"
write "$SPEC" "${HEADER}"'### Architecture
Rewritten.
'"${FOOTER}"
expect_quiet "a Write that rewrites a pre-hook tech-spec without touching the section is allowed"

# --- (b) a change to the section is judged ---------------------------------------
edit "$SPEC" "### Architecture" "### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| Foo | lib | reuse | fits |

### Architecture"
expect_quiet "an edit that adds a valid section to a pre-hook tech-spec passes"

edit "$SPEC" "### Architecture" "### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|

### Architecture"
expect_deny "an edit that adds an empty section is denied"
reason | grep -q 'need >= 1' && ok || fail "the deny names the missing rows"

printf '%s' "${HEADER}${VALID_SECTION}${FOOTER}" > "$SPEC"
edit "$SPEC" "| useFormState | composables | skip | needs multi-step state |" "| useFormState | composables | skip | - |"
expect_deny "an edit that blanks a skip row's Reason is denied"
edit "$SPEC" "| BaseDialog | packages/uikit | reuse | matches REQ-12 |" "| BaseDialog | packages/uikit | reuse | matches REQ-12 |
| Toast | packages/uikit | reuse | REQ-3 |"
expect_quiet "an edit that adds a valid row passes"
edit "$SPEC" "### Reuse audit" "### Reuse list"
expect_deny "an edit that renames the heading away is denied"
reason | grep -q 'missing required section' && ok || fail "the deny names the missing section"
edit "$SPEC" "$VALID_SECTION" ""
expect_deny "an edit that deletes the section is denied"
edit "$SPEC" "Fits in." "Fits in well."
expect_quiet "an edit elsewhere in a valid tech-spec passes"
edit "$SPEC" "Fits in." "Fits in.
<!-- myspec:reuse-audit skip: -->"
expect_deny "an edit that adds a reasonless marker is denied"

OUT=$(jq -nc --arg c "$REPO" --arg f "$SPEC" '{cwd: $c, tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "Fits in.", new_string: "Fits."}, {old_string: "| reuse | matches REQ-12 |", new_string: "| keep | matches REQ-12 |"}]}}' | bash "$HOOK" 2>/dev/null); RC=$?
expect_deny "a MultiEdit is judged by the section all its edits leave"

# A relative file_path resolves against the payload cwd.
OUT=$(jq -nc --arg c "$REPO" '{cwd: $c, tool_name: "Edit", tool_input: {file_path: ".ai/features/pay/tech-spec.md", old_string: "### Reuse audit", new_string: "### Gone"}}' | bash "$HOOK" 2>/dev/null); RC=$?
expect_deny "a repo-relative path is resolved against the cwd"

# A Write to an existing tech-spec with the marker that drops the marker
# and adds no section is a change to the state, and is denied.
printf '%s' "${HEADER}"'<!-- myspec:reuse-audit skip: legacy -->
'"${FOOTER}" > "$SPEC"
write "$SPEC" "${HEADER}${FOOTER}"
expect_deny "a Write that removes the marker without adding the section is denied"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
