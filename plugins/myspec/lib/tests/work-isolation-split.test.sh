#!/usr/bin/env bash
# Regression fixture for the work-isolation split (#226).
#
# The rule used to be path-gated to a fixed list of source directories, so it
# never loaded for edits in config/, plugins/, bin/, scripts/ and the rest,
# while the hooks enforced isolation everywhere. It is now an always-loaded
# core, and the procedure lives in ${aiDir}/work-isolation.md, which the block
# messages cite. Always loaded means every session of every project pays for
# it, so the core has its own cap well under setup-doctor's 1000-token rule
# budget, measured the same way (bytes / 4, rounded).
#
# Usage: work-isolation-split.test.sh [plugin-root]

set -uo pipefail

PLUGIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
RULE="$PLUGIN/framework-files/rules/work-isolation.md"
PROCEDURE="$PLUGIN/framework-files/work-isolation.md"
MANIFEST="$PLUGIN/framework-files/manifest.json"
CORE_CAP=200   # tokens; the design target is ~150

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

for f in "$RULE" "$PROCEDURE" "$MANIFEST"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

frontmatter() { awk 'NR == 1 && /^---$/ { on = 1; next } on && /^---$/ { exit } on' "$1"; }

# Always loaded: no paths: key (setup-doctor and Claude Code both treat a rule
# with paths: as conditional).
if frontmatter "$RULE" | grep -q '^paths:'; then
  fail "the work-isolation rule has paths: frontmatter, so it loads only for matching edits"
else
  ok
fi

# Installed size: init/update substitute ${aiDir}; .ai is the default.
# shellcheck disable=SC2016 # ${aiDir} is the literal placeholder
BYTES=$(sed 's#${aiDir}#.ai#g' "$RULE" | wc -c | tr -d ' ')
TOKENS=$(( (BYTES + 2) / 4 ))
# A zero size means the measurement itself failed; never read it as "under the cap".
if [ "$BYTES" -gt 0 ] && [ "$TOKENS" -le "$CORE_CAP" ]; then
  ok
else
  fail "the work-isolation core is ~$TOKENS tokens; the cap is $CORE_CAP (move procedure to framework-files/work-isolation.md)"
fi

# The core points at the procedure and keeps #237's session-id rule.
# shellcheck disable=SC2016 # ${aiDir} is the literal placeholder
grep -qF '${aiDir}/work-isolation.md' "$RULE" && ok || fail "the core does not name \${aiDir}/work-isolation.md"
grep -qF 'only from a block message' "$RULE" && ok || fail "the core lost the rule that the session id comes only from a block message"

# The procedure ships: a manifest files entry, which installs to ${aiDir}/<key>.
if jq -e '.files["work-isolation.md"].type == "overwrite"' "$MANIFEST" >/dev/null; then
  ok
else
  fail "framework-files/work-isolation.md has no overwrite entry in the manifest files block, so init/update never install it"
fi

# The procedure carries what moved out of the rule.
# shellcheck disable=SC2016 # backticks are literal Markdown
for needle in 'set-isolation.sh <session_id>' 'worktree-provision.sh' 'git -C <worktree>' 'promote-to-worktree.sh' 'Recommend `develop`'; do
  grep -qF -- "$needle" "$PROCEDURE" && ok || fail "the procedure file is missing: $needle"
done

# Hooks cite the procedure, never the rule, for what to do next.
for hook in require-isolation-decision.sh guard-worktree-context.sh; do
  src="$PLUGIN/hooks/$hook"
  grep -qF 'work-isolation.md' "$src" && ok || fail "$hook does not cite the procedure file"
  if grep -v '^[[:space:]]*#' "$src" | grep -qF '.claude/rules/work-isolation.md'; then
    fail "$hook sends the model to the rule; the procedure is in the aiDir file"
  else
    ok
  fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
