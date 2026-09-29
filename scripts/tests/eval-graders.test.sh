#!/usr/bin/env bash
# Every deterministic grader in evals/ must be able to fail:
# scripts/evals/check-graders.mjs runs each regex grader against its case's
# grader-samples.json and each Skill grader against synthetic calls.
# This suite runs it on the real evals/ and proves the checker itself
# catches a grader with no samples and a grader that accepts its fail sample.
#
# Usage: scripts/tests/eval-graders.test.sh

set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$SRC_ROOT/scripts/evals/check-graders.mjs"
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

out=$(node "$CHECK" "$SRC_ROOT/evals" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "real evals/: every deterministic grader passes its pass samples and fails its fail samples"; else nok "real evals/ grader checks" "$out"; fi

# A synthetic suite with three broken cases.
mkdir -p "$TMP/evals/no-samples/graders" "$TMP/evals/loose-regex/graders" "$TMP/evals/loose-skill/graders" "$TMP/evals/judge-only/graders"
for c in no-samples loose-regex loose-skill judge-only; do printf -- '---\ntags: [x]\n---\n\nprompt\n' > "$TMP/evals/$c/prompt.md"; done
printf -- "---\ntype: regex\npattern: 'REQ-004'\n---\n" > "$TMP/evals/no-samples/graders/flags.md"
printf -- "---\ntype: regex\npattern: 'invoice-reminders'\n---\n" > "$TMP/evals/loose-regex/graders/entry.md"
printf '{"entry": {"pass": ["- name: invoice-reminders"], "fail": ["- name: invoice-reminders-v2"]}}\n' > "$TMP/evals/loose-regex/grader-samples.json"
printf -- "---\ntype: tool_used\ntool: Skill\ninput_match: '\"skill\"\\\\s*:\\\\s*\"(?:[\\\\w-]+:)?code-review'\n---\n" > "$TMP/evals/loose-skill/graders/fired.md"
printf -- "---\ntype: llm\n---\n\nPASS if good.\n" > "$TMP/evals/judge-only/graders/judge.md"

out=$(node "$CHECK" "$TMP/evals" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "broken suite: exit 1" || nok "broken suite: exit 1 (got $rc)" "$out"
for want in "no-samples/flags: grader-samples.json needs" \
            "loose-regex/entry: accepts its fail sample" \
            "loose-skill/fired: accepts a skill that only shares the prefix" \
            "loose-skill/fired: accepts the built-in code-review skill" \
            "judge-only: no deterministic grader"; do
  if printf '%s' "$out" | grep -qF -- "$want"; then ok "catches: $want"; else nok "catches: $want" "$out"; fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
