#!/usr/bin/env bash
# A project one release behind whose rules/paths.md was installed by the old
# blanket substitution (#464): the "Framework-managed doc" row's Use column
# reads `.ai/features/foo/spec.md`, the resolved value the row forbids.
# `update` must render through lib/aidir-render.mjs, which writes the row's
# `$${aiDir}` back as a literal `${aiDir}`.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
# One minor behind the plugin, so update applies the files instead of
# stopping at "already up to date". Every migration is already recorded.
# shellcheck disable=SC2016 # a JS template literal, not a shell expansion
node -e '
const fs = require("fs");
const d = JSON.parse(fs.readFileSync(".myspec.json", "utf8"));
const [maj, min] = d.frameworkVersion.split(".").map(Number);
d.frameworkVersion = `${maj}.${Math.max(min - 1, 0)}.0`;
fs.writeFileSync(".myspec.json", JSON.stringify(d, null, 2) + "\n");
'
# shellcheck disable=SC2016 # literal text, not an expansion
sed 's#\$\${aiDir}#.ai#g; s#\${aiDir}#.ai#g' "$PLUGIN_ROOT/framework-files/rules/paths.md" > .claude/rules/paths.md
git_commit_all "chore: myspec installed one release ago"
