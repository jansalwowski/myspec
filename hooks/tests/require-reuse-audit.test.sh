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
reason() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
expect_deny() {  # the PreToolUse deny alone: no legacy decision/reason pair since the 3.0 host floor
  if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] \
      && [ "$(printf '%s' "$OUT" | jq -r 'has("decision") or has("reason")' 2>/dev/null)" = false ]; then ok; else fail "$1 (exit $RC, output: ${OUT:0:200})"; fi
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
reason | grep -qF 'Decision must be reuse or skip' && ok || fail "the deny names the bad decision"
reason | grep -qF 'has invalid rows in its "## Reuse audit" table' && ok || fail "a row-only deny opens with the row line"
reason | grep -qF '| Candidate |' && fail "a row-only deny leaves out the section template" || ok

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

# #165: only a file named tech-spec.md under ${aiDir}/features/, outside plans/.
for p in .ai/features/pay/old-tech-spec.md .ai/features/pay/draft-tech-spec.md \
    .ai/features/pay/plans/2026-01-01-tech-spec.md src/features/login/tech-spec.md \
    src/features/login/a-tech-spec.md; do
  write "$REPO/$p" "${HEADER}${FOOTER}"
  expect_quiet "$p is not a feature tech-spec"
done
write "$REPO/.ai/features/pay/sub/tech-spec.md" "${HEADER}${FOOTER}"
expect_deny "a sub-feature tech-spec is still judged"
printf '{"aiDir":"docs/ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"
write "$REPO/docs/ai/features/pay/tech-spec.md" "${HEADER}${FOOTER}"
expect_deny "a tech-spec under a configured aiDir is judged"
write "$SPEC" "${HEADER}${FOOTER}"
expect_quiet "a tech-spec outside the configured aiDir is not"
printf '{"aiDir":".ai","frameworkVersion":"3.0.0"}\n' > "$REPO/.myspec.json"

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


# --- the pre-filter: a call that cannot concern the hook starts no process -----
# The hook runs on every Write and Edit, and only a path ending in
# tech-spec.md can be its business. The raw payload is matched with a builtin
# before jq starts or a lib is sourced. Observed through a jq on PATH that
# logs each start. The filter must never skip what the full check would deny,
# so each payload shape that hides the name from a raw match is shown to
# reach the check: the payloads are written by hand, as jq would not escape
# them this way.
SHIM="$ROOT/shim"
JQ_LOG="$ROOT/jq.log"
mkdir -p "$SHIM"
printf '#!/bin/sh\necho jq >> "%s"\nexec "%s" "$@"\n' "$JQ_LOG" "$(command -v jq)" > "$SHIM/jq"
chmod +x "$SHIM/jq"
raw() {  # raw <json> -> OUT, RC for the payload exactly as given; JQ_RUNS, how often the hook started jq
  : > "$JQ_LOG"
  OUT=$(printf '%s' "$1" | PATH="$SHIM:$PATH" bash "$HOOK" 2>/dev/null); RC=$?
  JQ_RUNS=$(wc -l < "$JQ_LOG" | tr -d ' ')
}
no_jq() { [ "$JQ_RUNS" -eq 0 ] && ok || fail "$1 (jq started $JQ_RUNS times)"; }
BODY=$(printf '%s' "${HEADER}${FOOTER}" | jq -Rs .)
rm -f "$SPEC"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO/src/a.ts\",\"content\":\"export const a = 1;\\n\"}}"
expect_quiet "a source write passes"
no_jq "a source write exits before jq starts"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO/.ai/features/pay/spec.md\",\"content\":$BODY}}"
expect_quiet "another feature doc passes"
no_jq "a write to another feature doc exits before jq starts"
# The control: the same shape with the tech-spec path reaches the check, and the log sees it.
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$SPEC\",\"content\":$BODY}}"
expect_deny "creating a tech-spec without the section is still denied"
[ "$JQ_RUNS" -gt 0 ] && ok || fail "the jq log sees the full check run"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${SPEC//\//\\/}\",\"content\":$BODY}}"
expect_deny "a path with escaped slashes (\\/) is still denied"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${SPEC%tech-spec.md}tech\\u002dspec.md\",\"content\":$BODY}}"
expect_deny "a name carrying a unicode escape (tech\\u002dspec.md) is still denied"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${SPEC%.md}.\\u006dd\",\"content\":$BODY}}"
expect_deny "an extension carrying a unicode escape (.\\u006dd) is still denied"
# payload_parse strips trailing newlines from the path, so the full check sees a tech-spec.
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$SPEC\\n\",\"content\":$BODY}}"
expect_deny "a path with a trailing newline is still denied"
raw "{
  \"tool_input\" : { \"content\" : $BODY, \"file_path\" : \"$SPEC\" },
  \"cwd\" : \"$REPO\"
}"
expect_deny "a pretty-printed payload with the path last is still denied"
# What the full check has always let pass stays quiet: the filter follows the
# check, it does not widen it.
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO/src/a.ts\",\"content\":\"// see .ai/features/pay/tech-spec.md\"}}"
expect_quiet "a tech-spec path that appears only in the content passes"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$SPEC\",\"new_source\":\"x\"}}"
expect_quiet "a NotebookEdit carries no file_path and passes"
raw "{\"cwd\":\"$REPO\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO/.ai/features/pay/TECH-SPEC.MD\",\"content\":$BODY}}"
expect_quiet "an upper-case TECH-SPEC.MD is outside the scope, as it was before the filter"

