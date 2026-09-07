#!/usr/bin/env bash
# Regression fixture for backbone-audit/audit.mjs.
#
# The audit exists to catch topology drift a human stopped noticing, so three
# things have to be proven, in this order of importance:
#
#   1. A topology file matching its repository reports NOTHING. An audit that
#      cries drift over a correct file gets muted within a week, and then it
#      catches nothing forever. The baseline fixture is therefore written in the
#      shape `blueprints/backbone.md` actually emits — banner comments, trailing
#      `# TODO:` markers, database/ai_docs/agent blocks, per-unit config — not a
#      simplified shape that happens to avoid the checks.
#   2. Every check fires on the shape it was written for, and each one has a
#      POSITIVE control. An `expect_no_line` whose fixture could never produce
#      the line passes for the wrong reason and hides the check being deleted.
#   3. A check that cannot run says so. Reporting "no issues" when the parser
#      refused, the workspace config was unreadable or git was shallow is the
#      one failure this tool must never have.
#
# Usage: backbone-audit.test.sh [path-to-script]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${1:-$HERE/../backbone-audit/audit.mjs}"

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: script not found: $SCRIPT" >&2
  exit 1
fi

# The liveness assertions depend on git content semantics, so the host's global
# config must not reach the fixtures: commit.gpgsign alone makes every commit
# fail while 40-odd assertions still report green.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT=$(cd "$(mktemp -d)" && pwd -P)
REPO="$ROOT/proj"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect_line() {     # expect_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then ok; else fail "$2 (no line matching: $1)"; fi
}

expect_no_line() {  # expect_no_line <regex> <description>
  if grep -Eq -- "$1" <<<"$OUTPUT"; then fail "$2 (unexpected line matching: $1)"; else ok; fi
}

expect_exit() {     # expect_exit <want> <description>
  if [ "$STATUS" -eq "$1" ]; then ok; else fail "$2 (exit $STATUS, want $1)"; fi
}

run_audit() {       # run_audit [args...]
  OUTPUT=$(cd "$REPO" && node "$SCRIPT" "$@" 2>&1); STATUS=$?
}

edit_backbone() {   # edit_backbone <sed-expression>
  sed -i.bak "$1" "$REPO/backbone.yml" && rm -f "$REPO/backbone.yml.bak"
}

commit_all() {      # commit_all <message>
  (cd "$REPO" && git add -A && git commit -qm "$1")
}

# ── the fixture ──────────────────────────────────────────────────────────────
# A small monorepo whose backbone.yml matches it exactly, written the way the
# blueprint writes one.

