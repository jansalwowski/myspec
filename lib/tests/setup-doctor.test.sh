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
// never catch a drift check that forgot the substitution. Hooks and lib are the
// opposite: ${aiDir} there is live shell/JS syntax, so a faithful install copies
// them byte-for-byte (issue #74).
const put=(src,dest)=>{mkdirSync(join(root,dirname(dest)),{recursive:true});writeFileSync(join(root,dest),readFileSync(src,"utf8").split("${aiDir}").join(aiDir));return dest;};
const putRaw=(src,dest)=>{mkdirSync(join(root,dirname(dest)),{recursive:true});copyFileSync(src,join(root,dest));return dest;};
for(const k of Object.keys(m.files)){
  const dest = k.startsWith("templates/") ? aiDir+"/.templates/"+k.slice(10) : aiDir+"/"+k;
  put(join(plugin,"framework-files",k),dest);
}
for(const [k,e] of Object.entries(m.rules)){ put(join(plugin,"framework-files","rules",k),e.dest); }
for(const [k,e] of Object.entries(m.hooks)){ chmodSync(join(root,putRaw(join(plugin,"hooks",k),e.dest)),0o755); }
for(const [k,e] of Object.entries(m.lib)){ chmodSync(join(root,putRaw(join(plugin,"lib",k),e.dest)),0o755); }
writeFileSync(join(root,".myspec.json"),JSON.stringify({aiDir,frameworkVersion:V,project:{name:"fixture"},migrations:m.migrations||[]},null,2)+"\n");
copyFileSync(join(plugin,"templates","settings-hooks.json"),join(root,".claude","settings.json"));
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
expect_no_line 'framework-removed' "a manifest with an empty removed block reports nothing retired"
expect_no_line 'shipped-drift' "clean install reports no hook or lib drift"
expect_no_line 'dead-path-ref' "framework-owned rules are not scanned for dead refs"
expect_no_line 'topology-missing' "a project with no topologyFile key is not reported"
expect_no_line 'over-budget' "framework-owned rules are not warned about as over budget"
expect_no_line 'framework files over their always-loaded budget' "no plugin-owned always-loaded rule is over the 1000-token budget (regression guard for the 2.0 rules diet)"
expect_no_line 'hook-missing' "the template's \$CLAUDE_PROJECT_DIR hook commands resolve"
expect_no_line 'hook-unregistered' "every shipped hook is recognised as wired"
expect_no_line 'wiring-incomplete' "settings written from the template is fully wired"
expect_no_line 'hook-command-relative' "the template's \$CLAUDE_PROJECT_DIR commands are not reported as relative"
expect_line 'setup doctor: 0 error\(s\)' "summary counts zero errors"

# The stop hook runs exactly these two groups; they must be silent on a clean
# install or the gate blocks every session.
run_doctor --quiet wiring schema
expect_exit 0 "the blocking groups exit 0 on a clean install"
expect_no_line '^ERROR' "the blocking groups report no errors on a clean install"

# --- pass 1b: hooks still registered in the pre-2.2 relative form ------------

