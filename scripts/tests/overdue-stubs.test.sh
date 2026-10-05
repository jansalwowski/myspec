#!/usr/bin/env bash
# Regression fixture for scripts/overdue-stubs.sh, the stub-lifetime check the
# /release skill runs as its stub gate (Step 2). The 2.0 retirement stubs shipped
# for eleven minors because nothing checked (#267); this keeps the check
# wired and its arithmetic honest: due at X.(Y+1).0, overdue from X.(Y+2).0
# and at any higher major, and never a false stub from a manual-only skill
# or from prose that quotes the frontmatter flag.
#
# Usage: overdue-stubs.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/overdue-stubs.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
expect_eq() { if [ "$1" = "$2" ]; then ok; else fail "$3 (got: $(printf %q "$1"), want: $(printf %q "$2"))"; fi; }
run() { OUTPUT=$(bash "$SCRIPT" --root "$FIX" "$@" 2>&1); STATUS=$?; }
flat() { tr '\t\n' '  ' | sed 's/ $//'; }

FIX="$TMP/repo"
mkdir -p "$FIX/skills"
# skill <dir>: write stdin to its SKILL.md.
skill() { mkdir -p "$FIX/skills/$1"; cat > "$FIX/skills/$1/SKILL.md"; }

skill old-name <<'MD'
---
name: old-name
description: "Retired in myspec 2.0 — renamed to new-name."
disable-model-invocation: true
allowed-tools: [Read]
---

# old-name (retired)

## Rules

- `disable-model-invocation: true` keeps this out of the always-loaded description budget.
- Remove this stub one minor cycle after 2.0.
MD

# A stub whose description carries no version: the removal note decides.
skill note-only <<'MD'
---
name: note-only
description: "Retired, not replaced."
disable-model-invocation: true
---

# note-only (retired)

- Remove this stub one minor cycle after 2.3.
MD

# A stub written after the lifetime rule moved to RELEASING.md: no removal
# note at all. "Retired in myspec" alone makes it a stub.
skill no-note <<'MD'
---
name: no-note
description: "Retired in myspec 2.5 — folded into other-skill."
disable-model-invocation: true
---

# no-note (retired)

Tell the user the replacement and stop.
MD

# Manual-only, not a stub: no removal note.
skill manual-only <<'MD'
---
name: manual-only
description: "A slash-command-only skill that stays."
disable-model-invocation: true
---

# manual-only

Runs on request.
MD

# Prose quoting the flag is not frontmatter (skill-verify does this).
skill quoter <<'MD'
---
name: quoter
description: "Use when a SKILL.md needs auditing. Do NOT use to create skills."
---

# quoter

A manual-only skill sets `disable-model-invocation: true`. Remove this stub is a phrase it checks for.
MD

# A directory without SKILL.md is not a skill.
mkdir -p "$FIX/skills/stale"

run --version 2.0.3
expect_eq "$STATUS" 0 "patch of the retiring minor: nothing overdue"
expect_eq "$(printf '%s' "$OUTPUT" | flat)" "shipping no-note retired 2.5 shipping note-only retired 2.3 shipping old-name retired 2.0" "every stub still shipping, in directory order"

run --version 2.1.0
expect_eq "$STATUS" 0 "one minor behind: due, not overdue"
expect_eq "$(printf '%s' "$OUTPUT" | grep old-name | flat)" "due old-name retired 2.0" "the 2.0 stub is due at 2.1.0"

run --version 2.2.0
expect_eq "$STATUS" 1 "two minors behind: overdue"
expect_eq "$(printf '%s' "$OUTPUT" | flat)" "shipping no-note retired 2.5 shipping note-only retired 2.3 overdue old-name retired 2.0" "only the 2.0 stub is overdue at 2.2.0"

run --version 2.4.1
expect_eq "$(printf '%s' "$OUTPUT" | grep note-only | flat)" "due note-only retired 2.3" "the removal note alone gives the version"

run --version 2.6.0
expect_eq "$(printf '%s' "$OUTPUT" | grep no-note | flat)" "due no-note retired 2.5" "a stub without a removal note is listed, not skipped"

run --version 2.11.0
expect_eq "$(printf '%s' "$OUTPUT" | flat)" "overdue no-note retired 2.5 overdue note-only retired 2.3 overdue old-name retired 2.0" "all overdue at 2.11.0"

run --version 3.0.0
expect_eq "$STATUS" 1 "a higher major: every older stub is overdue"

run --version 2.2.0
expect_eq "$(printf '%s' "$OUTPUT" | grep -c 'manual-only\|quoter\|stale')" 0 "manual-only skills, prose and empty dirs are not stubs"

# A stub with no readable version cannot be judged: exit 2, named.
skill unversioned <<'MD'
---
name: unversioned
description: "Retired."
disable-model-invocation: true
---

- Remove this stub when convenient.
MD
run --version 2.0.1
expect_eq "$STATUS" 2 "an unversioned stub is an error, not a pass"
expect_eq "$(printf '%s' "$OUTPUT" | grep -c 'unversioned: no "Retired in myspec X.Y"')" 1 "names the stub"
rm -r "$FIX/skills/unversioned"

bash "$SCRIPT" --root "$FIX" >/dev/null 2>&1
expect_eq "$?" 2 "no --version is a usage error"
bash "$SCRIPT" --root "$FIX" --version 2.0 >/dev/null 2>&1
expect_eq "$?" 2 "a two-part version is a usage error"
bash "$SCRIPT" --root "$TMP/nowhere" --version 2.0.0 >/dev/null 2>&1
expect_eq "$?" 2 "a root without skills/ is an error"

# The real repo: every stub it ships must be judgeable (never exit 2).
bash "$SCRIPT" --version 2.12.0 >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ] || [ "$rc" = 1 ]; then ok; else fail "real repo: exit $rc (a shipped stub has no readable retirement version)"; fi

# The /release skill runs the check as its stub gate; without that line
# the script catches nothing.
expect_ge() { if [ "$1" -ge "$2" ]; then ok; else fail "$3 (got: $1, want >= $2)"; fi; }
expect_ge "$(grep -c 'scripts/overdue-stubs.sh --version' "$REPO_ROOT/.claude/skills/release/SKILL.md")" 1 "release skill runs the check"
expect_ge "$(grep -c 'scripts/overdue-stubs.sh' "$REPO_ROOT/RELEASING.md")" 1 "RELEASING.md names the check"

echo "overdue-stubs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