build_fixture() {
  rm -rf "$REPO"
  mkdir -p "$REPO"/{apps/api/src/services,apps/web/src,packages/uikit/src,.ai/features,.claude}
  cd "$REPO" || exit 1

  cat > pnpm-workspace.yaml <<'YAML'
packages:
  - "apps/*"
  - "packages/*"
YAML

  cat > package.json <<'JSON'
{
  "name": "fixture",
  "private": true,
  "scripts": { "dev": "turbo dev", "test": "vitest", "prepare": "husky" }
}
JSON

  echo '{ "name": "@fx/api" }'   > apps/api/package.json
  echo '{ "name": "@fx/web" }'   > apps/web/package.json
  echo '{ "name": "@fx/uikit" }' > packages/uikit/package.json

  echo 'export const boot = 1'  > apps/api/src/index.ts
  # Three files: the src-unlisted threshold is 3, so a listed directory that
  # sits below it would make the "listed dirs are not reported" assertion vacuous.
  echo 'export const a = 1'     > apps/api/src/services/a.ts
  echo 'export const b = 1'     > apps/api/src/services/b.ts
  echo 'export const c = 1'     > apps/api/src/services/c.ts
  echo 'export const t = 1'     > apps/api/src/services/a.test.ts
  echo 'import "@fx/uikit"'     > apps/web/src/main.ts
  echo 'export const ui = 1'    > packages/uikit/src/index.ts
  echo '{}'                     > tsconfig.json
  mkdir -p node_modules/.bin
  echo '{}'                     > apps/api/tsconfig.json
  echo '# index'                > .ai/INDEX.md
  echo '{}'                     > .claude/verification.json

  echo '{ "aiDir": ".ai", "topologyFile": "backbone.yml" }' > .myspec.json

  cat > backbone.yml <<'YAML'
version: 1
project: fixture
package_manager: pnpm
workspace_config: pnpm-workspace.yaml

# ── STRUCTURE ────────────────────────────────────────────────────────────────

apps:
  api:
    path: apps/api
    package: "@fx/api"
    purpose: API server
    stack: [Express, Apollo]
    entry: src/index.ts
    src:
      src/services/: business logic
    tests:
      pattern: "src/**/*.{test,spec}.ts"
      runner: vitest  # TODO: verify
    config:
      tsconfig: apps/api/tsconfig.json
  web:
    path: apps/web
    package: "@fx/web"
    purpose: web client
    entry: src/main.ts

packages:
  uikit:
    path: packages/uikit
    package: "@fx/uikit"
    purpose: shared components
    entry: src/index.ts
    used_by: [apps/web]

# ── DATABASE ─────────────────────────────────────────────────────────────────

database:
  schema: # TODO: add schema path
  migrations: # TODO: add migrations path

# ── AI DOCUMENTATION ─────────────────────────────────────────────────────────

ai_docs:
  index: .ai/INDEX.md
  features:
    dir: .ai/features/

# ── AGENT CONFIGURATION ──────────────────────────────────────────────────────

agent:
  verification: .claude/verification.json
  worktrees: .claude/worktrees/  # TODO: remove if not using git worktrees

# ── BOUNDARIES ───────────────────────────────────────────────────────────────

boundaries:
  never_modify:
    - .env
    - "**/node_modules/"

# ── COMMANDS ─────────────────────────────────────────────────────────────────

commands:
  dev: "pnpm dev"
  test: "pnpm test"

# ── ROOT CONFIG ───────────────────────────────────────────────────────────────

root_config:
  typescript: tsconfig.json

# ── AUDIT ────────────────────────────────────────────────────────────────────

audit:
  ignore: []
  stale_days: 365
YAML

  git init -q -b main .
  git config user.email t@example.com
  git config user.name Test
  git add -A
  git commit -qm init
}

# ═══ pass 1: a blueprint-shaped topology file that matches its repo is silent ══

build_fixture
run_audit

expect_exit 0 "a topology file matching its repo exits 0"
expect_line 'critical=0 high=0 medium=0 low=0' "a matching topology file reports no issues"
expect_line 'No issues at or above severity low' "the clean report says so explicitly"
expect_no_line 'NOT CHECKED' "nothing is skipped on a fully-equipped fixture"
expect_no_line 'prepare' "npm lifecycle scripts are not reported as undocumented commands"
expect_no_line 'src/services' "a listed source directory is not also reported as unlisted"
expect_no_line 'runner' "a value marked # TODO is not audited as fact"
expect_no_line 'worktrees' "a path whose trailing comment is a TODO is not audited as fact"
expect_no_line 'never_modify protects' "the blueprint default .env boundary does not fire"
expect_no_line 'database' "TODO-marked database paths are not audited as fact"

# Positive control for the two assertions above that depend on TODO handling:
# strip the marker and the value must be audited.
build_fixture
edit_backbone 's|worktrees: .claude/worktrees/  # TODO: remove if not using git worktrees|worktrees: .claude/worktrees/|'
run_audit
expect_line 'MEDIUM .*agent.worktrees points at ".claude/worktrees/"' "the same path IS audited once the TODO marker is gone"

# Positive control for src/services: unlist it and it must be reported.
build_fixture
edit_backbone 's|      src/services/: business logic|      src/other/: business logic|'
run_audit
expect_line 'LOW .*src/services/ holds 4 source files but is not listed under src:' "an unlisted source directory over the threshold IS reported"

