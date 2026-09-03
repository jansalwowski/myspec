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
  node -e '
const {readFileSync,writeFileSync,mkdirSync,copyFileSync,chmodSync}=require("fs");
const {join,dirname}=require("path");
const plugin=process.argv[1], root=process.argv[2], aiDir="ai";
const m=JSON.parse(readFileSync(join(plugin,"framework-files","manifest.json"),"utf8"));
const V=m.frameworkVersion, ff={};
// init and update replace ${aiDir} in what they copy. Copying verbatim here
// would compare plugin bytes against plugin bytes and could never catch a
// drift check that forgot the substitution — which is exactly what it missed.
const put=(src,dest)=>{mkdirSync(join(root,dirname(dest)),{recursive:true});writeFileSync(join(root,dest),readFileSync(src,"utf8").split("${aiDir}").join(aiDir));return dest;};
for(const k of Object.keys(m.files)){
  const dest = k.startsWith("templates/") ? aiDir+"/.templates/"+k.slice(10) : aiDir+"/"+k;
  put(join(plugin,"framework-files",k),dest); ff[k]={version:V,lastUpdated:"2026-09-02"};
}
for(const [k,e] of Object.entries(m.rules)){ put(join(plugin,"framework-files","rules",k),e.dest); ff["rules/"+k]={version:V,lastUpdated:"2026-09-02"}; }
for(const [k,e] of Object.entries(m.hooks)){ chmodSync(join(root,put(join(plugin,"hooks",k),e.dest)),0o755); }
for(const [k,e] of Object.entries(m.lib)){ chmodSync(join(root,put(join(plugin,"lib",k),e.dest)),0o755); }
writeFileSync(join(root,".myspec.json"),JSON.stringify({aiDir,frameworkVersion:V,project:{name:"fixture"},frameworkFiles:ff},null,2)+"\n");
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
expect_no_line 'marker-header-drift' "an unmodified marker-merge header is not drift"
expect_no_line 'shipped-drift' "clean install reports no hook or lib drift"
expect_no_line 'dead-path-ref' "framework-owned rules are not scanned for dead refs"
expect_no_line 'over-budget' "framework-owned rules are not warned about as over budget"
expect_line 'framework files over their always-loaded budget' "plugin-owned budget overruns are reported as a note"
expect_line 'setup doctor: 0 error\(s\)' "summary counts zero errors"

# The stop hook runs exactly these two groups; they must be silent on a clean
# install or the gate blocks every session.
run_doctor --quiet wiring schema
expect_exit 0 "the blocking groups exit 0 on a clean install"
expect_no_line '^ERROR' "the blocking groups report no errors on a clean install"

# --- pass 2: one break per check ---------------------------------------------

printf '\n# hand edit\n' >> "$REPO/.claude/rules/paths.md"
rm "$REPO/ai/.templates/session-log.md"
perl -0pi -e 's/<!-- myspec:framework-start -->//' "$REPO/ai/pre-flight.md"
perl -0pi -e 's/^# .*$/# Renamed Locally/m' "$REPO/ai/anti-patterns.md"
printf '\n# hand edit\n' >> "$REPO/.claude/hooks/no-absolute-paths.sh"
set_json .myspec.json 'delete d.frameworkFiles["rules/ideas.md"]'
chmod -x "$REPO/.claude/hooks/guard-git-branch.sh"
set_json .claude/settings.json 'd.hooks.Stop[0].hooks.push({type:"command",command:".claude/hooks/ghost.sh"})'
set_json .claude/settings.json 'd.hooks.PostToolUse[0].hooks = d.hooks.PostToolUse[0].hooks.filter(h => !/require-reuse-audit/.test(h.command))'
printf '#!/usr/bin/env bash\nif [ 1 =\n' > "$REPO/.claude/hooks/broken.sh"
chmod +x "$REPO/.claude/hooks/broken.sh"
set_json .myspec.json 'd.aiDir = "ai/"'
printf 'not json' > "$REPO/.claude/verification.json"
printf 'features:\n    - name: misindented\n      status: complete\n' > "$REPO/ai/features/index.yaml"
{
  echo '# Fixture'
  echo
  echo 'Rules live in `.claude/rules/nope.md`. Route to `/myspec:not-a-skill`.'
  head -c 4000 /dev/zero | tr '\0' 'x'
} > "$REPO/CLAUDE.md"

run_doctor

expect_exit 1 "a broken install exits 1"
expect_line 'ERROR framework-drift: .claude/rules/paths.md' "a hand-edited rule at a matching version is an error"
expect_line 'ERROR framework-missing: ai/.templates/session-log.md' "a deleted framework file is an error"
expect_line 'ERROR marker-missing: ai/pre-flight.md' "a marker-merge file without markers is an error"
expect_line 'ERROR shipped-drift: .claude/hooks/no-absolute-paths.sh' "a hand-edited hook is an error"
expect_line 'WARN +framework-unlisted: .myspec.json' "an untracked framework file is a warning"
expect_line 'ERROR hook-not-executable: .claude/hooks/guard-git-branch.sh' "a registered hook without +x is an error"
expect_line 'ERROR hook-missing: .claude/hooks/ghost.sh' "a registered hook that does not exist is an error"
expect_line 'WARN +hook-unregistered: .claude/hooks/broken.sh' "an unwired hook script is a warning"
expect_line 'ERROR hook-syntax: .claude/hooks/broken.sh' "a hook that fails bash -n is an error"
expect_line 'WARN +wiring-incomplete: .claude/settings.json' "a hook the template wires but settings does not is a warning"
expect_line 'ERROR aidir-trailing-slash' "a trailing slash on aiDir is an error"
expect_line 'ERROR verification-unparseable' "unparseable verification.json is an error"
expect_line 'ERROR features-index-unreadable: ai/features/index.yaml:2' "a mis-indented manifest entry is an error, with its line"
expect_line 'WARN +marker-header-drift: ai/anti-patterns.md' "a changed marker-merge header is a warning update cannot fix"
expect_no_line 'ERROR marker-header-drift' "the header finding never blocks, because update cannot repair it"
expect_line 'WARN +over-budget: CLAUDE.md' "an oversized project CLAUDE.md is a warning"
expect_line 'WARN +dead-path-ref: CLAUDE.md' "a dead path reference in a project file is a warning"
expect_line 'WARN +dead-skill-ref: CLAUDE.md' "a reference to a skill the plugin does not ship is a warning"
expect_line 'run: chmod \+x .claude/hooks/guard-git-branch.sh' "findings carry a literal fix command"

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
set_json .myspec.json 'd.frameworkFiles["memory-index.md"] = d.frameworkFiles["anti-patterns.md"]; delete d.frameworkFiles["anti-patterns.md"]'

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