# The template now registers hooks as "$CLAUDE_PROJECT_DIR"/.claude/hooks/x.sh,
# because a bare relative command resolves against the session's cwd rather than
# the project — a nested worktree then fails every matching tool call. Pass 1
# covers that shipped form. Every install written before the switch still holds
# the relative one, and update must not treat it as unwired: the two spellings
# name the same file, so a literal comparison would wire each hook a second time.
# It is still reported, as hook-command-relative, so update rewrites it: once a
# session cd's into a subdirectory the bare command fails, and a failing Stop
# hook is non-blocking, so the verification gate is skipped silently (#217).
# That makes it an error: nothing else would ever report the missing gate (#216).
cp "$REPO/.claude/settings.json" "$ROOT/settings-projectdir.json"
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json '
const walk = (n) => {
  if (Array.isArray(n)) { n.forEach(walk); return; }
  if (!n || typeof n !== "object") { return; }
  if (typeof n.command === "string") {
    n.command = n.command.replace(/^"\$CLAUDE_PROJECT_DIR"\//, "");
  }
  Object.values(n).forEach(walk);
};
walk(d.hooks)'

run_doctor wiring
expect_exit 1 "hooks registered in the legacy relative form fail the wiring group"
expect_no_line 'hook-missing' "a relative hook path is not reported missing"
expect_no_line 'hook-unregistered' "a relative hook is recognised as wired"
expect_no_line 'wiring-incomplete' "a relative command matches the template's \$CLAUDE_PROJECT_DIR one"
expect_line 'ERROR hook-command-relative: .claude/settings.json: hook command ".claude/hooks/verify-before-stop.sh" runs .claude/hooks/verify-before-stop.sh by a relative path' "a bare relative Stop hook command is an error"
expect_line 'run: /myspec:update' "a relative framework hook command names update as the fix"
expect_no_line 'WARN +hook-command-relative' "no relative framework hook command is downgraded to a warning"

# Every template entry is reported, whatever its event and matcher: update
# rewrites what the doctor lists, so an entry the scan skipped stays bare. The
# expected list is read from the template, not written out here.
# shellcheck disable=SC2016 # literal text, not an expansion
TEMPLATE_COMMANDS=$(node -e '
const walk = (n, out) => {
  if (Array.isArray(n)) { n.forEach((x) => walk(x, out)); return out; }
  if (!n || typeof n !== "object") { return out; }
  if (typeof n.command === "string") { out.push(n.command.replace(/^"\$CLAUDE_PROJECT_DIR"\//, "")); }
  Object.values(n).forEach((x) => walk(x, out));
  return out;
};
console.log(walk(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks, []).join("\n"));
' "$PLUGIN/templates/settings-hooks.json")
TEMPLATE_COUNT=$(printf '%s\n' "$TEMPLATE_COMMANDS" | grep -c .)
REPORTED_COUNT=$(printf '%s\n' "$OUTPUT" | grep -cE '^ERROR hook-command-relative: .claude/settings.json:')
if [ "$TEMPLATE_COUNT" -gt 0 ] && [ "$REPORTED_COUNT" -eq "$TEMPLATE_COUNT" ]; then ok; else fail "every bare template entry is reported once (template $TEMPLATE_COUNT, reported $REPORTED_COUNT)"; fi
while IFS= read -r cmd; do
  case "$OUTPUT" in
    *"hook command \"$cmd\" runs"*) ok ;;
    *) fail "the bare template command is reported: $cmd" ;;
  esac
done <<< "$TEMPLATE_COMMANDS"

# A project's own relative hook is not the framework's gate: a warning.
mkdir -p "$REPO/scripts"
printf '#!/bin/sh\nexit 0\n' > "$REPO/scripts/own-hook.sh"
chmod 755 "$REPO/scripts/own-hook.sh"
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:"scripts/own-hook.sh"})'
run_doctor hook-command-relative
expect_line 'WARN +hook-command-relative: .claude/settings.json: hook command "scripts/own-hook.sh"' "a project-owned relative hook command is a warning"
# shellcheck disable=SC2016 # literal text, not an expansion
expect_line 'fix: prefix the script with "\$CLAUDE_PROJECT_DIR"/' "a project-owned relative hook command names the prefix fix"
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.pop()'
rm "$REPO/scripts/own-hook.sh"

# The cases below change the Stop entry alone; with every other entry bare they
# would also carry those entries' hook-command-relative errors.
cp "$ROOT/settings-projectdir.json" "$REPO/.claude/settings.json"

# An interpreter may lead the command; the script is then token 1. Such a
# command does not exec the file, so a mode 644 script there is correct and
# calling it an error would block every session: the stop hook runs this group.
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/verify-before-stop.sh\""'
chmod 644 "$REPO/.claude/hooks/verify-before-stop.sh"

run_doctor wiring
expect_exit 0 "an interpreter-led command with a non-executable script exits 0"
expect_no_line '^ERROR' "an interpreter-led command reports no errors"
expect_no_line 'hook-not-executable' "a script run through bash needs no executable bit"
expect_no_line 'hook-unregistered: .claude/hooks/verify-before-stop.sh' "an interpreter-led command still resolves its script"
expect_no_line 'wiring-incomplete' "an interpreter-led command matches the template's bare one"
expect_no_line 'hook-command-relative: .claude/settings.json: hook command "bash' "an interpreter-led \$CLAUDE_PROJECT_DIR command is not relative"

set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "bash ./.claude/hooks/verify-before-stop.sh"'
run_doctor wiring
expect_line 'ERROR hook-command-relative: .claude/settings.json: hook command "bash ./.claude/hooks/verify-before-stop.sh"' "an interpreter-led relative command is an error"

# The bit still matters when the harness execs the file itself.
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = ".claude/hooks/verify-before-stop.sh"'

run_doctor wiring
expect_line 'ERROR hook-not-executable: .claude/hooks/verify-before-stop.sh' "a directly exec'd hook without the bit is still an error"
chmod 755 "$REPO/.claude/hooks/verify-before-stop.sh"

# The braced spelling resolves too. The template writes the bare one, so no
# other case in the suite would catch a broken \${CLAUDE_PROJECT_DIR} branch.
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "${CLAUDE_PROJECT_DIR}/.claude/hooks/verify-before-stop.sh"'

run_doctor wiring
expect_exit 0 "a braced \${CLAUDE_PROJECT_DIR} hook path resolves"
expect_no_line 'hook-missing' "a braced hook path is not reported missing"
expect_no_line 'hook-unregistered' "a braced hook is recognised as wired"

# A .sh that is only an argument is not the hook script: reporting it missing
# blocks the gate on a file the harness never runs, and /myspec:update cannot
# fix it.
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "npx prettier --check src/setup.sh"'

run_doctor wiring
expect_no_line 'hook-missing: src/setup.sh' "a .sh passed as an argument is not treated as the hook script"
expect_line 'WARN +hook-unregistered: .claude/hooks/verify-before-stop.sh' "a command that runs no hook leaves that hook unregistered"
expect_line 'wiring-incomplete' "a command that runs no hook leaves the Stop gate unwired"

# Nor is a path a command merely mentions. Certifying that gate as wired is the
# worse failure of the two: nothing then reports that the hook never runs.
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "echo .claude/hooks/verify-before-stop.sh"'

run_doctor wiring
expect_line 'WARN +hook-unregistered: .claude/hooks/verify-before-stop.sh' "a mentioned hook path does not count as wired"
expect_line 'wiring-incomplete' "a mentioned hook path does not satisfy the template pair"

# A variable this process cannot expand is unresolvable, not missing.
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = "\"$CLAUDE_PLUGIN_ROOT\"/hooks/verify-before-stop.sh"'

run_doctor wiring
expect_no_line 'hook-missing' "an unexpandable variable in a hook path is not reported missing"

set_json .claude/settings.json 'd.hooks.Stop[0].hooks[0].command = ".claude/hooks/verify-before-stop.sh"'

# A genuinely absent hook must still be caught, in either spelling.
# shellcheck disable=SC2016 # literal text, not an expansion
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/ghost.sh"})'

run_doctor wiring
expect_line 'ERROR hook-missing: .claude/hooks/ghost.sh' "a missing hook is still an error, reported by its repo-relative path"

cp "$ROOT/settings-projectdir.json" "$REPO/.claude/settings.json"

# --- pass 1c: the matcher is part of the wiring (issue #125) ------------------

# The template wires mark-code-changed.sh under PostToolUse twice, once per
# matcher. Keying the comparison on (event, script) alone let either entry
# stand in for the other, so a project missing the Bash one reported clean and
# update never added it. Claude Code reads a matcher as a regex, so each
# template tool name is tested against the project's matchers: order, grouping
# and anchors do not matter, a matcher that is absent, empty or "*" covers
# every tool, and the warning names only the tools left uncovered.
set_json .claude/settings.json 'd.hooks.PostToolUse = d.hooks.PostToolUse.filter(e => e.matcher !== "Bash")'

run_doctor wiring
expect_line 'WARN +wiring-incomplete: .claude/settings.json: .claude/hooks/mark-code-changed.sh is not wired under PostToolUse for matcher Bash' "a hook wired under only one of its template matchers is incomplete"
expect_no_line 'validate-frontmatter.sh is not wired' "the hooks wired under their template matcher stay quiet"

set_json .claude/settings.json 'd.hooks.PostToolUse[0].matcher = "Write|Edit"'

run_doctor wiring
expect_line 'mark-code-changed.sh is not wired under PostToolUse for matcher MultiEdit\|NotebookEdit —' "a narrower matcher names only the tools it leaves uncovered"

set_json .claude/settings.json 'd.hooks.PostToolUse[0].matcher = "NotebookEdit|Edit|Bash|MultiEdit|Write"'

run_doctor wiring
expect_no_line 'wiring-incomplete' "one entry whose alternation covers both template matchers, in any order, is wired"

set_json .claude/settings.json 'delete d.hooks.PostToolUse[0].matcher'

run_doctor wiring
expect_no_line 'wiring-incomplete' "an entry with no matcher covers every template matcher"

set_json .claude/settings.json 'd.hooks.PostToolUse[0].matcher = "*"'

run_doctor wiring
expect_no_line 'wiring-incomplete' "a \"*\" matcher covers every template matcher"

set_json .claude/settings.json 'd.hooks.PostToolUse[0].matcher = ".*"'

run_doctor wiring
expect_no_line 'wiring-incomplete' "a regex matcher is compiled, not split on |"

cp "$ROOT/settings-projectdir.json" "$REPO/.claude/settings.json"
set_json .claude/settings.json 'd.hooks.PostToolUse.forEach(e => { e.matcher = e.matcher === "Bash" ? "^Bash$" : "(" + e.matcher + ")" })'

run_doctor wiring
expect_no_line 'wiring-incomplete' "anchored and grouped matchers cover the names they match"

cp "$ROOT/settings-projectdir.json" "$REPO/.claude/settings.json"
set_json .claude/settings.json 'd.hooks.Stop[0].matcher = "Bash"'

run_doctor wiring
expect_no_line 'wiring-incomplete' "a matcher on an event the template wires with none does not unwire it"

cp "$ROOT/settings-projectdir.json" "$REPO/.claude/settings.json"
set_json .claude/settings.json 'd.hooks.PostToolUse.find(e => e.matcher === "Bash").matcher = ["Bash"]'

run_doctor wiring
expect_line 'mark-code-changed.sh is not wired under PostToolUse for matcher Bash' "a matcher that is not a string covers nothing"

cp "$ROOT/settings-projectdir.json" "$REPO/.claude/settings.json"

# --- pass 2: one break per check ---------------------------------------------

printf '\n# hand edit\n' >> "$REPO/.claude/rules/paths.md"
rm "$REPO/ai/.templates/session-log.md"
perl -0pi -e 's/<!-- myspec:framework-start -->//' "$REPO/ai/pre-flight.md"
perl -0pi -e 's/^# .*$/# Renamed Locally/m' "$REPO/ai/anti-patterns.md"
printf '\n# hand edit\n' >> "$REPO/.claude/hooks/no-absolute-paths.sh"
set_json .myspec.json 'd.frameworkFiles = {"rules/ideas.md": {version: "1.27.0", lastUpdated: "2026-08-01"}}'
printf '## Project anchors\n' > "$REPO/.claude/rules/ai-setup-audit.md"
mkdir -p "$REPO/ai/memory/sessions/active" && printf -- '---\nstatus: active\n---\n' > "$REPO/ai/memory/sessions/active/old.md"
chmod -x "$REPO/.claude/hooks/guard-worktree-context.sh"
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:".claude/hooks/ghost.sh"})'
set_json .claude/settings.json 'd.hooks.PostToolUse[0].hooks = d.hooks.PostToolUse[0].hooks.filter(h => !/require-reuse-audit/.test(h.command))'
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
expect_line 'ERROR shipped-drift: .claude/hooks/no-absolute-paths.sh' "a hand-edited hook is an error"
expect_line 'WARN +myspec-schema-stale: .myspec.json' "pre-2.0 per-file bookkeeping is a warning"
expect_line 'WARN +doctor-rule-unrenamed: .claude/rules/ai-setup-audit.md' "the pre-rename doctor extension is a warning"
expect_line 'WARN +sessions-unmigrated: ai/memory/sessions/active' "a 1.x live session log is a warning"
expect_line 'ERROR hook-not-executable: .claude/hooks/guard-worktree-context.sh' "a registered hook without +x is an error"
expect_line 'ERROR hook-missing: .claude/hooks/ghost.sh' "a registered hook that does not exist is an error"
expect_line 'WARN +hook-unregistered: .claude/hooks/broken.sh' "an unwired hook script is a warning"
expect_line 'ERROR hook-syntax: .claude/hooks/broken.sh' "a hook that fails bash -n is an error"
expect_line 'WARN +wiring-incomplete: .claude/settings.json' "a hook the template wires but settings does not is a warning"
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
expect_line 'run: chmod \+x .claude/hooks/guard-worktree-context.sh' "findings carry a literal fix command"

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