# ═══ pass 2: stale — declared in the topology, gone or changed on disk ════════

build_fixture
rm -rf "$REPO/apps/web"
run_audit
expect_exit 2 "a declared path that no longer exists is critical"
expect_line 'CRITICAL .*app "web" path "apps/web" does not exist' "a vanished app path is reported"
expect_line 'at backbone.yml:[0-9]+' "findings carry the line to edit"

build_fixture
edit_backbone 's|    entry: src/index.ts|    entry: src/server.ts|'
run_audit
expect_line 'HIGH .*entry "src/server.ts" does not exist' "a stale entry point is reported"

# The repo root has a src/ and a tsconfig.json. A unit-relative declaration must
# NOT be satisfied by the root copy: that fallback silenced the whole sweep.
build_fixture
mkdir -p "$REPO/src" && echo 'x' > "$REPO/src/main.ts"
rm "$REPO/apps/web/src/main.ts"
commit_all root-src
run_audit
expect_line 'HIGH .*app "web" entry "src/main.ts" does not exist' "a root-level file does not satisfy a unit-relative entry"

build_fixture
edit_backbone 's|      src/services/: business logic|      src/gone/: business logic|'
run_audit
expect_line 'MEDIUM .*lists source dir "src/gone/"' "a removed source directory is reported"

build_fixture
edit_backbone 's|      tsconfig: apps/api/tsconfig.json|      tsconfig: apps/api/tsconfig.build.json|'
run_audit
expect_line 'MEDIUM .*config.tsconfig points at "apps/api/tsconfig.build.json"' "a stale per-unit config path is reported"

build_fixture
edit_backbone 's|"@fx/api"|"@fx/api-renamed"|'
run_audit
expect_line 'MEDIUM .*claims package "@fx/api-renamed" but apps/api/package.json says "@fx/api"' "a renamed package is reported"
expect_line 'fix: +set package: "@fx/api"' "the fix names the real package name"

build_fixture
edit_backbone 's|    package: "@fx/web"||'
run_audit
expect_line 'LOW .*app "web" has a package.json \(@fx/web\) but no package: key' "an omitted package key is reported — a rename behind it is undetectable"

build_fixture
edit_backbone 's|    path: apps/web|    purpose: no path here|'
run_audit
expect_line 'HIGH .*app "web" declares no path' "a unit with no path is reported"

# A unit collapsed to a scalar by a hand edit holds no fields at all; an empty
# block is a different defect and is covered by the path-undeclared case above.
build_fixture
node -e '
const fs = require("fs"), p = process.argv[1] + "/backbone.yml";
fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace(/  web:\n    path: apps\/web\n    package: "@fx\/web"\n    purpose: web client\n    entry: src\/main.ts\n/, "  web: apps/web\n"));
' "$REPO"
run_audit
expect_line 'HIGH .*app "web" has no fields' "a unit collapsed to a scalar is reported"

build_fixture
edit_backbone 's|      pattern: "src/\*\*/\*.{test,spec}.ts"|      pattern: "src/**/*.notatest.ts"|'
run_audit
expect_line 'LOW .*tests.pattern "src/\*\*/\*.notatest.ts" matches no file' "a test pattern matching nothing is reported"

build_fixture
edit_backbone 's|      pattern: "src/\*\*/\*.{test,spec}.ts"|      pattern: "*.test.ts"|'
run_audit
expect_no_line 'tests.pattern' "a bare test pattern matches at any depth, as test runners mean it"

build_fixture
edit_backbone 's|    used_by: \[apps/web\]|    used_by: [apps/gone]|'
run_audit
expect_line 'MEDIUM .*lists consumer "apps/gone", which does not exist' "a consumer directory that is gone is reported"

build_fixture
edit_backbone 's|  test: "pnpm test"|  typecheck: "pnpm typecheck"|'
run_audit
expect_exit 1 "a command with no script behind it is high severity"
expect_line 'HIGH .*commands.typecheck runs "pnpm typecheck" but there is no "typecheck" script' "a dead command is reported"

