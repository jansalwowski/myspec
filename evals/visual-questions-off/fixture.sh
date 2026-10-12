#!/usr/bin/env bash
# visualQuestions off: no rule installed, so a design question stays in the terminal.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
node -e 'const f=".myspec.json",c=JSON.parse(require("fs").readFileSync(f,"utf8"));c.visualQuestions="off";require("fs").writeFileSync(f,JSON.stringify(c,null,2)+"\n")'
git_commit_all "chore: initialise myspec with visual questions off"
