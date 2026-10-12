#!/usr/bin/env bash
# visualQuestions on: the rule the visual-questions blueprint installs is in place.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
node -e 'const f=".myspec.json",c=JSON.parse(require("fs").readFileSync(f,"utf8"));c.visualQuestions="auto";require("fs").writeFileSync(f,JSON.stringify(c,null,2)+"\n")'
mkdir -p .claude/rules
cp "$PLUGIN_ROOT/templates/rules/visual-questions.md" .claude/rules/visual-questions.md
git_commit_all "chore: initialise myspec with visual questions on"