# --- pass 2b: ${aiDir} substituted into code is drift, not installation --------
# hooks/ and lib/ resolve aiDir at runtime and carry ${aiDir} as live shell and
# JS template-literal syntax. init/update must copy them byte-for-byte; a copy
# with the value baked in is corrupt, and matchesShipped used to accept it — so
# the corruption was invisible and survived every later update (issue #74).

build_fixture
# shellcheck disable=SC2016 # literal text, not an expansion
node -e '
const {readFileSync,writeFileSync}=require("fs");const {join}=require("path");
const root=process.argv[1];
for (const f of [".claude/lib/setup-doctor.mjs",".claude/hooks/validate-frontmatter.sh"]) {
  const p=join(root,f);
  writeFileSync(p, readFileSync(p,"utf8").split("${aiDir}").join("ai"));
}
' "$REPO"
run_doctor install

expect_line 'shipped-drift: .claude/lib/setup-doctor.mjs' "a lib helper with the aiDir value baked in is drift"
expect_line 'shipped-drift: .claude/hooks/validate-frontmatter.sh' "a hook with the aiDir value baked in is drift"

# Documents are the opposite case: both spellings are a correct install, because
# init and update disagree about which of them substitutes the rules.
build_fixture
cp "$PLUGIN/framework-files/rules/paths.md" "$REPO/.claude/rules/paths.md"
run_doctor install
expect_no_line 'framework-drift: .claude/rules/paths.md' "a rule holding the literal placeholder is not drift"