# pnpm/yarn also run a local binary, so `pnpm tsc` with no `tsc` script is valid.
build_fixture
mkdir -p "$REPO/node_modules/.bin" && touch "$REPO/node_modules/.bin/tsc"
edit_backbone 's|  test: "pnpm test"|  test: "pnpm test"\n  typecheck: "pnpm tsc"|'
run_audit
expect_no_line 'no "tsc" script' "a local binary is not reported as a missing script"

build_fixture
edit_backbone 's|  typescript: tsconfig.json|  typescript: config/tsconfig.json|'
run_audit
expect_line 'MEDIUM .*root_config.typescript points at "config/tsconfig.json"' "a moved root config file is reported"

build_fixture
edit_backbone 's|  index: .ai/INDEX.md|  index: .ai/MISSING.md|'
run_audit
expect_line 'MEDIUM .*ai_docs.index points at ".ai/MISSING.md"' "a stale nested ai_docs path is reported"

build_fixture
edit_backbone 's|workspace_config: pnpm-workspace.yaml|workspace_config: config/workspaces.yaml|'
run_audit
expect_line 'HIGH .*workspace_config names "config/workspaces.yaml", which does not exist' "a broken workspace_config is reported, since the MISSING sweep depends on it"

# A protected path that moved is protection that silently stopped applying.
build_fixture
edit_backbone 's|    - .env|    - infra/terraform/prod|'
run_audit
expect_line 'MEDIUM .*boundaries.never_modify protects "infra/terraform/prod", which does not exist' "a stale boundary path is reported"

# ═══ pass 3: missing — present in the repo, absent from the topology ══════════

build_fixture
mkdir -p "$REPO/packages/newpkg/src"
echo '{ "name": "@fx/newpkg" }' > "$REPO/packages/newpkg/package.json"
echo 'export const n = 1' > "$REPO/packages/newpkg/src/index.ts"
run_audit
expect_exit 1 "an undocumented workspace member is high severity"
expect_line 'HIGH .*workspace member "packages/newpkg" \(@fx/newpkg\) is not in the topology file' "a new workspace member is reported"
expect_line 'fix: +add it under apps: or packages: with path: packages/newpkg' "the fix says where to add it"

# `build` and `dist` are real package names as often as they are build output.
# Filtering them out of glob expansion made undocumented members invisible.
build_fixture
mkdir -p "$REPO/packages/dist"
echo '{ "name": "@fx/dist" }' > "$REPO/packages/dist/package.json"
run_audit
expect_line 'HIGH .*workspace member "packages/dist" \(@fx/dist\) is not in the topology file' "a workspace member named like build output is still enumerated"

build_fixture
node -e '
const fs = require("fs"), p = process.argv[1] + "/package.json";
const m = JSON.parse(fs.readFileSync(p, "utf8"));
m.scripts.lint = "eslint .";
m.scripts.preview = "vite preview";
fs.writeFileSync(p, JSON.stringify(m, null, 2));
' "$REPO"
run_audit
expect_line 'LOW .*package.json script "lint" is not in commands:' "a new script missing from commands is reported"
expect_line 'LOW .*package.json script "preview" is not in commands:' "a script merely starting with pre- is not mistaken for a lifecycle hook"

build_fixture
mkdir -p "$REPO/apps/api/src/workers"
for i in 1 2 3; do echo "export const w = $i" > "$REPO/apps/api/src/workers/w$i.ts"; done
run_audit
expect_line 'LOW .*src/workers/ holds 3 source files but is not listed under src:' "a new source directory with real code is reported"

# Not every unit keeps code under src/.
build_fixture
mkdir -p "$REPO/apps/api/internal/queue"
for i in 1 2 3; do echo "package queue" > "$REPO/apps/api/internal/queue/q$i.go"; done
run_audit
expect_line 'LOW .*internal/queue/ holds 3 source files but is not listed under src:' "a source root other than src/ is walked"

