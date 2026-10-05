#!/usr/bin/env bash
# Regression fixture for setup-doctor.mjs.
#
# The doctor replaces prose that a language model re-derived on every audit
# run, so the thing that has to be proven is that each check fires on the shape
# it was written for and stays quiet on a clean install — a doctor that warns
# about a correct installation is the failure mode the whole design is aimed
# at, not a cosmetic problem.
#
# Builds a real install from the plugin manifest (the same copy rules init
# follows), asserts it is clean, then breaks one thing per check. A third pass
# covers the severity policy that decides whether the stop hook can block:
# identical drift is an ERROR at a matching version and a WARN while an update
# is pending, because the second one is not the project's fault.
#
# Usage: setup-doctor.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../setup-doctor.mjs}"
PLUGIN=$(cd "$HERE/../.." && pwd)

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect_line() {     # expect_line <regex> <description>
  if printf '%s\n' "$OUTPUT" | grep -Eq -- "$1"; then ok; else fail "$2 (no line matching: $1)"; fi
}

expect_no_line() {  # expect_no_line <regex> <description>
  if printf '%s\n' "$OUTPUT" | grep -Eq -- "$1"; then fail "$2 (unexpected line matching: $1)"; else ok; fi
}

expect_exit() {     # expect_exit <want> <description>
  if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1)"; fi
}

run_doctor() {      # run_doctor <args...>; sets OUTPUT and STATUS
  OUTPUT=$(node "$SCRIPT" --root "$REPO" --plugin-root "$PLUGIN" "$@" 2>&1)
  STATUS=$?
}

# Install the framework the way init does: manifest is the source of truth for
# what is copied and where, so the fixture cannot drift from the real layout.
build_fixture() {
  rm -rf "$REPO"
  mkdir -p "$REPO"
  (cd "$REPO" && git init -q -b main .)
  # shellcheck disable=SC2016 # literal text, not an expansion
  node -e '
const {readFileSync,writeFileSync,mkdirSync,copyFileSync,chmodSync}=require("fs");
const {join,dirname}=require("path");
const plugin=process.argv[1], root=process.argv[2], aiDir="ai";
const m=JSON.parse(readFileSync(join(plugin,"framework-files","manifest.json"),"utf8"));
const V=m.frameworkVersion;
// init and update substitute ${aiDir} into the DOCUMENTS they copy, so copying
// those verbatim would compare plugin bytes against plugin bytes and could
// never catch a drift check that forgot the substitution.
const put=(src,dest)=>{mkdirSync(join(root,dirname(dest)),{recursive:true});writeFileSync(join(root,dest),readFileSync(src,"utf8").split("${aiDir}").join(aiDir));return dest;};
for(const k of Object.keys(m.files)){
  const dest = k.startsWith("templates/") ? aiDir+"/.templates/"+k.slice(10) : aiDir+"/"+k;
  put(join(plugin,"framework-files",k),dest);
}
for(const [k,e] of Object.entries(m.rules)){ put(join(plugin,"framework-files","rules",k),e.dest); }
// Since 3.0 the hooks and lib run from the plugin: nothing of them is copied
// and settings.json carries no framework entry. A 3.0 init writes no
// settings.json at all; this one holds a project hook, so the checks on
// project-owned wiring have something to read.
mkdirSync(join(root,"scripts"),{recursive:true});
writeFileSync(join(root,"scripts","own-hook.sh"),"#!/bin/sh\nexit 0\n");
chmodSync(join(root,"scripts","own-hook.sh"),0o755);
mkdirSync(join(root,".claude"),{recursive:true});
writeFileSync(join(root,".claude","settings.json"),JSON.stringify({hooks:{Stop:[{hooks:[{type:"command",command:"\"$CLAUDE_PROJECT_DIR\"/scripts/own-hook.sh"}]}]}},null,2)+"\n");
writeFileSync(join(root,".myspec.json"),JSON.stringify({aiDir,frameworkVersion:V,project:{name:"fixture"},migrations:m.migrations||[]},null,2)+"\n");
copyFileSync(join(plugin,"templates","verification.json"),join(root,".claude","verification.json"));
mkdirSync(join(root,aiDir,"features"),{recursive:true});
copyFileSync(join(plugin,"scaffolding","features","index.yaml"),join(root,aiDir,"features","index.yaml"));
mkdirSync(join(root,aiDir,"memory"),{recursive:true});
writeFileSync(join(root,"CLAUDE.md"),"# Fixture\n\nRules live in `.claude/rules/workflow.md`.\n");
' "$PLUGIN" "$REPO"
}

set_json() {  # set_json <file> <node-expression-on-d>
  node -e '
const fs=require("fs");
const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
(new Function("d", process.argv[2]))(d);
fs.writeFileSync(process.argv[1], JSON.stringify(d,null,2)+"\n");
' "$REPO/$1" "$2"
}

# --- pass 1: a correct installation is quiet ---------------------------------

build_fixture
run_doctor

expect_exit 0 "clean install exits 0"
expect_no_line '^ERROR' "clean install reports no errors"
expect_no_line 'framework-drift' "clean install reports no drift"
expect_no_line 'myspec-schema-stale' "a 2.0-shape .myspec.json is not stale"
expect_no_line 'framework-removed' "a 3.0 install holds none of the retired copies"
expect_no_line 'hook-copy-retired' "a 3.0 install holds no hook or lib copy under .claude/"
expect_no_line 'dead-path-ref' "framework-owned rules are not scanned for dead refs"
expect_no_line 'topology-missing' "a project with no topologyFile key is not reported"
expect_no_line 'over-budget' "framework-owned rules are not warned about as over budget"
expect_no_line 'framework files over their always-loaded budget' "no plugin-owned always-loaded rule is over the 1000-token budget (regression guard for the 2.0 rules diet)"
expect_no_line 'hook-missing' "the project's \$CLAUDE_PROJECT_DIR hook command resolves"
expect_no_line 'hook-wired-locally' "a project hook is not a framework hook"
expect_no_line 'hook-command-relative' "a \$CLAUDE_PROJECT_DIR command is not reported as relative"
expect_line 'setup doctor: 0 error\(s\)' "summary counts zero errors"

# The stop hook runs exactly these two groups; they must be silent on a clean
# install or the gate blocks every session.
run_doctor --quiet wiring schema
expect_exit 0 "the blocking groups exit 0 on a clean install"
expect_no_line '^ERROR' "the blocking groups report no errors on a clean install"