# --- pass 3a: pins are honoured for every manifest block -----------------------
# update looks a pin up by its manifest key — `rules/workflow.md`,
# `hooks/guard-worktree-context.sh`, `lib/branch-cleanup.sh` — and skips the
# entry. The doctor tracked only `files` and `rules`, so a pinned hook or helper
# drifted forever with no way to clear it (issue #71). Worse, `shipped-drift` is
# what update Step 3.7 reads as "this entry did not get written, re-apply it",
# which pointed at the one file that must not be re-applied.

build_fixture
node -e '
const {readFileSync,writeFileSync}=require("fs");
const {join}=require("path");
const root=process.argv[1];
const cfg=JSON.parse(readFileSync(join(root,".myspec.json"),"utf8"));
cfg.frameworkFiles={
  "hooks/guard-worktree-context.sh":{pinned:"extra guard for our monorepo"},
  "lib/branch-cleanup.sh":{pinned:"local lint-gate fixes"},
};
writeFileSync(join(root,".myspec.json"),JSON.stringify(cfg,null,2)+"\n");
for (const f of [".claude/hooks/guard-worktree-context.sh",".claude/lib/branch-cleanup.sh"]) {
  writeFileSync(join(root,f), readFileSync(join(root,f),"utf8")+"\n# local fork\n");
}
' "$REPO"
run_doctor install