build_fixture
mkdir -p "$REPO/apps/api/src/scratch"
echo 'export const one = 1' > "$REPO/apps/api/src/scratch/one.ts"
run_audit
expect_no_line 'src/scratch' "a directory below the source-file threshold is not reported"

build_fixture
touch "$REPO/docker-compose.yml"
run_audit
expect_line 'LOW .*docker-compose.yml exists at the project root but is not in root_config' "a new root config file is reported"

build_fixture
mkdir -p "$REPO/prisma"
touch "$REPO/prisma/schema.prisma"
edit_backbone '/^database:/,+2d'
run_audit
expect_line 'MEDIUM .*prisma/schema.prisma exists but the topology file has no database: block' "an undocumented database is reported"

# ═══ pass 4: liveness signals ════════════════════════════════════════════════

build_fixture
cd "$REPO" || exit 1
git commit -q --amend --no-edit --date="2023-01-01T00:00:00Z" \
  --author="Test <t@example.com>" >/dev/null 2>&1
GIT_COMMITTER_DATE="2023-01-01T00:00:00Z" git commit -q --amend --no-edit --date="2023-01-01T00:00:00Z"
echo 'export const fresh = 1' > apps/api/src/fresh.ts
commit_all recent
run_audit
expect_line 'MEDIUM .*package "uikit" \(packages/uikit\) has no commit since 2023-01-01' "a path nothing has touched in years is signalled"
expect_line 'LIVENESS SIGNALS' "liveness findings are grouped apart from drift"
expect_line 'verify before acting' "the liveness header says the signals are not verdicts"

run_audit --no-liveness
expect_no_line 'LIVENESS SIGNALS' "--no-liveness suppresses the whole sweep"
expect_line 'liveness sweep: +DID NOT RUN' "a suppressed sweep is announced, not silently skipped"

run_audit --stale-days=10000
expect_no_line 'has no commit since' "--stale-days raises the staleness threshold"

build_fixture
rm "$REPO/apps/web/src/main.ts"
edit_backbone 's|    entry: src/main.ts|    entry: src/index.ts|'
edit_backbone 's|    used_by: \[apps/web\]|    used_by: []|'
echo 'export const w = 1' > "$REPO/apps/web/src/index.ts"
commit_all drop-import
run_audit
expect_line 'MEDIUM .*package "uikit" \(@fx/uikit\) has no inbound references outside its own directory' "a package nothing imports is signalled"
expect_line 'check: +grep -rIl .*@fx/uikit' "the evidence command searches the working tree, not just the index"
expect_line 'git grep misses untracked, gitignored and submodule code' "the fix names what the signal cannot see"

# used-by-stale is a grep proxy and belongs with the other signals, not with the
# mechanically-decided drift the skill says to act on.
build_fixture
rm "$REPO/apps/web/src/main.ts"
echo 'export const w = 1' > "$REPO/apps/web/src/index.ts"
edit_backbone 's|    entry: src/main.ts|    entry: src/index.ts|'
commit_all drop-import2
run_audit
expect_line 'MEDIUM .*lists consumer "apps/web", but nothing tracked under it references @fx/uikit' "a consumer that stopped importing is signalled"
OUTPUT=$(sed -n '/LIVENESS SIGNALS/,$p' <<<"$OUTPUT")
expect_line 'lists consumer "apps/web"' "used-by-stale is filed under liveness, not stale"

build_fixture
cd "$REPO" || exit 1
mkdir -p generated/client
echo 'export const gen = 1' > generated/client/index.ts
echo '{ "name": "@fx/generated" }' > generated/client/package.json
node -e '
const fs = require("fs");
let t = fs.readFileSync("backbone.yml", "utf8");
t = t.replace("packages:\n  uikit:", "packages:\n  generated:\n    path: generated/client\n    package: \"@fx/generated\"\n  uikit:");
t = t.replace("  never_modify:", "  generated_do_not_edit:\n    - generated/\n  never_modify:");
fs.writeFileSync("backbone.yml", t);
'
GIT_AUTHOR_DATE="2023-01-01T00:00:00Z" GIT_COMMITTER_DATE="2023-01-01T00:00:00Z" git add -A
GIT_AUTHOR_DATE="2023-01-01T00:00:00Z" GIT_COMMITTER_DATE="2023-01-01T00:00:00Z" git commit -qm generated
echo 'export const fresh = 1' > apps/api/src/fresh.ts
commit_all recent
run_audit
expect_no_line 'package "generated" .*has no commit since' "a path the topology marks generated is exempt from liveness"
expect_no_line 'package "generated" .*has no inbound references' "generated code is not reported as unimported"