# The filter matches bytes, not characters of the hook's locale (PR #449
# review): [[ =~ ]] decodes the payload in the locale first, and where the
# bytes before the path are not valid there the match failed and a write the
# full check denies was skipped. A raw invalid byte in a UTF-8 locale, and a
# valid UTF-8 payload from a project in a non-ASCII directory under a locale
# with another encoding. The second needs the locale installed.
raw_in() {  # raw_in <locale> <payload file> -> OUT, RC
  OUT=$(LC_ALL="$1" bash "$HOOK" < "$2" 2>/dev/null); RC=$?
}
# Read once and matched with case: under pipefail `locale -a | grep -q` fails
# when grep leaves early and locale dies of SIGPIPE.
LOCALES=$(locale -a 2>/dev/null || true)
UTF8_LOCALE=$(printf '%s\n' "$LOCALES" | grep -iE '^(C|en_US)\.utf-?8$' | head -1)
printf '{"note":"caf\351","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":%s}}' "$REPO" "$SPEC" "$BODY" > "$ROOT/invalid-byte.json"
raw_in "${UTF8_LOCALE:-en_US.UTF-8}" "$ROOT/invalid-byte.json"
expect_deny "a payload with a raw invalid byte before the path is still denied"
NREPO="$ROOT/プロジェクト"
mkdir -p "$NREPO/.ai/features/pay"
git init -q -b main "$NREPO"
printf '{"aiDir":".ai"}\n' > "$NREPO/.myspec.json"
printf '{"cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/.ai/features/pay/tech-spec.md","content":%s}}' "$NREPO" "$NREPO" "$BODY" > "$ROOT/non-ascii-dir.json"
raw_in "${UTF8_LOCALE:-en_US.UTF-8}" "$ROOT/non-ascii-dir.json"
expect_deny "a doc in a non-ASCII directory is denied in a UTF-8 locale"
for loc in ja_JP.SJIS zh_TW.Big5; do
  case $'\n'"$LOCALES"$'\n' in *$'\n'"$loc"$'\n'*) HAVE=1 ;; *) HAVE=0 ;; esac
  if [ "$HAVE" = 1 ]; then
    raw_in "$loc" "$ROOT/non-ascii-dir.json"
    expect_deny "a doc in a non-ASCII directory is still denied under LC_ALL=$loc"
  else
    echo "SKIP  locale $loc is not installed"
  fi
done

# --- a check that could not run: the outcome is what it was ---------------------
# reuse_audit_issues returns 2 when a command failed (lib/content-checks.sh).
# Under set -e that status must not end the hook: with the row check's awk
# failing a bad row is allowed in silence, as before the function had a status.
# shellcheck source=lib/tests/failing-tool.sh
. "$CLAUDE_PLUGIN_ROOT/lib/tests/failing-tool.sh"
failing_tool "$ROOT/awkfail" awk 'function trim'
rm -f "$SPEC"
BAD_ROW="${HEADER}### Reuse audit

| Candidate | Surface | Decision | Reason |
|-----------|---------|----------|--------|
| BaseDialog | packages/uikit | maybe | matches REQ-12 |
${FOOTER}"
write "$SPEC" "$BAD_ROW"
expect_deny "fixture: the bad row is denied when awk works"
OUT=$(jq -nc --arg c "$REPO" --arg f "$SPEC" --arg b "$BAD_ROW" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: $b}}' | PATH="$ROOT/awkfail:$PATH" bash "$HOOK" 2>/dev/null); RC=$?
expect_quiet "a failed row awk allows in silence, exit 0"
# The pre-check: an Edit to an existing tech-spec is judged only when it
# changes the section, read by reuse_audit_state. With the heading awk failing
# on both sides, both states read empty and equal; a state that could not be
# read must not let the edit through unjudged.
failing_tool "$ROOT/headingfail" awk 'tolower(h)'
rm -f "$SPEC"
printf '%s' "${HEADER}${VALID_SECTION}${FOOTER}" > "$SPEC"
OUT=$(jq -nc --arg c "$REPO" --arg f "$SPEC" '{cwd: $c, tool_name: "Edit", tool_input: {file_path: $f, old_string: "| reuse |", new_string: "| maybe |"}}' | PATH="$ROOT/headingfail:$PATH" bash "$HOOK" 2>/dev/null); RC=$?
expect_deny "a section edit is judged when the heading awk fails, not skipped as unchanged"
rm -f "$SPEC"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