expect_exit 0 "a pinned hook and lib helper do not fail the run"
expect_no_line 'shipped-drift: .claude/hooks/guard-worktree-context.sh' "a pinned hook is not reported as drifted"
expect_no_line 'shipped-drift: .claude/lib/branch-cleanup.sh' "a pinned lib helper is not reported as drifted"

# The pin must not blind the check for its neighbours.
node -e '
const {readFileSync,writeFileSync}=require("fs");const {join}=require("path");
const root=process.argv[1];const f=join(root,".claude/hooks/mark-code-changed.sh");
writeFileSync(f, readFileSync(f,"utf8")+"\n# unpinned drift\n");
' "$REPO"
run_doctor install
expect_line 'shipped-drift: .claude/hooks/mark-code-changed.sh' "an unpinned hook still drifts while a sibling is pinned"

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
set_json .myspec.json 'd.isolation={worktreeRoot:"wt", allowLinkedModules:false}; d.hooks={markCodeChanged:{ignorePaths:["gen/**"]}}; d.reuseAudit={enabled:false};'
set_json .claude/verification.json 'd.containers={api:{mountSource:".", mountTarget:"/srv/app"}}; d.checks[0].paths=["api/**"]; d.checks[0].runIn="api";'
run_doctor_env MYSPEC_ALLOW_LINKED_MODULES=1 MYSPEC_CHECK_CAP_SECONDS=30 -- settings
expect_line '^SET +isolation\.worktreeRoot = "wt" \(\.myspec\.json\)$' "settings: a project value is listed with its file and is not marked"
expect_line '^SET +isolation\.allowLinkedModules = true \(session: MYSPEC_ALLOW_LINKED_MODULES=1\) — loosens a gate$' "settings: a session override wins over the project file, names its variable, and is marked"
expect_line '^SET +hooks\.markCodeChanged\.ignorePaths = \["gen/\*\*"\] \(\.myspec\.json\) — loosens a gate$' "settings: ignorePaths is marked as loosening"
expect_line '^SET +reuseAudit\.enabled = false \(\.myspec\.json\) — loosens a gate$' "settings: a gate turned off is marked as loosening"
expect_line '^SET +checks\[0\]\.paths = \["api/\*\*"\] \(\.claude/verification\.json\) — loosens a gate$' "settings: a check's paths is marked as loosening"
expect_line '^SET +checks\[0\]\.runIn = "api" \(\.claude/verification\.json\)$' "settings: runIn is listed, unmarked"
expect_line '^SET +MYSPEC_CHECK_CAP_SECONDS = "30" \(session\)$' "settings: a standalone session variable is listed"
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
set_json .myspec.json 'd.isolation={provision:{symlink:[], copy:[]}}; d.isolaton={}; d.reuseAudt={}; d.hooks={markCodeChanged:{ignorePaths:7}};'
set_json .claude/verification.json 'd.checks=[];'
run_doctor_env -- settings
expect_line '^SET +isolation\.provision\.symlink = \[\] \(\.myspec\.json\)$' "settings: an emptied symlink list is listed"
expect_line '^SET +isolation\.provision\.copy = \[\] \(\.myspec\.json\)$' "settings: an emptied copy list is listed"
expect_line '^SET +checks = \[\] \(\.claude/verification\.json\)$' "settings: an emptied checks list is listed"

run_doctor_env -- schema
expect_line '^WARN +setting-unknown-key: \.myspec\.json: isolaton is not a myspec setting \(did you mean isolation\?\)' "settings: a top-level typo gets its near miss"
expect_line '^WARN +setting-unknown-key: \.myspec\.json: reuseAudt is not a myspec setting \(did you mean reuseAudit\?\)' "settings: a second top-level typo gets its near miss"
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