# --- pass 1b: framework hooks still wired in a settings file (#262) ----------
# Since 3.0 the plugin's hooks.json runs the framework hooks, and the harness
# keeps a plugin's handler separate from a settings copy of the same command:
# an entry a 2.x init or update wrote runs the retired copy a second time. The
# doctor reports every such entry by the script's name, whatever the path in
# front of it, and leaves the project's own entries in the same arrays alone.
# At a matching version that is an error (the gate blocks on it); while an
# update is pending it is a warning, because update is what unwires it.
cp "$REPO/.claude/settings.json" "$ROOT/settings-clean.json"
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json '
d.hooks.PreToolUse = [
  { matcher: "Bash", hooks: [{ type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-worktree-context.sh" }] },
  { matcher: "Write|Edit", hooks: [{ type: "command", command: ".claude/hooks/require-isolation-decision.sh" }, { type: "command", command: "bash \"$CLAUDE_PROJECT_DIR/scripts/lint-on-edit.sh\"" }] },
];
d.hooks.PostToolUse = [
  { matcher: "Write|Edit|MultiEdit|NotebookEdit", hooks: [
    { type: "command", command: "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/validate-frontmatter.sh\"" },
    { type: "command", command: "./.claude/hooks/mark-code-changed.sh" },
    { type: "command", command: "${CLAUDE_PROJECT_DIR}/.claude/hooks/no-absolute-paths.sh" },
  ] },
  { matcher: "Bash", hooks: [{ type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/mark-code-changed.sh" }] },
];
d.hooks.Stop[0].hooks.push({ type: "command", command: "\"${CLAUDE_PLUGIN_ROOT}\"/hooks/verify-before-stop.sh", timeout: 330 });
d.hooks.SessionEnd = [{ hooks: [{ type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/record-session-metrics.sh" }] }];
'
printf '#!/bin/sh\nexit 0\n' > "$REPO/scripts/lint-on-edit.sh"
chmod 755 "$REPO/scripts/lint-on-edit.sh"

run_doctor wiring
expect_exit 1 "framework hooks still wired in settings.json fail the wiring group"
REPORTED_COUNT=$(printf '%s\n' "$OUTPUT" | grep -cE '^ERROR hook-wired-locally: .claude/settings.json:')
if [ "$REPORTED_COUNT" -eq 8 ]; then ok; else fail "every framework entry is reported once, whatever its spelling (want 8, got $REPORTED_COUNT)"; fi
for name in guard-worktree-context require-isolation-decision validate-frontmatter mark-code-changed no-absolute-paths verify-before-stop record-session-metrics; do
  expect_line "hook-wired-locally: .claude/settings.json: hook command \".*$name.sh\"* runs the framework hook $name.sh" "the entry for $name.sh is reported by its script name"
done
# shellcheck disable=SC2016 # literal text, not an expansion
expect_line 'hook command "bash "\$CLAUDE_PROJECT_DIR/.claude/hooks/validate-frontmatter.sh"" runs the framework hook' "an interpreter-led framework entry is reported"
expect_line 'hook command "./.claude/hooks/mark-code-changed.sh" runs the framework hook' "a bare relative framework entry is reported"
expect_line 'hook command ""\$\{CLAUDE_PLUGIN_ROOT\}"/hooks/verify-before-stop.sh" runs the framework hook' "a plugin-root spelling in settings is still a second copy of the plugin's own entry"
expect_line 'run: /myspec:update' "a framework entry names update as the fix"
expect_no_line 'hook-wired-locally: .claude/settings.json: hook command ".*own-hook.sh' "the project's own hook in the same arrays is not reported"
expect_no_line 'hook-wired-locally: .claude/settings.json: hook command ".*lint-on-edit.sh' "a project hook in the same matcher group is not reported"
expect_no_line 'hook-missing' "a framework entry is not also reported as missing"
expect_no_line 'hook-command-relative' "a framework entry is not also reported as relative"
expect_no_line 'WARN +hook-wired-locally' "no framework entry is downgraded to a warning at a matching version"

# While an update is pending the same entries are warnings, like framework
# drift: the migration that unwires them lands with the version stamp, and a
# Stop hook run in between must not block on the fix that is still landing.
cp "$REPO/.myspec.json" "$ROOT/myspec-matching.json"
set_json .myspec.json 'd.frameworkVersion = "0.0.1"'
run_doctor wiring
expect_exit 0 "framework entries do not fail the wiring group while an update is pending"
expect_line 'WARN +hook-wired-locally: .claude/settings.json: hook command ".*verify-before-stop.sh' "a framework entry is a warning while an update is pending"
expect_line 'run: /myspec:update' "the pending-update warning still names update as the fix"
expect_no_line 'ERROR hook-wired-locally' "no framework entry is an error while an update is pending"
cp "$ROOT/myspec-matching.json" "$REPO/.myspec.json"
cp "$ROOT/settings-clean.json" "$REPO/.claude/settings.json"

# settings.local.json is the developer's own file and update never rewrites it,
# so a framework entry there is a warning that names the hand fix: an error
# would block every stop with nothing the framework can do to clear it.
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":".claude/hooks/verify-before-stop.sh"}]}]}}' > "$REPO/.claude/settings.local.json"
run_doctor --quiet wiring schema
expect_exit 0 "a framework entry in settings.local.json does not fail the wiring group"
expect_no_line '^ERROR hook-wired-locally' "settings.local.json adds no hook-wired-locally error"
run_doctor wiring schema
expect_line 'WARN +hook-wired-locally: .claude/settings.local.json: hook command ".claude/hooks/verify-before-stop.sh"' "a framework entry in settings.local.json is a warning"
expect_line 'fix: delete that entry from .claude/settings.local.json by hand' "the settings.local.json warning says to delete the entry by hand"
rm "$REPO/.claude/settings.local.json"

# The project's own hooks keep their checks. A relative command is a warning
# (the doctor does not own what that hook guards), a missing script an error,
# an exec'd script without the bit an error, an interpreter-led one not.
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:"scripts/own-hook.sh"})'
run_doctor wiring
expect_exit 0 "a project-owned relative hook command does not fail the wiring group"
expect_line 'WARN +hook-command-relative: .claude/settings.json: hook command "scripts/own-hook.sh"' "a project-owned relative hook command is a warning"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_line 'fix: add the "\$CLAUDE_PROJECT_DIR"/ prefix by hand' "a project-owned relative hook command names the prefix fix"
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.pop()'

# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/ghost.sh"})'
run_doctor wiring
expect_line 'ERROR hook-missing: .claude/hooks/ghost.sh' "a missing project hook is an error, reported by its repo-relative path"
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.pop()'

chmod 644 "$REPO/scripts/own-hook.sh"
run_doctor wiring
expect_line 'ERROR hook-not-executable: scripts/own-hook.sh' "a directly exec'd project hook without the bit is an error"
expect_line 'run: chmod \+x scripts/own-hook.sh' "the finding carries a literal fix command"
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "bash \"$CLAUDE_PROJECT_DIR/scripts/own-hook.sh\""'
run_doctor wiring
expect_exit 0 "an interpreter-led project hook with a non-executable script exits 0"
expect_no_line 'hook-not-executable' "a script run through bash needs no executable bit"
expect_no_line 'hook-command-relative' "an interpreter-led \$CLAUDE_PROJECT_DIR command is not relative"
chmod 755 "$REPO/scripts/own-hook.sh"

# A .sh that is only an argument is not the hook script, and neither is a path
# a command merely mentions: nothing may claim a file the harness never runs.
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "npx prettier --check src/setup.sh"'
run_doctor wiring
expect_no_line 'hook-missing: src/setup.sh' "a .sh passed as an argument is not treated as the hook script"
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "echo .claude/hooks/verify-before-stop.sh"'
run_doctor wiring
expect_no_line 'hook-wired-locally' "a mentioned framework hook path is not a run of it"

cp "$ROOT/settings-clean.json" "$REPO/.claude/settings.json"

# --- pass 2: one break per check ---------------------------------------------

printf '\n# hand edit\n' >> "$REPO/.claude/rules/paths.md"
rm "$REPO/ai/.templates/session-log.md"
perl -0pi -e 's/<!-- myspec:framework-start -->//' "$REPO/ai/pre-flight.md"
perl -0pi -e 's/^# .*$/# Renamed Locally/m' "$REPO/ai/anti-patterns.md"
set_json .myspec.json 'd.frameworkFiles = {"rules/ideas.md": {version: "1.27.0", lastUpdated: "2026-08-01"}}'
printf '## Project anchors\n' > "$REPO/.claude/rules/ai-setup-audit.md"
mkdir -p "$REPO/ai/memory/sessions/active" && printf -- '---\nstatus: active\n---\n' > "$REPO/ai/memory/sessions/active/old.md"
mkdir -p "$REPO/.claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$REPO/.claude/hooks/own.sh"
chmod 644 "$REPO/.claude/hooks/own.sh"
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/own.sh"})'
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:".claude/hooks/ghost.sh"})'
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.PreToolUse = [{matcher:"Bash",hooks:[{type:"command",command:"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-worktree-context.sh"}]}]'
cp "$PLUGIN/lib/hook-core.sh" "$REPO/.claude/hooks/guard-worktree-context.sh"
printf '#!/usr/bin/env bash\nif [ 1 =\n' > "$REPO/.claude/hooks/broken.sh"
chmod +x "$REPO/.claude/hooks/broken.sh"
set_json .myspec.json 'd.aiDir = "ai/"'
set_json .myspec.json 'd.topologyFile = "backbone.yml"'
printf 'not json' > "$REPO/.claude/verification.json"
printf 'features:\n    - name: misindented\n      status: complete\n' > "$REPO/ai/features/index.yaml"
{
  echo '# Fixture'
  echo
  # shellcheck disable=SC2016 # literal text, not an expansion
  echo 'Rules live in `.claude/rules/nope.md`. Route to `/myspec:not-a-skill`.'
  # shellcheck disable=SC2016 # literal text, not an expansion
  echo 'Run `/bootstrap` first; `/deps-check` weekly; `/vue-component` for components.'
  head -c 4000 /dev/zero | tr '\0' 'x'
} > "$REPO/CLAUDE.md"

run_doctor

expect_exit 1 "a broken install exits 1"
expect_line 'ERROR framework-drift: .claude/rules/paths.md' "a hand-edited rule at a matching version is an error"
expect_line 'ERROR framework-missing: ai/.templates/session-log.md' "a deleted framework file is an error"
expect_line 'ERROR marker-missing: ai/pre-flight.md' "a marker-merge file without markers is an error"
expect_line 'WARN +myspec-schema-stale: .myspec.json' "pre-2.0 per-file bookkeeping is a warning"
expect_line 'WARN +doctor-rule-unrenamed: .claude/rules/ai-setup-audit.md' "the pre-rename doctor extension is a warning"
expect_line 'WARN +sessions-unmigrated: ai/memory/sessions/active' "a 1.x live session log is a warning"
expect_line 'ERROR hook-not-executable: .claude/hooks/own.sh' "a registered project hook without +x is an error"
expect_line 'ERROR hook-missing: .claude/hooks/ghost.sh' "a registered hook that does not exist is an error"
expect_line 'WARN +hook-unregistered: .claude/hooks/broken.sh' "an unwired project hook script is a warning"
expect_line 'ERROR hook-syntax: .claude/hooks/broken.sh' "a project hook that fails bash -n is an error"
expect_line 'ERROR hook-wired-locally: .claude/settings.json: hook command ".*guard-worktree-context.sh" runs the framework hook' "a framework hook still wired is an error"
expect_line 'WARN +hook-copy-retired: .claude/hooks/guard-worktree-context.sh' "a framework hook copy still on disk is a warning"
expect_no_line 'hook-unregistered: .claude/hooks/guard-worktree-context.sh' "a retired framework copy is not also an unregistered project hook"
expect_no_line 'framework-removed: .claude/hooks/guard-worktree-context.sh' "a retired framework copy is not also reported by the install group"
expect_line 'ERROR aidir-trailing-slash' "a trailing slash on aiDir is an error"
expect_line 'ERROR verification-unparseable' "unparseable verification.json is an error"
expect_line 'ERROR features-index-unreadable: ai/features/index.yaml:2' "a mis-indented manifest entry is an error, with its line"
expect_line 'ERROR framework-drift: ai/anti-patterns.md: header above' "a changed marker-merge header is drift, since update owns the header"
expect_line 'WARN +over-budget: CLAUDE.md' "an oversized project CLAUDE.md is a warning"
expect_line 'WARN +dead-path-ref: CLAUDE.md' "a dead path reference in a project file is a warning"
expect_no_line 'references /(bootstrap|deps-check|vue-component),' "a slash command is not a dead path reference"
expect_line 'WARN +dead-skill-ref: CLAUDE.md' "a reference to a skill the plugin does not ship is a warning"
expect_line 'WARN +topology-missing: .myspec.json' "a topologyFile pointing at nothing is a warning, not a blocker"
expect_line 'bootstrap and the reuse audit fall back to guessing' "the topology finding says what it breaks"
expect_line 'run: chmod \+x .claude/hooks/own.sh' "findings carry a literal fix command"

run_doctor --quiet
expect_no_line '^WARN' "--quiet suppresses warnings"
expect_line '^ERROR' "--quiet keeps errors"

run_doctor wiring
expect_line 'ERROR hook-syntax' "a group selector runs its own checks"
expect_no_line 'framework-drift' "a group selector excludes other groups"

# The stop hook runs exactly these two groups. A features-manifest error must
# not reach them: the gate fires on uncommitted .claude/ changes, and blocking
# a stop over a file the session never touched is a false block.
run_doctor --quiet wiring schema
expect_no_line 'features-index-unreadable' "the blocking groups exclude the features manifest"
expect_line 'ERROR hook-syntax' "the blocking groups still carry wiring errors"

run_doctor features
expect_line 'ERROR features-index-unreadable' "the features group carries the manifest check"
expect_no_line 'hook-syntax' "the features group excludes wiring"

run_doctor hook-not-executable
expect_line 'ERROR hook-not-executable' "a check selector runs that check"
expect_no_line 'hook-syntax' "a check selector excludes its group siblings"

run_doctor --json
if printf '%s' "$OUTPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.exit(j.errors.length>0 && j.errors[0].remediation && j.errors[0].group ? 0 : 1)})'; then ok; else fail "--json emits finding records with group and remediation"; fi

# --- pass 2b: manifest note: cap and volatile state (issue #86) --------------

build_fixture
LONG=$(head -c 151 /dev/zero | tr '\0' 'x')
{
  echo 'features:'
  echo '  - name: clean'
  echo '    status: in-progress'
  echo '    note: "Export deferred to v2; see spec Out of Scope, defaced 20260927"'
  echo '  - name: long'
  echo "    note: $LONG"
  echo '  - name: block'
  echo '    note: |'
  echo '      v1 shipped'
  echo '      v2 in progress'
  echo '  - name: pr'
  echo "    note: 'PR #1234 stays DRAFT until QA'"
  echo '  - name: merge'
  echo '    note: Not yet merged to main'
  echo '  - name: sha'
  echo '    note: reverted in 9a9110c'
} > "$REPO/ai/features/index.yaml"
mkdir -p "$REPO/ai/features/parent"
printf 'sub-features:\n  - name: child\n    note: landed at 672f470e\n' > "$REPO/ai/features/parent/index.yaml"

run_doctor features
expect_exit 0 "note findings are warnings and never fail the run"
expect_no_line 'index.yaml:4' "a short, current-state note is quiet (no word or date read as a SHA)"
expect_line 'WARN +note-over-cap: ai/features/index.yaml:6' "a note over 150 chars is a warning"
expect_line 'WARN +note-over-cap: ai/features/index.yaml:8.*multi-line' "a block-scalar note is over the one-line cap"
expect_line 'WARN +note-volatile: ai/features/index.yaml:12.*PR/issue state' "a PR draft state is volatile"
expect_line 'WARN +note-volatile: ai/features/index.yaml:14.*merge state' "a not-yet-merged claim is volatile"
expect_line 'WARN +note-volatile: ai/features/index.yaml:16.*commit SHA' "a short SHA is volatile"
expect_line 'WARN +note-volatile: ai/features/parent/index.yaml:3' "sub-feature manifests are checked too"

run_doctor --quiet wiring schema
expect_no_line 'note-' "the blocking stop-hook groups exclude note checks"

# A near-miss key escapes every check above: it is not note:, so neither the
# cap nor the volatility pattern ever reads it (#180).
{
  echo 'features:'
  echo '  - name: a'
  echo "    notes: \"$LONG PR #12 abc1234def\""
  echo '  - name: b'
  echo "    Note: short"
  echo '  - name: c'
  echo "    note: $LONG"
} > "$REPO/ai/features/index.yaml"

run_doctor features
expect_exit 0 "an unknown manifest key is a warning"
expect_line 'WARN +manifest-unknown-key: ai/features/index.yaml:3: notes:' "a notes: key is reported, not skipped"
expect_line 'WARN +manifest-unknown-key: ai/features/index.yaml:5: Note:' "a capitalised Note: key is reported"
expect_line 'WARN +note-over-cap: ai/features/index.yaml:7' "a real note: beside them is still capped"
expect_no_line 'manifest-unknown-key: ai/features/index.yaml:7' "note: itself is not an unknown key"

# Prose inside a block scalar or a nested mapping is value text, not an entry
# key: reporting it would have the fix rename part of the description.
{
  echo 'features:'
  echo '  - name: a'
  echo '    description: >'
  echo '      Exports the ledger.'
  echo ''
  echo '      Note: legacy path kept for exports'
  echo '    meta:'
  echo '      Notes: nested, not an entry key'
  echo '    notes: entry key after the block'
} > "$REPO/ai/features/index.yaml"

run_doctor features
expect_no_line 'manifest-unknown-key: ai/features/index.yaml:6' "a Note: line inside a block scalar is not a key"
expect_no_line 'manifest-unknown-key: ai/features/index.yaml:8' "a Notes: key in a nested mapping is not an entry key"
expect_line 'WARN +manifest-unknown-key: ai/features/index.yaml:9: notes:' "an entry key after the block scalar is still reported"

# --- pass 3: severity depends on whether an update is pending ----------------

build_fixture
printf '\n# hand edit\n' >> "$REPO/.claude/rules/paths.md"
set_json .myspec.json 'd.frameworkVersion = "0.0.1"'

run_doctor install
expect_exit 0 "drift while an update is pending does not fail the run"
expect_line 'WARN +framework-drift: .claude/rules/paths.md' "drift while an update is pending is a warning"
expect_line 'plugin ships v' "the warning names the version skew as the reason"
expect_no_line 'ERROR framework-drift' "drift while an update is pending is not an error"

# --- pass 3b: a manifest entry the framework renamed -------------------------
#
# Until a project runs update it holds the old filename. Reporting the new one
# as missing would be true, useless, and would fire on every project the day
# the rename ships — so the doctor names the migration instead, as a warning.

build_fixture
mv "$REPO/ai/anti-patterns.md" "$REPO/ai/memory-index.md"
# build_fixture writes no frameworkFiles block, so seed it: without this the
# whole expression threw and the setup silently did nothing.
set_json .myspec.json 'd.frameworkFiles = d.frameworkFiles || {}; d.frameworkFiles["memory-index.md"] = d.frameworkFiles["anti-patterns.md"] || {}; delete d.frameworkFiles["anti-patterns.md"]'

run_doctor install
expect_exit 0 "an unmigrated rename does not fail the run"
expect_line 'WARN +framework-renamed: ai/memory-index.md' "the old filename is reported as a pending rename"
expect_line 'run: /myspec:update' "the rename finding carries the migration command"
expect_no_line 'ERROR framework-missing: ai/anti-patterns.md' "the new name is not also reported as missing"

# Both names on disk is the hand-rolled workaround colliding with the
# framework rename. Neither update nor the doctor guesses which one wins.
cp "$REPO/ai/memory-index.md" "$REPO/ai/anti-patterns.md"

run_doctor install
expect_line 'WARN +framework-renamed: ai/memory-index.md' "both names present is reported"
expect_line 'both exist' "the both-present finding says so"
expect_exit 0 "both names present does not fail the run"

# --- pass 3b-ii: the renamed file has no framework markers (#127) ------------
#
# A project that replaced memory-index.md with a redirect stub holds a
# marker-less old file. update moves it, then asks how to seed the framework
# region (replace / prepend / pin) instead of stopping. The doctor must not
# promise a project section it cannot find, and once the move is done the
# rename must be settled whichever answer the user gave.

STUB='# Moved

The anti-pattern index now lives in anti-patterns.md.
'

build_fixture
rm "$REPO/ai/anti-patterns.md"
printf '%s' "$STUB" > "$REPO/ai/memory-index.md"

run_doctor install
expect_line 'WARN +framework-renamed: ai/memory-index.md: .*no framework markers' "a marker-less old file is named as such"
expect_line 'run: /myspec:update' "the marker-less rename still points at update"
expect_no_line 'carries the project section across' "a marker-less old file is not promised a project-section carry-over"
expect_exit 0 "a pending marker-less rename does not fail the run"

# Both names present and the old one is the marker-less stub: there is no
# project section to merge, so the fix is deleting the stub.
# shellcheck disable=SC2016 # literal text, not an expansion
sed 's/\${aiDir}/ai/g' "$PLUGIN/framework-files/anti-patterns.md" > "$REPO/ai/anti-patterns.md"

run_doctor install
expect_line 'WARN +framework-renamed: ai/memory-index.md and ai/anti-patterns.md both exist' "stub beside the new file is reported"
expect_line 'fix: .*ai/memory-index.md has no framework markers' "the both-exist fix names the marker-less stub"

# The move done, the stub is now the new file and still has no markers. The
# finding is marker-missing, not the rename, and update is the fix.
rm "$REPO/ai/anti-patterns.md"
mv "$REPO/ai/memory-index.md" "$REPO/ai/anti-patterns.md"

run_doctor install
expect_no_line 'framework-renamed' "a completed move ends the rename finding"
expect_line 'ERROR marker-missing: ai/anti-patterns.md' "the moved marker-less file is marker-missing"
expect_line 'run: /myspec:update' "marker-missing points at update, which now offers the choices"

# Answer "prepend": plugin framework-owned region above the stub. Clean.
# shellcheck disable=SC2016 # literal text, not an expansion
node -e '
const fs=require("fs");
const src=fs.readFileSync(process.argv[1],"utf8").split("${aiDir}").join("ai");
const end="<!-- myspec:framework-end -->";
const region=src.slice(0, src.indexOf(end)+end.length);
fs.writeFileSync(process.argv[2], region+"\n\n"+fs.readFileSync(process.argv[2],"utf8"));
' "$PLUGIN/framework-files/anti-patterns.md" "$REPO/ai/anti-patterns.md"

run_doctor install
expect_no_line 'marker-missing' "prepending the framework region resolves marker-missing"
expect_no_line 'framework-renamed' "prepending leaves no rename finding"
expect_no_line 'framework-drift: ai/anti-patterns.md' "the prepended region matches the plugin copy"

# Answer "pin": the stub stays as it is, pinned under the new key. Clean.
rm "$REPO/ai/anti-patterns.md"
printf '%s' "$STUB" > "$REPO/ai/anti-patterns.md"
set_json .myspec.json 'd.frameworkFiles = { "anti-patterns.md": { pinned: "redirect stub, kept by choice" } }'

run_doctor install
expect_no_line 'marker-missing' "a pinned marker-less file is not marker-missing"
expect_no_line 'framework-renamed' "a pinned moved file leaves no rename finding"

# --- pass 3c: a file the framework retired ----------------------------------
#
# The manifest's removed block is how a deletion travels; the real manifest
# retires nothing yet, so a fake plugin root carries one entry. Sources are
# absent there on purpose: compare() skips a key it cannot read, so only the
# removed check speaks.

FAKE="$ROOT/plugin-removed"
mkdir -p "$FAKE/framework-files"
# shellcheck disable=SC2016 # literal text, not an expansion
node -e '
const fs=require("fs");
const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
delete m.files["templates/example-usage.md"];
m.removed={"templates/example-usage.md":{dest:"${aiDir}/.templates/example-usage.md",since:"2.0.0"}};
fs.writeFileSync(process.argv[2],JSON.stringify(m,null,2)+"\n");
' "$PLUGIN/framework-files/manifest.json" "$FAKE/framework-files/manifest.json"

build_fixture
mkdir -p "$REPO/ai/.templates" && printf '# stale\n' > "$REPO/ai/.templates/example-usage.md"
OUTPUT=$(node "$SCRIPT" --root "$REPO" --plugin-root "$FAKE" install 2>&1); STATUS=$?
expect_exit 0 "a retired file still on disk does not fail the run"
expect_line 'WARN +framework-removed: ai/.templates/example-usage.md' "a retired file still on disk is reported"
expect_line 'in v2.0.0' "the finding names the version that retired it"
expect_line 'run: /myspec:update' "the finding carries the deletion command"

set_json .myspec.json 'd.frameworkFiles = {"templates/example-usage.md": {pinned: "kept on purpose"}}'
OUTPUT=$(node "$SCRIPT" --root "$REPO" --plugin-root "$FAKE" install 2>&1); STATUS=$?
expect_no_line 'framework-removed' "a pinned retired file is a deliberate keep and is not reported"

# --- pass 3d: the migrations list is the schema marker ----------------------

build_fixture
set_json .myspec.json 'delete d.migrations'
run_doctor schema
expect_line 'WARN +myspec-schema-stale: .myspec.json has no migrations list' "a missing migrations list means the 2.0 migrations have not run"

# --- pass 2b: both ${aiDir} spellings of a rule are a correct install ----------
# init and update disagree about which of them substitutes the rules.
build_fixture
cp "$PLUGIN/framework-files/rules/paths.md" "$REPO/.claude/rules/paths.md"
run_doctor install
expect_no_line 'framework-drift: .claude/rules/paths.md' "a rule holding the literal placeholder is not drift"

# --- pass 3a: retired hook and lib copies (#262) --------------------------------
# A 2.x install left copies of the hooks and lib under .claude/. The plugin
# runs its own since 3.0, so a copy is reported once, as hook-copy-retired,
# whether or not it is pinned, hand-patched, broken or wired: update moves it
# to .claude/state/retired-3.0/ rather than deleting it. The install group
# does not report it a second time, and the project-hook checks do not read
# it as a project hook.

build_fixture
mkdir -p "$REPO/.claude/hooks" "$REPO/.claude/lib/stop-gate"
cp "$PLUGIN/hooks/verify-before-stop.sh" "$REPO/.claude/hooks/verify-before-stop.sh"
printf '#!/usr/bin/env bash\nif [ 1 =\n' > "$REPO/.claude/hooks/mark-code-changed.sh"
cp "$PLUGIN/lib/hook-core.sh" "$REPO/.claude/lib/hook-core.sh"
printf 'if [ 1 =\n' > "$REPO/.claude/lib/branch-cleanup.sh"
cp "$PLUGIN/lib/stop-gate/run.sh" "$REPO/.claude/lib/stop-gate/run.sh"
printf '#!/bin/sh\nexit 0\n' > "$REPO/.claude/hooks/own.sh"
chmod 755 "$REPO/.claude/hooks/"*.sh
set_json .myspec.json 'd.frameworkFiles = {"hooks/verify-before-stop.sh": {pinned: "local fork"}}'
run_doctor

expect_exit 0 "retired copies alone do not fail the run"
expect_line 'WARN +hook-copy-retired: .claude/hooks/verify-before-stop.sh: a copy of the plugin.s hook' "a hook copy is reported, pinned or not"
expect_line 'WARN +hook-copy-retired: .claude/hooks/mark-code-changed.sh' "a hand-written hook copy is reported"
expect_line 'WARN +hook-copy-retired: .claude/lib/hook-core.sh: a copy of the plugin.s lib helper' "a lib copy is reported"
expect_line 'WARN +hook-copy-retired: .claude/lib/branch-cleanup.sh' "a lib copy that no longer matches is reported the same way"
expect_line 'WARN +hook-copy-retired: .claude/lib/stop-gate/run.sh' "a lib copy in a subdirectory is reported"
expect_line 'retired-3.0' "the finding says where update moves the copy"
expect_line 'run: /myspec:update' "the finding carries the move command"
expect_no_line 'framework-removed: .claude/' "the install group does not report the copies a second time"
expect_no_line 'hook-syntax: .claude/hooks/mark-code-changed.sh' "a broken retired hook copy is not parsed: nothing runs it"
expect_no_line 'hook-syntax: .claude/lib/branch-cleanup.sh' "a broken retired lib copy is not parsed"
expect_no_line 'hook-unregistered: .claude/hooks/verify-before-stop.sh' "a retired hook copy is not an unregistered project hook"
expect_line 'WARN +hook-unregistered: .claude/hooks/own.sh' "a project hook beside the copies is still checked"
expect_no_line 'hook-copy-retired: .claude/hooks/own.sh' "a project hook is not a retired copy"

# A 2.0 retirement under .claude/hooks/ (guard-git-branch.sh, since 2.0.0) is a
# plain deletion update already performs, not a plugin-run copy: it keeps its
# framework-removed finding and is never reported as hook-copy-retired, nor
# routed to a move the migration would then compare with a file the plugin
# does not ship.
build_fixture
mkdir -p "$REPO/.claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$REPO/.claude/hooks/guard-git-branch.sh"
chmod 755 "$REPO/.claude/hooks/guard-git-branch.sh"
run_doctor
expect_line 'WARN +framework-removed: .claude/hooks/guard-git-branch.sh: retired by the framework in v2.0.0' "a 2.0-retired hook copy keeps its framework-removed finding"
expect_no_line 'hook-copy-retired: .claude/hooks/guard-git-branch.sh' "a 2.0-retired hook is not a plugin-run copy"

# --- pass 3b: a pinned framework rule over budget ------------------------------
# The 2.0 rules diet shrank the always-loaded rules, but two consumer repos pin
# workflow.md with the reason "trimmed for always-loaded context budget". update
# never touches a pin, so the stale fork keeps costing tokens the pin was taken
# to save — and the plugin-owned note ("update overwrites local edits, report
# upstream") is the opposite of what that reader should do.

build_fixture
node -e '
const {readFileSync,writeFileSync}=require("fs");
const {join}=require("path");
const root=process.argv[1];
const cfg=JSON.parse(readFileSync(join(root,".myspec.json"),"utf8"));
cfg.frameworkFiles={"rules/workflow.md":{pinned:"trimmed for always-loaded context budget"}};
writeFileSync(join(root,".myspec.json"),JSON.stringify(cfg,null,2)+"\n");
const rule=join(root,".claude","rules","workflow.md");
writeFileSync(rule,readFileSync(rule,"utf8")+"\n"+("stale forked prose. ".repeat(500)));
' "$REPO"
run_doctor budget

expect_line 'WARN +over-budget-pinned: .claude/rules/workflow.md' "a pinned framework rule over budget is a warning, not a note"
expect_line 'pinned in .myspec.json' "the finding says the file is pinned"
expect_line 'trimmed for always-loaded context budget' "the finding quotes the pin reason"
expect_line 'update skips it' "the finding says update will not fix this"
expect_line 'plugin copy is now smaller' "the finding says the pin now costs more than it saves"
expect_no_line 'report upstream' "a pinned file is not reported as a plugin-owned issue"
expect_no_line 'WARN +over-budget: .claude/rules/workflow.md' "a managed file is not also reported as project-owned"

# --- pass 3e: diff-scoped verification checks --------------------------------
#
# A repo that is already red on its default branch configures a check as a
# diffCommand instead of a whole-repo command. That counts as configured, but
# only if it actually reads the base ref the stop hook exports — otherwise it
# quietly replaces the gate with something narrower.

build_fixture
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/verification.json 'd.checks[0].command = ""; d.checks[0].diffCommand = "files=$(git diff --name-only \"$MYSPEC_BASE_REF\"); [ -z \"$files\" ] || npx eslint $files"; d.checks[1].command = "tsc --noEmit"; d.checks[2].command = "npm test"'

run_doctor schema
expect_exit 0 "a diff-scoped check does not fail the run"
expect_no_line 'verification-empty' "a check configured only as a diffCommand counts as configured"
expect_no_line 'verification-diff-unscoped' "a diffCommand that reads the base ref is not flagged"

set_json .claude/verification.json 'd.checks[0].diffCommand = "npx eslint src/"'

run_doctor schema
expect_line 'WARN +verification-diff-unscoped: .claude/verification.json' "a diffCommand that ignores the base ref is a warning"
expect_line 'MYSPEC_BASE_REF' "the finding names the ref the command should scope to"

# The gate exports $MYSPEC_BASE_REF, so a diffCommand that calls a script which
# reads it is scoped even though the command string never names it (#180).
mkdir -p "$REPO/scripts"
# shellcheck disable=SC2016 # literal text, not an expansion
printf '#!/bin/sh\ngit diff --name-only "$MYSPEC_BASE_REF" | xargs lint\n' > "$REPO/scripts/lint-changed.sh"
printf '#!/bin/sh\nlint .\n' > "$REPO/scripts/lint-all.sh"
for cmd in 'bash scripts/lint-changed.sh' './scripts/lint-changed.sh --fix' 'sh "scripts/lint-changed.sh"'; do
  CMD="$cmd" set_json .claude/verification.json "d.checks[0].diffCommand = process.env.CMD"
  run_doctor schema
  expect_no_line 'verification-diff-unscoped' "a diffCommand whose script reads the base ref is not flagged: $cmd"
done

# $CLAUDE_PROJECT_DIR is the repo root, the portable form for a hook script,
# so the script behind it is read like a relative one, in every spelling.
# shellcheck disable=SC2016 # literal text, not an expansion
for cmd in '"$CLAUDE_PROJECT_DIR"/scripts/lint-changed.sh' '${CLAUDE_PROJECT_DIR}/scripts/lint-changed.sh' '"${CLAUDE_PROJECT_DIR}/scripts/lint-changed.sh"' 'bash $CLAUDE_PROJECT_DIR/scripts/lint-changed.sh'; do
  CMD="$cmd" set_json .claude/verification.json "d.checks[0].diffCommand = process.env.CMD"
  run_doctor schema
  expect_no_line 'verification-diff-unscoped' "a project-dir diffCommand whose script reads the base ref is not flagged: $cmd"
done

# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/verification.json 'd.checks[0].diffCommand = "\"$CLAUDE_PROJECT_DIR\"/scripts/lint-all.sh"'
run_doctor schema
expect_line 'WARN +verification-diff-unscoped' "a project-dir diffCommand whose script ignores the base ref is still flagged"

set_json .claude/verification.json 'd.checks[0].diffCommand = "bash scripts/lint-all.sh"'
run_doctor schema
expect_line 'WARN +verification-diff-unscoped' "a diffCommand whose script ignores the base ref is still flagged"

set_json .claude/verification.json 'd.checks[0].diffCommand = "bash scripts/missing.sh"'
run_doctor verification-diff-unscoped
expect_line 'WARN +verification-diff-unscoped' "a diffCommand naming a missing script is flagged, and the check id is selectable"

# --- pass 3f: dead refs from a linked worktree (#228) -------------------------
#
# A linked worktree lives under the main checkout's .claude/worktrees, and that
# directory never travels with a branch. Run from the worktree, a reference to
# it does not resolve there, though it is no dead reference.

build_fixture
# shellcheck disable=SC2016 # literal backticks, not a command substitution
printf '# Fixture\n\nWorktrees live in `.claude/worktrees`; rules in `.claude/rules/workflow.md`; see `docs/gone.md`.\n' > "$REPO/CLAUDE.md"
mkdir -p "$REPO/docs" "$REPO/.claude/worktrees"
echo gone > "$REPO/docs/gone.md"
echo keep > "$REPO/docs/keep.md"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm fixture
git -C "$REPO" worktree add -q -b wt1 "$REPO/.claude/worktrees/wt1"
WT="$REPO/.claude/worktrees/wt1"
git -C "$WT" rm -q docs/gone.md

run_doctor refs
expect_no_line 'dead-path-ref' "the main checkout has no dead refs"

OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" refs 2>&1); STATUS=$?
expect_no_line 'dead-path-ref: CLAUDE.md: references .claude/worktrees' "a linked worktree does not report the main checkout's .claude/worktrees as dead"
expect_line 'WARN +dead-path-ref: CLAUDE.md: references docs/gone.md' "a tracked file this branch removed is still a dead ref from the worktree"

# --- pass 3g: links the provision record does not list (#239) ----------------
#
# The Stop hook compares only what worktree-provision.sh recorded in
# .claude/state/provision.json. A link out of the worktree it did not record,
# and a recorded lockfile that changed, are the doctor's to report.

build_fixture
mkdir -p "$REPO/node_modules/dep" "$REPO/apps/web/node_modules/dep" "$REPO/vendor/dep" "$ROOT/outside"
printf 'node_modules\napps/web/node_modules\nvendor\n' > "$REPO/.gitignore"
printf 'v1\n' > "$REPO/composer.lock"
printf '{}\n' > "$REPO/apps/web/package.json"
ln -s "$ROOT/outside" "$REPO/shared"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm fixture
git -C "$REPO" worktree add -q -b wt2 "$REPO/.claude/worktrees/wt2"
WT="$REPO/.claude/worktrees/wt2"
ln -s "$REPO/node_modules" "$WT/node_modules"
ln -s "$REPO/apps/web/node_modules" "$WT/apps/web/node_modules"
ln -s "$REPO/vendor" "$WT/vendor"
mkdir -p "$WT/inner" "$WT/.claude/state"
ln -s "$WT/inner" "$WT/inside"
jq -n --arg s "$REPO" --arg t "$REPO/vendor" --arg h "$(shasum -a 256 < "$REPO/composer.lock" 2>/dev/null | cut -d' ' -f1 || sha256sum < "$REPO/composer.lock" | cut -d' ' -f1)" \
  '{source: $s, links: [{path: "vendor", target: $t, lockfiles: {"composer.lock": $h}}]}' > "$WT/.claude/state/provision.json"

OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +link-unrecorded: node_modules links out of this worktree \(to $REPO/node_modules\) and was not recorded by provision; checks here may describe the main checkout" "worktree: a hand-made top-level link out of the worktree is reported"
expect_line "WARN +link-unrecorded: apps/web/node_modules links out of this worktree" "worktree: a hand-made link one level down (a workspace package) is reported"
expect_no_line "link-unrecorded: vendor" "worktree: a link the record lists is not reported"
expect_no_line "link-unrecorded: inside" "worktree: a link that stays inside the worktree is not reported"
expect_no_line "link-unrecorded: shared" "worktree: a link git tracks is not reported"
expect_no_line "provision-stale" "worktree: a recorded lockfile that still matches is not reported"
expect_exit 0 "worktree: the findings are warnings"

# One git-dir probe serves the refs and worktree groups, and the tracked-link
# test reuses the first ls-files listing (#256 review).
GITLOG="$ROOT/git.log"
mkdir -p "$ROOT/gitshim"
# shellcheck disable=SC2016 # expanded by the shim when it runs
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec %s "$@"\n' "$GITLOG" "$(command -v git)" > "$ROOT/gitshim/git"
chmod +x "$ROOT/gitshim/git"
cp "$WT/CLAUDE.md" "$ROOT/claude.md.bak"
# shellcheck disable=SC2016 # literal backticks
printf 'See `.claude/rules/gone-rule.md`.\n' >> "$WT/CLAUDE.md"
: > "$GITLOG"
OUTPUT=$(PATH="$ROOT/gitshim:$PATH" node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" refs worktree 2>&1); STATUS=$?
expect_line 'dead-path-ref: CLAUDE.md: references .claude/rules/gone-rule.md' "probe: the dead ref that needs the main checkout is found"
eq_count() { local n; n=$(grep -cxF -- "$1" "$GITLOG"); [ "$n" -eq "$2" ] && ok || fail "$3 (ran $n times)"; }
eq_count "rev-parse --git-dir --git-common-dir" 1 "probe: git rev-parse --git-dir --git-common-dir runs once"
[ "$(grep -c '^ls-files -z --' "$GITLOG")" -eq 0 ] && ok || fail "probe: no second ls-files for the link candidates"
cp "$ROOT/claude.md.bak" "$WT/CLAUDE.md"

printf 'v2\n' > "$WT/composer.lock"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-stale: vendor was provisioned from composer.lock, which has changed since \(in this worktree\)" "worktree: a recorded lockfile changed in the worktree is reported"
git -C "$WT" checkout -q -- composer.lock
printf 'v3\n' > "$REPO/composer.lock"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-stale: vendor was provisioned from composer.lock, which has changed since \(in $REPO\)" "worktree: a recorded lockfile changed in the source checkout is reported"
# A lockfile pattern recorded absent (null) that now matches a file is
# reported, as the Stop hook blocks on it (#256 review).
printf 'v1\n' > "$REPO/composer.lock"
jq '.links[0].lockfiles += {"sub/composer.lock": null, "compo*.lock": null}' "$WT/.claude/state/provision.json" > "$ROOT/prov.json" \
  && mv "$ROOT/prov.json" "$WT/.claude/state/provision.json"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_no_line "provision-stale" "worktree: recorded-absent lockfiles still absent, and a glob matching only hashed files, are not reported"
mkdir -p "$WT/sub" && printf 'x\n' > "$WT/sub/composer.lock"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-stale: vendor was provisioned while sub/composer.lock did not exist, and it has appeared since \(in this worktree\)" "worktree: a recorded-absent lockfile that appears is reported"
rm -rf "$WT/sub"
# A [...] class is a shell class, as provision expands it (#257 review).
jq '.links[0].lockfiles += {"packages/[ab]/package-lock.json": null, "packages/[!ab]x/package-lock.json": null}' "$WT/.claude/state/provision.json" > "$ROOT/prov.json" \
  && mv "$ROOT/prov.json" "$WT/.claude/state/provision.json"
mkdir -p "$WT/packages/c" "$WT/packages/ax" "$WT/packages/[ab]"
printf 'x\n' > "$WT/packages/c/package-lock.json"
printf 'x\n' > "$WT/packages/ax/package-lock.json"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_no_line "provision-stale" "worktree: a lockfile outside a [...] class is not a match"
mkdir -p "$WT/packages/b" && printf 'x\n' > "$WT/packages/b/package-lock.json"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-stale: vendor was provisioned while packages/b/package-lock.json did not exist" "worktree: packages/[ab]/package-lock.json matches packages/b as the shell does"
rm -rf "$WT/packages/b"
printf 'x\n' > "$WT/packages/[ab]/package-lock.json"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_no_line "provision-stale" "worktree: [ab] is a class, not the literal directory [ab]"
mkdir -p "$WT/packages/cx" && printf 'x\n' > "$WT/packages/cx/package-lock.json"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-stale: vendor was provisioned while packages/cx/package-lock.json did not exist" "worktree: [!ab] negates the class"
rm -rf "$WT/packages"

# A recorded link that dangles or moved, and a record that cannot be read,
# are named as the Stop hook blocks on them (#256 review).
cp "$WT/.claude/state/provision.json" "$ROOT/prov.bak"
rm "$WT/vendor" && ln -s "$ROOT/nowhere/vendor" "$WT/vendor"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-link-dangling: vendor was linked by provision but its target no longer exists" "worktree: a dangling recorded link is reported"
mkdir -p "$ROOT/elsewhere/vendor"
rm "$WT/vendor" && ln -s "$ROOT/elsewhere/vendor" "$WT/vendor"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-link-moved: vendor was linked by provision to $REPO/vendor and now resolves to $ROOT/elsewhere/vendor" "worktree: a recorded link that moved is reported"
rm "$WT/vendor" && ln -s "$REPO/vendor" "$WT/vendor"
printf '{"source":' > "$WT/.claude/state/provision.json"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_line "WARN +provision-record-unreadable: \.claude/state/provision\.json cannot be read" "worktree: a truncated record is reported as unreadable"
expect_no_line "link-unrecorded" "worktree: a truncated record is not read as no record"
cp "$ROOT/prov.bak" "$WT/.claude/state/provision.json"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_no_line "provision-link|provision-record" "worktree: a recorded link back on its target is not reported"

# A recorded link whose tree starts loading the source checkout's own code
# after provisioning: doctor runs provision's tree_loads_checkout checks
# (#256 review, the plan's doctor backstop).
loads_main() {  # loads_main <description> -> expects the finding, then cleans the tree
  OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
  expect_line "WARN +provision-link-loads-main: vendor links to $REPO/vendor, which now loads the source checkout's own code \($2" "worktree: $1"
  expect_line "move vendor to isolation\.provision\.copy" "worktree: $1, with the fix"
  rm -rf "$REPO/vendor/composer" "$REPO/vendor/lib" "$REPO/vendor/@acme" "$REPO/packages"
}
ln -s "$REPO/vendor/dep" "$REPO/vendor/inner-link"
OUTPUT=$(node "$SCRIPT" --root "$WT" --plugin-root "$PLUGIN" worktree 2>&1); STATUS=$?
expect_no_line "provision-link-loads-main" "worktree: a link inside the tree loads nothing"
rm "$REPO/vendor/inner-link"
mkdir -p "$REPO/vendor/composer"
# shellcheck disable=SC2016 # the literal $baseDir text Composer writes
printf '<?php\nreturn array(\x27App\\\\\x27 => array($baseDir . \x27/src\x27));\n' > "$REPO/vendor/composer/autoload_psr4.php"
# shellcheck disable=SC2016 # a literal $baseDir in the expected line
loads_main "a Composer autoload against \$baseDir" 'composer/autoload_psr4\.php loads the root package from \$baseDir'
mkdir -p "$REPO/vendor/lib/python3.12/site-packages/app-1.0.dist-info" "$REPO/packages/app"
printf '{"url":"file://%s/packages/app","dir_info":{"editable":true}}\n' "$REPO" > "$REPO/vendor/lib/python3.12/site-packages/app-1.0.dist-info/direct_url.json"
loads_main "an editable install of the source checkout" 'app-1\.0\.dist-info is an editable install of '"$REPO"'/packages/app'
mkdir -p "$REPO/vendor/@acme" "$REPO/packages/ui"
ln -s ../../packages/ui "$REPO/vendor/@acme/ui"
loads_main "a workspace link two levels down" '@acme/ui links to '"$REPO"'/packages/ui'

ln -s "$ROOT/outside" "$REPO/elsewhere"
run_doctor worktree
expect_no_line "link-unrecorded" "worktree: the main checkout is never checked"

# --- pass 5: project settings against the schema (#233) ------------------------
# The doctor names no setting itself: every key, type, format and reference
# comes from lib/myspec-config.schema.json, so these fixtures exercise the
# schema's own entries.

# run_doctor_env <env assignments...> -- <args...>: run with only these
# variables, so a MYSPEC_* in the caller's environment cannot leak in.
run_doctor_env() {
  local vars=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  OUTPUT=$(env -i PATH="$PATH" HOME="$HOME" ${vars[@]+"${vars[@]}"} node "$SCRIPT" --root "$REPO" --plugin-root "$PLUGIN" "$@" 2>&1)
  STATUS=$?
}

build_fixture
run_doctor_env -- schema
expect_exit 0 "settings: a fresh install passes the schema surface"
expect_no_line 'setting-' "settings: a fresh install has no unknown key, wrong type, bad glob or dangling ref"

run_doctor_env -- settings
expect_line '^SET +aiDir = "ai" \(\.myspec\.json\)$' "settings: a non-default aiDir is listed with its file"
expect_line '^SET +checks\[0\]\.required = true \(\.claude/verification\.json\)$' "settings: a check's fields are listed item by item"
expect_no_line 'frameworkVersion|migrations|checks\[0\]\.name|checks\[0\]\.description|^SET +notes' "settings: bookkeeping and free-text keys are not listed"
expect_no_line 'loosens a gate' "settings: a fresh install loosens nothing"

# Defaults only: nothing to list, and the listing says so.
DEFAULTS="$ROOT/defaults"
mkdir -p "$DEFAULTS/.ai"
printf '{"aiDir": ".ai", "frameworkVersion": "0.0.0"}\n' > "$DEFAULTS/.myspec.json"
OUTPUT=$(env -i PATH="$PATH" HOME="$HOME" node "$SCRIPT" --root "$DEFAULTS" --plugin-root "$PLUGIN" settings 2>&1); STATUS=$?
expect_line '^SET +every setting is at its default$' "settings: defaults only says every setting is at its default"
expect_no_line '^SET +[a-zA-Z]+.* = ' "settings: defaults only lists no key"

# A project file plus a session override.
set_json .myspec.json 'd.isolation={worktreeRoot:"wt", allowLinkedModules:false}; d.hooks={markCodeChanged:{ignorePaths:["gen/**"]}};'
set_json .claude/verification.json 'd.containers={api:{mountSource:".", mountTarget:"/srv/app"}}; d.checks[0].paths=["api/**"]; d.checks[0].runIn="api";'
run_doctor_env MYSPEC_ALLOW_LINKED_MODULES=1 MYSPEC_CHECK_CAP_SECONDS=30 MYSPEC_GATE_BUDGET_SECONDS=120 -- settings
expect_line '^SET +isolation\.worktreeRoot = "wt" \(\.myspec\.json\)$' "settings: a project value is listed with its file and is not marked"
expect_line '^SET +isolation\.allowLinkedModules = true \(session: MYSPEC_ALLOW_LINKED_MODULES=1\) — loosens a gate$' "settings: a session override wins over the project file, names its variable, and is marked"
expect_line '^SET +hooks\.markCodeChanged\.ignorePaths = \["gen/\*\*"\] \(\.myspec\.json\) — loosens a gate$' "settings: ignorePaths is marked as loosening"
expect_line '^SET +checks\[0\]\.paths = \["api/\*\*"\] \(\.claude/verification\.json\) — loosens a gate$' "settings: a check's paths is marked as loosening"
expect_line '^SET +checks\[0\]\.runIn = "api" \(\.claude/verification\.json\)$' "settings: runIn is listed, unmarked"
expect_line '^SET +MYSPEC_CHECK_CAP_SECONDS = "30" \(session\)$' "settings: a standalone session variable is listed"
expect_line '^SET +MYSPEC_GATE_BUDGET_SECONDS = "120" \(session\)$' "settings: a lowered gate budget is listed"
expect_no_line '^SET +every setting' "settings: a project with settings does not claim defaults"

run_doctor_env MYSPEC_ALLOW_LINKED_MODULES=1 -- --json settings
if printf '%s' "$OUTPUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8")); const s=r.settings.find((x)=>x.key==="hooks.markCodeChanged.ignorePaths"); process.exit(s && s.loosens===true && s.source===".myspec.json" ? 0 : 1)'; then ok; else fail "settings: --json carries key, source and loosens"; fi

run_doctor_env MYSPEC_ALLOW_LINKED_MODULES=1 -- --quiet
expect_no_line '^SET ' "settings: --quiet leaves the listing out (bootstrap's summary stays one line)"

run_doctor_env -- schema
expect_exit 0 "settings: valid settings pass the schema surface"
expect_no_line 'setting-' "settings: a defined container, usable globs and known keys raise nothing"

# One break per finding type.
build_fixture
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .myspec.json 'd["$schema"]="x"; d.isolation={worktreeRot:"wt", allowLinkedModules:"yes", provision:{install:[{run:"true", cwd:"nope"}, {run:"true", cwd:"."}, "make deps"]}}; d.ignorePaths=["gen/**"]; d.zzzUnrelated=1; d.hooks={markCodeChanged:{ignorePaths:["../out/**", "/abs/**", "ok/**"]}};'
set_json .claude/verification.json 'd.checks[0].pahts=["api/**"]; d.checks[0].required="true"; d.checks[1].runIn="api"; d.checks[2].paths=[""];'
run_doctor_env -- schema
expect_exit 1 "settings: a wrong type or a dangling reference is an error"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: isolation\.worktreeRot is not a myspec setting \(did you mean isolation\.worktreeRoot\?\)' "settings: a misspelled key gets its near-miss sibling"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: ignorePaths is not a myspec setting \(did you mean hooks\.markCodeChanged\.ignorePaths\?\)' "settings: a key at the wrong level points at where it belongs"
expect_line '^WARN +setting-unknown-key: \.claude/verification\.json: checks\[0\]\.pahts is not a myspec setting \(did you mean checks\[0\]\.paths\?\)' "settings: an unknown field on a check gets its near miss"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: zzzUnrelated is not a myspec setting; nothing reads it' "settings: an unknown key with no near miss is still reported"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_no_line 'setting-unknown-key: .*\$schema' "settings: a \$-prefixed JSON convention key is not reported"
expect_line '^ERROR setting-wrong-type: \.myspec\.json: isolation\.allowLinkedModules is ignored — expected boolean, got string; it uses the default' "settings: a wrong type is an error that says the default applies"
expect_line '^ERROR setting-wrong-type: \.claude/verification\.json: checks\[0\]\.required is string, expected boolean' "settings: a wrong type inside a check is an error"
expect_line '^ERROR setting-unknown-ref: \.claude/verification\.json: checks\[1\]\.runIn names "api", which containers in \.claude/verification\.json does not define' "settings: runIn naming an undefined container is an error"
expect_line '^WARN +setting-glob-unusable: \.myspec\.json: hooks\.markCodeChanged\.ignorePaths\[0\] is "\.\./out/\*\*".*\.\. segment' "settings: a glob that leaves the checkout is unusable"
expect_line '^WARN +setting-glob-unusable: \.myspec\.json: hooks\.markCodeChanged\.ignorePaths\[1\] is "/abs/\*\*".*absolute' "settings: an absolute glob is unusable"
expect_no_line 'ignorePaths\[2\]' "settings: a usable glob beside bad ones is not reported"
expect_line '^WARN +setting-glob-unusable: \.claude/verification\.json: checks\[2\]\.paths\[0\] is "".*empty' "settings: an empty check path glob is unusable"
expect_line '^WARN +setting-dir-missing: \.myspec\.json: isolation\.provision\.install\[0\]\.cwd is "nope"' "settings: an install step whose cwd does not exist is reported"
expect_no_line 'install\[1\]\.cwd|install\[2\]' "settings: an install step in an existing cwd, or a bare command, is not reported"

run_doctor_env -- --quiet wiring schema
expect_exit 1 "settings: the stop hook's groups see a wrong-type setting"

run_doctor_env -- setting-unknown-ref
expect_line 'setting-unknown-ref' "settings: a single settings check id is selectable"
expect_no_line 'setting-wrong-type|setting-unknown-key' "settings: selecting one check id hides the others"

# PR #246 review: an emptied list is listed whole; a top-level typo gets its
# near miss; a non-object settings file is one finding; a list setting of the
# wrong type is not also read as a glob.
build_fixture
set_json .myspec.json 'd.isolation={provision:{symlink:[], copy:[]}}; d.isolaton={}; d.feedbak={}; d.reuseAudit={enabled:false}; d.hooks={markCodeChanged:{ignorePaths:7}};'
set_json .claude/verification.json 'd.checks=[];'
run_doctor_env -- settings
expect_line '^SET +isolation\.provision\.symlink = \[\] \(\.myspec\.json\)$' "settings: an emptied symlink list is listed"
expect_line '^SET +isolation\.provision\.copy = \[\] \(\.myspec\.json\)$' "settings: an emptied copy list is listed"
expect_line '^SET +checks = \[\] \(\.claude/verification\.json\)$' "settings: an emptied checks list is listed"

run_doctor_env -- schema
expect_line '^WARN +setting-unknown-key: \.myspec\.json: isolaton is not a myspec setting \(did you mean isolation\?\)' "settings: a top-level typo gets its near miss"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: feedbak is not a myspec setting \(did you mean feedback\?\)' "settings: a second top-level typo gets its near miss"
# The 2.x reuseAudit switch is no setting since 3.0 (#263): the key is
# reported as unknown, and never listed as a gate turned off.
expect_line '^WARN +setting-unknown-key: \.myspec\.json: reuseAudit is not a myspec setting' "settings: the retired reuseAudit key is reported as unknown"
expect_no_line 'reuseAudit\.enabled' "settings: the retired reuseAudit.enabled is not a catalogued setting"
GLOB_LINES=$(printf '%s\n' "$OUTPUT" | grep -c 'ignorePaths')
if [ "$GLOB_LINES" -eq 1 ]; then ok; else fail "settings: a non-array ignorePaths is one finding, got $GLOB_LINES"; fi
expect_line '^ERROR setting-wrong-type: \.myspec\.json: hooks\.markCodeChanged\.ignorePaths is ignored — expected array, got number' "settings: a non-array ignorePaths is a wrong type"
expect_no_line 'setting-glob-unusable' "settings: a non-array ignorePaths is not also an unusable glob"

printf '[]\n' > "$REPO/.myspec.json"
printf '[]\n' > "$REPO/.claude/verification.json"
run_doctor_env -- schema
for f in '\.myspec\.json' '\.claude/verification\.json'; do
  N=$(printf '%s\n' "$OUTPUT" | grep -cE "^ERROR setting-wrong-type: $f: $f is not a JSON object")
  if [ "$N" -eq 1 ]; then ok; else fail "settings: a non-object $f is one finding, got $N"; fi
done

# --- schema v2 (#265): the keys the blueprints write are settings ------------
# A lockin-shaped .myspec.json: the mockups block the setup mockup blueprint
# writes (blueprints/mockup.md, Post-generation) and a pin. Before v2 the
# doctor warned `mockups is not a myspec setting` on every mockup-enabled
# consumer. The keys v2 removed (project.description, codeReview) are reported
# as unknown until their migrations drop them.
build_fixture
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .myspec.json 'd.project={name:"lockin", description:"GeoGuessr Meta Guides Platform", techStack:"Vue 3"}; d.mockups={extension:".vue", commands:{verify:"pnpm --filter @lockin/mockups typecheck", preview:"pnpm dev:mockups", compileCheck:"curl -s \"$PREVIEW_URL/@fs{absPath}\"", audit:"pnpm mockups:audit"}, siblingRoots:["apps/web/src/components", "packages/uikit/src/components"]}; d.frameworkFiles={"rules/ideas.md":{pinned:"gated with paths", hash:"0".repeat(64), upstreamHash:"1".repeat(64)}}; d.orchestration={featureImplement:"workflow"}; d.probes={portSource:"$DEV_PORTS", scratchEnvScript:"scripts/scratch-env.sh"}; d.codeReview={verbosity:"standard"};'
run_doctor_env -- schema
expect_no_line 'setting-unknown-key: \.myspec\.json: mockups' "schema v2: the mockups block is a setting, not an unknown key"
expect_no_line 'setting-unknown-key: \.myspec\.json: (project\.name|project\.techStack|frameworkFiles|orchestration|probes)' "schema v2: project.name, techStack, a pin, orchestration and probes are settings"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: project\.description is not a myspec setting' "schema v2: project.description is unknown (dropped by 3.0.0-schema-v2)"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: codeReview is not a myspec setting' "schema v2: codeReview is unknown (dropped by 3.0.0-code-review)"
expect_no_line 'setting-wrong-type' "schema v2: a well-typed pin and mockups block raise no type error"
run_doctor_env -- settings
expect_line '^SET +mockups\.extension = "\.vue" \(\.myspec\.json\)$' "schema v2: a mockups key is listed as in force"
expect_line '^SET +orchestration\.featureImplement = "workflow" \(\.myspec\.json\)$' "schema v2: a non-default featureImplement is listed"
expect_line '^SET +probes\.portSource = ' "schema v2: probes.portSource is listed"
expect_no_line '^SET +(project|frameworkFiles\.)' "schema v2: project fields and the pin hashes are bookkeeping, not listed"

# A pin is typed through the `*` entry: a reason that is not a string, a hash
# of the wrong type, and a pin that is not an object are errors; a field no
# pin has is unknown and gets its near miss.
set_json .myspec.json 'd.frameworkFiles={"rules/ideas.md":{pinned:true, hash:7, hsah:"x"}, "pre-flight.md":"a reason"};'
run_doctor_env -- schema
expect_exit 1 "schema v2: a mistyped pin is an error"
expect_line '^ERROR setting-wrong-type: \.myspec\.json: frameworkFiles\.rules/ideas\.md\.pinned is boolean, expected string' "schema v2: a non-string pin reason is a wrong type"
expect_line '^ERROR setting-wrong-type: \.myspec\.json: frameworkFiles\.rules/ideas\.md\.hash is number, expected string' "schema v2: a non-string hash is a wrong type"
expect_line '^ERROR setting-wrong-type: \.myspec\.json: frameworkFiles\.pre-flight\.md is string, expected object' "schema v2: a pin that is not an object is a wrong type"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: frameworkFiles\.rules/ideas\.md\.hsah is not a myspec setting \(did you mean frameworkFiles\.rules/ideas\.md\.hash\?\)' "schema v2: an unknown pin field gets its near miss"

# --- container checks (#220, #221): what the stop gate no longer parses -------
# exec_checks <json array of [command, runIn or ""]> -> verification.json
# with one required check per pair, named C0, C1, ... and one container "app".
exec_checks() {
  set_json .claude/verification.json "d.containers={app:{mountSource:'.', mountTarget:'/srv/app'}}; d.checks=$1.map(([c, r], i) => Object.assign({name: 'C' + i, command: c, required: true}, r ? {runIn: r} : {}));"
}
build_fixture
# shellcheck disable=SC2016 # literal $MYSPEC_CHECK_WORKDIR in the commands
exec_checks '[
  ["docker compose exec app make lint", ""],
  ["docker compose -p x exec -w /srv/app app make lint", ""],
  ["docker compose exec app make lint", "app"],
  ["docker compose exec -Tw /srv/app/wt app make lint", "app"],
  ["docker exec -ew app make lint", "app"],
  ["docker exec --workdir=/srv/app app make lint", "app"],
  ["docker compose exec -w \"$MYSPEC_CHECK_WORKDIR\" app make lint", "app"],
  ["docker compose exec app sh -c \"cd $MYSPEC_CHECK_WORKDIR && make\"", "app"],
  ["docker compose exec -T app make -w lint", "app"],
  ["docker compose run --rm app make lint", ""],
  ["npm run lint", ""]
]'
run_doctor_env -- schema
expect_exit 0 "containers: the container findings are warnings, not errors"
expect_line '^WARN +verification-exec-no-runin: .*check C0 runs a container exec without runIn — in a linked worktree this check will be refused' "containers: an exec without runIn is warned about"
expect_line '^WARN +verification-exec-no-runin: .*check C1 ' "containers: a -w does not stand in for runIn"
expect_line 'declare runIn and a containers entry' "containers: the fix names runIn and containers"
# docs/ exists in the plugin repository, not in the project the doctor runs in:
# a fix pointing there sends the user to a file they do not have.
expect_no_line '(^|[^/[:alnum:]_.-])docs/' "containers: no finding points at a bare docs/ path"
# shellcheck disable=SC2016 # a literal $ in the pattern
# shellcheck disable=SC2016 # a literal $ in the pattern
expect_line '^WARN +verification-runin-no-workdir: .*check C2 has runIn but its container exec passes neither -w/--workdir nor \$MYSPEC_CHECK_WORKDIR' "containers: a runIn exec without the workdir is warned about"
expect_no_line 'check C3 ' "containers: a -Tw <dir> cluster sets the workdir"
expect_line '^WARN +verification-runin-no-workdir: .*check C4 ' "containers: -ew is -e w, not a workdir"
expect_no_line 'check C5 ' "containers: --workdir= sets the workdir"
expect_no_line 'check C6 ' "containers: -w \"\$MYSPEC_CHECK_WORKDIR\" is the workdir"
expect_no_line 'check C7 ' "containers: a command that names MYSPEC_CHECK_WORKDIR is trusted"
expect_line '^WARN +verification-runin-no-workdir: .*check C8 ' "containers: a -w after the service name belongs to the inner command"
expect_no_line 'check C9 |check C10 ' "containers: a compose run and a host command raise nothing"

# Every form the hook declares is found the way the hook finds it.
FORMS=$(sed -n 's/^CONTAINER_EXEC_FORMS=(\(.*\))$/\1/p' "$PLUGIN/lib/stop-gate/run.sh" | grep -o '"[^"]*"' | tr -d '"')
[ "$(printf '%s\n' "$FORMS" | grep -c .)" -ge 8 ] && ok || fail "containers: the gate's CONTAINER_EXEC_FORMS were read (got: $FORMS)"
build_fixture
exec_checks "$(printf '%s\n' "$FORMS" | jq -Rnc '[inputs | [. + " app make lint", ""]]')"
run_doctor_env -- verification-exec-no-runin
N=$(printf '%s\n' "$OUTPUT" | grep -cE '^WARN +verification-exec-no-runin')
[ "$N" -eq "$(printf '%s\n' "$FORMS" | grep -c .)" ] && ok || fail "containers: every hook exec form is warned about without runIn (got $N)"

# runIn naming an undefined container: an error before a stop refuses it.
build_fixture
exec_checks '[["docker compose exec -w /x app make lint", "nope"]]'
run_doctor_env -- schema
expect_exit 1 "containers: runIn naming an undefined container is an error"
expect_line '^ERROR setting-unknown-ref: .*checks\[0\]\.runIn names "nope"' "containers: the error names the container"

# A check's cwd is a repo-relative directory that must exist.
build_fixture
mkdir -p "$REPO/api"
set_json .claude/verification.json 'd.checks[0].cwd="api"; d.checks[1].cwd="nope"; d.checks[2].cwd="/abs"; d.checks.push({name:"root",command:"true",required:true,cwd:""}, {name:"slashes",command:"true",required:true,cwd:".//api"});'
run_doctor_env -- schema
expect_no_line 'checks\[3\]\.cwd' "cwd: an empty cwd is the root, as the hook reads it (#255 review)"
expect_line '^WARN +setting-dir-missing: \.claude/verification\.json: checks\[4\]\.cwd is "\.//api"' "cwd: .//api, which the hook ignores, is reported"
expect_no_line 'checks\[0\]\.cwd' "cwd: an existing directory raises nothing"
expect_line '^WARN +setting-dir-missing: \.claude/verification\.json: checks\[1\]\.cwd is "nope"' "cwd: a missing directory is reported"
expect_line '^WARN +setting-dir-missing: \.claude/verification\.json: checks\[2\]\.cwd is "/abs"' "cwd: an absolute cwd is reported"
run_doctor_env -- settings
expect_line '^SET +checks\[0\]\.cwd = "api" \(\.claude/verification\.json\)$' "cwd: a check's cwd is listed"

# An ignoreBlockInMain entry that is no blockInMain entry removes nothing:
# warned, while a default's or a project entry's exact text is not (#255 review).
build_fixture
set_json .myspec.json 'd.isolation={blockInMain:["^make[[:space:]]+deploy"], ignoreBlockInMain:["^git[[:space:]]+push([[:space:]]|$)", "^make[[:space:]]+deploy", "^git[[:space:]]+push"]};'
run_doctor_env -- schema
expect_line '^WARN +setting-unmatched-item: \.myspec\.json: isolation\.ignoreBlockInMain\[2\] is "\^git\[\[:space:\]\]\+push", which is not an entry of isolation\.blockInMain' "ignoreBlockInMain: a near-miss of a default is reported"
expect_no_line 'ignoreBlockInMain\[0\]|ignoreBlockInMain\[1\]' "ignoreBlockInMain: a default's or a project entry's exact text is not reported"
expect_exit 0 "ignoreBlockInMain: the finding is a warning"

# The worktree guard's list is a setting: a project's entries and its
# ignoreBlockInMain are listed in force, the trim marked as loosening.
build_fixture
set_json .myspec.json 'd.isolation={blockInMain:["^make[[:space:]]+deploy"], ignoreBlockInMain:["^git[[:space:]]+push([[:space:]]|$)"]};'
run_doctor_env -- settings
expect_line '^SET +isolation\.blockInMain = default \+ \["\^make\[\[:space:\]\]\+deploy"\] \(\.myspec\.json\)$' "blockInMain: the list in force, default plus the project entry, is listed"
expect_line '^SET +isolation\.ignoreBlockInMain = \["\^git.*push.*"\] \(\.myspec\.json\) — loosens a gate$' "blockInMain: ignoreBlockInMain is listed as loosening"
run_doctor_env -- schema
expect_no_line 'setting-' "blockInMain: both keys are known settings of the right type"

# --- pass 4: argument handling ------------------------------------------------

OUTPUT=$(node "$SCRIPT" --list-checks 2>&1); STATUS=$?
expect_exit 0 "--list-checks exits 0"
expect_line '^install +framework-drift' "--list-checks names each check with its group"

OUTPUT=$(node "$SCRIPT" --root "$REPO" nonsense 2>&1); STATUS=$?
expect_exit 2 "an unknown selector is a usage error"

OUTPUT=$(node "$SCRIPT" --root "$ROOT" 2>&1); STATUS=$?
expect_exit 0 "a directory with no .myspec.json exits 0"
expect_line 'not a myspec project' "a directory with no .myspec.json says so"

# --- report -------------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