# A unit outside every workspace glob is not built by the package manager.
build_fixture
mkdir -p "$REPO/tools/cli"
echo '{ "name": "@fx/cli" }' > "$REPO/tools/cli/package.json"
node -e '
const fs = require("fs");
let t = fs.readFileSync(process.argv[1] + "/backbone.yml", "utf8");
t = t.replace("packages:\n  uikit:", "packages:\n  cli:\n    path: tools/cli\n    package: \"@fx/cli\"\n  uikit:");
fs.writeFileSync(process.argv[1] + "/backbone.yml", t);
' "$REPO"
commit_all tools
run_audit
expect_line 'MEDIUM .*package "cli" \(tools/cli\) is outside every glob in pnpm-workspace.yaml' "a unit no workspace glob covers is signalled"

# The single-app template points at the repo root, which is the workspace root
# and never one of its own members.
build_fixture
cd "$REPO" || exit 1
rm -rf packages apps/web
cat > backbone.yml <<'YAML'
version: 1
project: fixture
package_manager: pnpm
workspace_config: pnpm-workspace.yaml

app:
  name: root
  path: .
  entry: package.json

commands:
  dev: "pnpm dev"
  test: "pnpm test"

root_config:
  typescript: tsconfig.json
YAML
commit_all single
run_audit
expect_line 'apps/packages: +1' "the single-app template registers its one unit"
expect_no_line 'is outside every glob' "the repo root is not reported as outside the workspace"

# ═══ pass 5: the parser contract — accept the shape, refuse to guess ══════════

# A sequence at its key's own indent is legal YAML and common. Reading it as a
# sibling replaced the GRANDPARENT map, which silently deleted boundaries: and
# audit.ignore along with it.
build_fixture
node -e '
const fs = require("fs"), p = process.argv[1] + "/backbone.yml";
fs.writeFileSync(p, fs.readFileSync(p, "utf8")
  .replace("    used_by: [apps/web]", "    used_by:\n    - apps/web")
  .replace("  never_modify:\n    - .env\n    - \"**/node_modules/\"", "  never_modify:\n  - .env\n  - \"**/node_modules/\""));
' "$REPO"
run_audit
expect_exit 0 "a sequence at its key's own indent parses correctly"
expect_no_line 'has no fields' "a same-indent sequence does not destroy its grandparent map"

build_fixture
mkdir -p "$REPO/packages/newpkg"
echo '{ "name": "@fx/newpkg" }' > "$REPO/packages/newpkg/package.json"
cat > "$REPO/pnpm-workspace.yaml" <<'YAML'
packages:
- "apps/*"
- "packages/*"
YAML
run_audit
expect_line 'HIGH .*workspace member "packages/newpkg"' "a flush-left pnpm-workspace.yaml is still read"

refuse() {          # refuse <description> <yaml-tail>
  build_fixture
  printf '%s' "$2" >> "$REPO/backbone.yml"
  run_audit
  expect_exit 3 "$1 aborts the audit"
  expect_line 'audit ABORTED' "$1 says the run was abandoned"
  expect_no_line 'No issues' "$1 never reports a clean result"
}

refuse "a block scalar" '
notes: |
  schema: legacy/old.prisma
  kept for reference
'
# Every body line here is shaped like a key, so nothing downstream objects: the
# block-scalar guard is the only thing standing between this and two invented
# top-level keys.
refuse "a block scalar whose body parses as keys" '
notes: |
  first: one
  second: two
'
refuse "a YAML anchor" '
anchored:
  path: &apath apps/api
'
refuse "a flow mapping" '
extra: {a: 1, b: 2}
'
refuse "a duplicate top-level key" '
commands:
  build: "pnpm build"
'
refuse "a merge key" '
merged:
  <<: *apath
'

build_fixture
printf 'version: 1\napps:\n\tapi:\n' > "$REPO/backbone.yml"
run_audit
expect_exit 3 "tab indentation aborts the audit"
expect_line 'tab indentation' "the refusal names the construct"
expect_line 'backbone.yml:3' "the refusal names the line"

build_fixture
: > "$REPO/backbone.yml"
run_audit
expect_exit 3 "an empty topology file aborts"
expect_line 'is empty' "an empty topology file is named as the reason"

# ═══ pass 6: a check that cannot run must never read as clean ═════════════════

build_fixture
rm "$REPO/pnpm-workspace.yaml"
node -e '
const fs = require("fs"), p = process.argv[1] + "/package.json";
const m = JSON.parse(fs.readFileSync(p, "utf8")); delete m.workspaces;
fs.writeFileSync(p, JSON.stringify(m, null, 2));
' "$REPO"
edit_backbone '/^workspace_config:/d'
mkdir -p "$REPO/packages/newpkg"
echo '{ "name": "@fx/newpkg" }' > "$REPO/packages/newpkg/package.json"
run_audit
expect_line 'NOT CHECKED' "a sweep with no input announces itself"
expect_line 'no workspace globs found' "the reason names what was missing"
expect_line 'lerna, nx, rush' "the reason names the layouts that go unenumerated"
expect_no_line 'No issues at or above severity low' "a run with an unrun check does not print the unqualified clean line"
expect_line 'did not run — see NOT CHECKED above before calling this clean' "the clean line is qualified by what was skipped"

build_fixture
rm -rf "$REPO/.git"
run_audit
expect_line 'liveness sweep: +DID NOT RUN' "a non-git repo cannot run the liveness sweep"
expect_line 'not a git repository' "the reason is stated"

build_fixture
cd "$REPO" || exit 1
echo 'export const second = 1' > apps/api/src/second.ts
commit_all second
SHALLOW="$ROOT/shallow"
rm -rf "$SHALLOW"
git clone -q --depth=1 "file://$REPO" "$SHALLOW" 2>/dev/null
FULL_REPO="$REPO"
REPO="$SHALLOW"
run_audit
expect_line 'liveness sweep: +DID NOT RUN' "a shallow clone cannot run the liveness sweep"
expect_line 'shallow clone' "the reason names the shallow clone"
expect_no_line 'No issues at or above severity low' "a shallow clone does not report an unqualified clean result"
REPO="$FULL_REPO"

build_fixture
cd "$REPO" || exit 1
echo 'import "@fx/uikit"' > apps/web/src/untracked.ts
run_audit
expect_line 'untracked file' "untracked files are announced, because git grep cannot see them"

build_fixture
edit_backbone 's|  dev: "pnpm dev"|  dev: "pnpm --filter web dev"|'
run_audit
expect_line 'is not of the form <package-manager> <script>' "a command shape that cannot be resolved is announced, not guessed at"
expect_no_line 'HIGH .*commands.dev' "an unresolvable command is not reported as broken"

# ═══ pass 7: flags ═══════════════════════════════════════════════════════════

build_fixture
edit_backbone 's|  test: "pnpm test"|  typecheck: "pnpm typecheck"|'
touch "$REPO/docker-compose.yml"
run_audit
expect_line 'LOW .*docker-compose.yml' "the fixture produces both a HIGH and a LOW finding"
expect_line 'HIGH .*commands.typecheck' "the HIGH finding is present unfiltered"

run_audit --severity=high
expect_no_line 'LOW .*docker-compose.yml' "--severity hides findings below the threshold"
expect_line 'HIGH .*commands.typecheck' "--severity keeps findings at the threshold"
expect_line 'shown: +1 of [0-9]+' "the report says how many findings were hidden"

# A display filter must never turn a failing run into a passing one.
run_audit --severity=critical
expect_exit 1 "--severity=critical still exits 1 when a HIGH finding exists"
expect_line 'exit code still reflects all' "the report says the exit code ignores the filter"

build_fixture
mkdir -p "$REPO/packages/newpkg"
echo '{ "name": "@fx/newpkg" }' > "$REPO/packages/newpkg/package.json"
edit_backbone 's|"@fx/api"|"@fx/api-renamed"|'
run_audit
expect_line 'apps/packages: +3' "all units are audited without --only"
expect_line 'claims package "@fx/api-renamed"' "the api finding is present without --only"

run_audit --only=uikit
expect_line 'apps/packages: +1 \(--only=uikit\)' "--only narrows the unit list"
expect_no_line 'claims package "@fx/api-renamed"' "--only excludes other units' findings"
expect_no_line 'workspace member' "--only skips the project-wide sweeps"

run_audit --only=nosuchunit
expect_exit 3 "--only naming nothing is an error, not an empty pass"

build_fixture
cp "$REPO/backbone.yml" "$REPO/other.yml"
edit_backbone 's|"@fx/api"|"@fx/api-renamed"|'
run_audit --file=other.yml
expect_no_line 'claims package "@fx/api-renamed"' "--file audits the named file, not the one in .myspec.json"
expect_line 'topology file: +other.yml' "the report names the file that was audited"

run_audit "--file=$REPO/other.yml"
expect_exit 0 "--file accepts an absolute path"

run_audit --file=nosuch.yml
expect_exit 3 "--file naming a missing file is an error"
expect_line 'file=nosuch.yml does not exist' "the error names the flag's value, not .myspec.json"

run_audit --stale-days=abc
expect_exit 3 "a non-numeric --stale-days is rejected rather than silently disabling the sweep"

run_audit --severity=bogus
expect_exit 3 "an unknown severity is rejected"

# --json must survive a pipe: process.stdout.write is async on a pipe, and a
# large report was silently cut at the 64 KB buffer, yielding invalid JSON.
build_fixture
cd "$REPO" || exit 1
for i in $(seq 1 200); do
  mkdir -p "packages/p$i" && echo "{ \"name\": \"@fx/p$i\" }" > "packages/p$i/package.json"
done
OUTPUT=$(node "$SCRIPT" --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log("VALID "+j.issues.length)}catch(e){console.log("INVALID")}})' 2>&1)
expect_line '^VALID [0-9]{3}' "--json survives a pipe on a report larger than the pipe buffer"

run_audit --json
expect_line '"kind": "workspace-member-unlisted"' "--json carries the check id"
expect_line '"notChecked"' "--json carries the checks that did not run"

build_fixture
rm "$REPO/backbone.yml"
run_audit --json
expect_exit 3 "a missing topology file exits 3 under --json"
expect_line '"error"' "--json emits a parseable object even when the audit cannot run"

# ═══ pass 8: the ignore list ═════════════════════════════════════════════════

build_fixture
mkdir -p "$REPO/packages/newpkg"
echo '{ "name": "@fx/newpkg" }' > "$REPO/packages/newpkg/package.json"
edit_backbone 's|  ignore: \[\]|  ignore:\n    - packages/newpkg|'
run_audit
expect_exit 0 "an ignored path drops out of the audit entirely"
expect_no_line 'packages/newpkg' "audit.ignore silences a deliberate omission"

build_fixture
edit_backbone 's|  ignore: \[\]|  ignore:\n    - packages/removed-long-ago|'
run_audit
expect_line 'LOW .*audit.ignore lists "packages/removed-long-ago", which matches nothing' "an ignore entry matching nothing is reported — it mutes anything created there later"

build_fixture
edit_backbone 's|  stale_days: 365|  stale_days: 9999|'
run_audit
expect_line 'stale after 9999 days' "audit.stale_days is read from the topology file"

# ═══ report ══════════════════════════════════════════════════════════════════

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
