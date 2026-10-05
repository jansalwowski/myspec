#!/usr/bin/env bash
# Tests for the settings reader (docs/project-settings-design.md, rollout
# step 1): lib/myspec-config.sh, lib/myspec-config.mjs and their schema.
#
#   1. Semantics. Each case runs both readers on the same fixture and asserts
#      the value, and that the two print the same stdout and stderr: hooks
#      use the shell reader and lib scripts the Node one, so a drift between
#      them is a setting that means two things.
#   2. Catalogue. Every key in the design's catalogue tables has a schema
#      entry with the same type, default and issue, and every schema key not
#      marked "catalogue": false is in a table. A key added without a schema
#      entry fails here (principle 7).
#   3. Scripts. Every MYSPEC_* variable a hook or lib script reads or exports,
#      and every .myspec.json key a shell script reads with jq, has a schema
#      entry.
#
# Usage: myspec-config.test.sh [plugin-root]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN="${1:-$(cd "$HERE/../.." && pwd)}"
SH="$PLUGIN/lib/myspec-config.sh"
MJS="$PLUGIN/lib/myspec-config.mjs"
SCHEMA="$PLUGIN/lib/myspec-config.schema.json"
DOC="$PLUGIN/docs/project-settings-design.md"

# Hooks and docs run the shell reader directly, so it must be executable.
[ -x "$SH" ] || { echo "FATAL: script not executable: $SH" >&2; exit 1; }

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# fixture <name> [myspec-json] [verification-json] -> a checkout with those files
fixture() {
  local d="$ROOT/$1"
  mkdir -p "$d/.claude"
  git init -q "$d"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$d/.myspec.json"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$d/.claude/verification.json"
  printf '%s\n' "$d"
}

# read_both <dir> <key> [env...] -> sets OUT, ERR from the shell reader and
# fails when the Node reader prints anything different.
read_both() {
  local dir="$1" key="$2"
  shift 2
  OUT=$(env "$@" bash "$SH" get "$key" --root "$dir" 2>"$ROOT/err-sh")
  ERR=$(cat "$ROOT/err-sh")
  local out_js err_js
  out_js=$(env "$@" node "$MJS" get "$key" --root "$dir" 2>"$ROOT/err-js")
  err_js=$(cat "$ROOT/err-js")
  [ "$OUT" = "$out_js" ] && [ "$ERR" = "$err_js" ] && ok \
    || fail "parity on $key in $(basename "$dir"): sh=[$OUT|$ERR] node=[$out_js|$err_js]"
}

# expect <desc> <expected-json> -> compares OUT as JSON
expect() {
  if [ "$(printf '%s' "$OUT" | jq -cS . 2>/dev/null)" = "$(printf '%s' "$2" | jq -cS .)" ]; then ok
  else fail "$1: got $OUT, want $2"; fi
}

# --- 1. semantics -------------------------------------------------------------

# No files: every key is its schema default, and a key with none is null.
D=$(fixture empty)
read_both "$D" isolation.provision.symlink; expect "default symlink" '["node_modules"]'
[ -z "$ERR" ] && ok || fail "no settings prints no warning (got: $ERR)"
read_both "$D" isolation.provision.install; expect "install has no default" 'null'
read_both "$D" isolation.worktreeRoot; expect "default worktreeRoot" '".claude/worktrees"'
read_both "$D" verification.checks; expect "no verification.json" 'null'
read_both "$D" no.such.key; expect "unknown key" 'null'

# Schema v2 (#265): the version is the contract, declared in the design doc.
[ "$(jq -r '.version' "$SCHEMA")" = 2 ] && ok || fail "the schema is version 2"
grep -qE '^\| 2 \| 3\.0\.0 \|' "$DOC" && ok || fail "the design doc's Schema version table lists version 2"
read_both "$D" orchestration.featureImplement; expect "default featureImplement" '"controller"'
read_both "$D" probes.portSource; expect "portSource has no default" 'null'
read_both "$D" mockups; expect "mockups has no default" 'null'
read_both "$D" project.description; expect "project.description is no key" 'null'

# A map typed through a `*` entry (frameworkFiles.*.pinned) comes back whole:
# the readers never look inside a map, as they never look inside a list.
D=$(fixture pins '{"frameworkFiles":{"rules/ideas.md":{"pinned":"gated","hash":"abc"},"pre-flight.md":{"pinned":7}},"mockups":{"extension":".vue","siblingRoots":["src"]}}')
read_both "$D" frameworkFiles; expect "pins pass through the readers whole" '{"rules/ideas.md":{"pinned":"gated","hash":"abc"},"pre-flight.md":{"pinned":7}}'
[ -z "$ERR" ] && ok || fail "a mistyped pin field is doctor's finding, not the readers' (got: $ERR)"
read_both "$D" mockups.siblingRoots; expect "mockups.siblingRoots is read" '["src"]'

# The guard's default list (#250), as the schema holds it.
BLOCK_DEFAULT=$(jq -c '.keys["isolation.blockInMain"].default' "$SCHEMA")
[ "$(jq 'length' <<< "$BLOCK_DEFAULT")" -gt 0 ] && ok || fail "blockInMain has a non-empty default"

# Objects merge key by key: a project value replaces one leaf, defaults keep the rest.
D=$(fixture objects '{"isolation":{"worktreeRoot":"wt","provision":{"clean":["**/*.tsbuildinfo"]}},"custom":{"a":1}}')
read_both "$D" isolation
expect "object merge" '{"blockInMain":'"$BLOCK_DEFAULT"',"ignoreBlockInMain":[],"allowLinkedModules":false,"worktreeRoot":"wt","provision":{"symlink":["node_modules"],"copy":[".eslintcache"],"clean":["**/*.tsbuildinfo"]}}'
read_both "$D" custom.a; expect "unknown keys pass through" '1'

# A replace list (existing keys, principle 2) drops the default; an extend list keeps it.
D=$(fixture lists '{"isolation":{"provision":{"symlink":["vendor"],"copy":[".mypy_cache"]},"blockInMain":["^make( |$)"]}}')
read_both "$D" isolation.provision.symlink; expect "symlink replaces the default" '["vendor"]'
read_both "$D" isolation.provision.copy; expect "copy replaces the default" '[".mypy_cache"]'
read_both "$D" isolation.blockInMain; expect "blockInMain extends its default" "$(jq -c '. + ["^make( |$)"]' <<< "$BLOCK_DEFAULT")"

# A wrong-typed value falls back to the default and is named on stderr.
D=$(fixture wrongtype '{"aiDir":3,"isolation":{"allowLinkedModules":"yes","provision":{"symlink":"vendor","install":{"run":"x"}}}}')
read_both "$D" aiDir; expect "wrong-typed aiDir" '".ai"'
printf '%s' "$ERR" | grep -qF "ignoring aiDir in .myspec.json: expected string, got number" && ok \
  || fail "wrong-typed aiDir is named on stderr (got: $ERR)"
read_both "$D" isolation.allowLinkedModules; expect "wrong-typed allowLinkedModules fails closed" 'false'
read_both "$D" isolation.provision.symlink; expect "wrong-typed symlink" '["node_modules"]'
printf '%s' "$ERR" | grep -qF "isolation.provision.symlink" && ok || fail "wrong-typed symlink is named"
read_both "$D" isolation.provision.install; expect "wrong-typed install" 'null'
printf '%s' "$ERR" | grep -qF "ignoring isolation.provision.install in .myspec.json: expected string or array, got object" && ok \
  || fail "wrong-typed install is named (got: $ERR)"
# Only keys at, above or below the requested one are named.
read_both "$D" topologyFile
[ -z "$ERR" ] && ok || fail "an unrelated key names no other key (got: $ERR)"
read_both "$D" isolation.worktreeRoot
printf '%s' "$ERR" | grep -qF "aiDir" && fail "isolation.worktreeRoot does not name aiDir" || ok
read_both "$D" isolation.provision
printf '%s' "$ERR" | grep -qF "isolation.provision.symlink" && printf '%s' "$ERR" | grep -qF "isolation.provision.install" && ok \
  || fail "a parent key names the bad keys under it (got: $ERR)"

# A non-object where the schema expects an object.
D=$(fixture intermediate '{"isolation":"worktree"}')
read_both "$D" isolation.worktreeRoot; expect "non-object isolation" '".claude/worktrees"'
printf '%s' "$ERR" | grep -qF "ignoring isolation in .myspec.json: expected an object, got string" && ok \
  || fail "non-object isolation is named (got: $ERR)"

# An unreadable file is ignored whole and named; the other file is still read.
D=$(fixture badjson '{"isolation": ' '{"checks":[{"name":"Lint","command":"make lint","required":true}]}')
read_both "$D" isolation.worktreeRoot; expect "bad .myspec.json" '".claude/worktrees"'
printf '%s' "$ERR" | grep -qF ".myspec.json is not a JSON object; isolation.worktreeRoot falls back to the default" && ok \
  || fail "bad .myspec.json is named with the key (got: $ERR)"
read_both "$D" verification.checks; expect "verification.json still read" '[{"name":"Lint","command":"make lint","required":true}]'
[ -z "$ERR" ] && ok || fail "a verification key does not name the bad .myspec.json (got: $ERR)"
D=$(fixture badverify '{"aiDir":"docs"}' '[1]')
read_both "$D" verification.checks; expect "array verification.json" 'null'
printf '%s' "$ERR" | grep -qF ".claude/verification.json is not a JSON object" && ok || fail "array verification.json is named"
read_both "$D" aiDir; expect "aiDir read beside a bad verification.json" '"docs"'

# A file that exists but cannot be read falls back like a bad one, in both
# readers, instead of aborting the shell reader (skipped as root, who reads it).
D=$(fixture unreadable '{"aiDir":"docs"}')
chmod 000 "$D/.myspec.json"
if [ ! -r "$D/.myspec.json" ]; then
  read_both "$D" aiDir; expect "unreadable .myspec.json" '".ai"'
  printf '%s' "$ERR" | grep -qF ".myspec.json is not a JSON object; aiDir falls back to the default" && ok \
    || fail "unreadable .myspec.json is named (got: $ERR)"
  bash "$SH" get aiDir --root "$D" >/dev/null 2>&1; [ $? -eq 0 ] && ok || fail "sh: an unreadable file exits 0"
fi
chmod 644 "$D/.myspec.json"

# The session layer wins over the project layer, and only on its exact value.
D=$(fixture session '{"isolation":{"allowLinkedModules":false},"feedback":{"metrics":true}}')
read_both "$D" isolation.allowLinkedModules MYSPEC_ALLOW_LINKED_MODULES=1; expect "session override" 'true'
read_both "$D" isolation.allowLinkedModules MYSPEC_ALLOW_LINKED_MODULES=yes; expect "session override needs 1" 'false'
read_both "$D" feedback.metrics MYSPEC_DISABLE_METRICS=1; expect "MYSPEC_DISABLE_METRICS" 'false'
read_both "$D" feedback.metrics DO_NOT_TRACK=0; expect "DO_NOT_TRACK=0 keeps metrics" 'true'
read_both "$D" feedback.metrics DO_NOT_TRACK=true; expect "DO_NOT_TRACK=true stops metrics" 'false'
read_both "$D" feedback.metrics DO_NOT_TRACK=false; expect "DO_NOT_TRACK=false keeps metrics" 'true'
read_both "$D" feedback.metrics DO_NOT_TRACK=FALSE; expect "DO_NOT_TRACK=FALSE keeps metrics" 'true'
# The schema's DO_NOT_TRACK rule is the metrics hook's rule: run the hook's own
# case line on each value and compare with the reader.
# shellcheck disable=SC2016 # a literal ${DO_NOT_TRACK in the pattern
HOOK_CASE=$(grep -m1 '^case "${DO_NOT_TRACK' "$PLUGIN/hooks/record-session-metrics.sh")
[ -n "$HOOK_CASE" ] && ok || fail "the metrics hook has a DO_NOT_TRACK case line"
D=$(fixture dnt)
for v in '' 0 false FALSE 1 true yes False off; do
  hook=$(DO_NOT_TRACK="$v" bash -c "$HOOK_CASE; echo true" 2>/dev/null)
  read_both "$D" feedback.metrics DO_NOT_TRACK="$v"; expect "DO_NOT_TRACK='$v' as the hook decides" "${hook:-false}"
done
read_both "$D" feedback MYSPEC_DISABLE_FRICTION_REPORT=1; expect "session merges into an object" '{"metrics":true,"frictionReport":false}'

# --root defaults to the top of the current checkout.
D=$(fixture toplevel '{"aiDir":"docs/ai"}')
mkdir -p "$D/src/deep"
OUT=$(cd "$D/src/deep" && bash "$SH" get aiDir 2>/dev/null)
expect "sh: --root defaults to the checkout top" '"docs/ai"'
OUT=$(cd "$D/src/deep" && node "$MJS" get aiDir 2>/dev/null)
expect "node: --root defaults to the checkout top" '"docs/ai"'

# The Node CLI runs when its path goes through a symlink (a symlinked plugin
# or .claude dir, or a temp dir such as macOS /tmp -> /private/tmp).
D=$(fixture symlinked '{"aiDir":"docs/ai"}')
ln -s "$(dirname "$MJS")" "$ROOT/linked-lib"
OUT=$(node "$ROOT/linked-lib/myspec-config.mjs" get aiDir --root "$D" 2>/dev/null)
expect "node: runs through a symlinked path" '"docs/ai"'

# Usage errors exit 2.
for args in "" "get" "set aiDir" "get .aiDir" "get a..b" "get aiDir --root"; do
  # shellcheck disable=SC2086 # word-split on purpose: each string is an argv
  bash "$SH" $args >/dev/null 2>&1; [ $? -eq 2 ] && ok || fail "sh: '$args' is a usage error"
  # shellcheck disable=SC2086
  node "$MJS" $args >/dev/null 2>&1; [ $? -eq 2 ] && ok || fail "node: '$args' is a usage error"
done

# Extend vs replace against a small known default: run copies of both readers
# beside a schema that gives blockInMain one.
ALT="$ROOT/alt"
mkdir -p "$ALT"
cp "$SH" "$MJS" "$ALT/"
jq '.keys["isolation.blockInMain"].default = ["^default"]' "$SCHEMA" > "$ALT/myspec-config.schema.json"
D=$(fixture extend '{"isolation":{"blockInMain":["^a","^default"],"provision":{"symlink":["vendor"]}}}')
for reader in "bash $ALT/myspec-config.sh" "node $ALT/myspec-config.mjs"; do
  # shellcheck disable=SC2086 # the reader string is a command and its script
  OUT=$($reader get isolation.blockInMain --root "$D" 2>/dev/null)
  expect "${reader%% *}: an extend list appends to the default, once each" '["^default","^a"]'
  # shellcheck disable=SC2086
  OUT=$($reader get isolation.provision.symlink --root "$D" 2>/dev/null)
  expect "${reader%% *}: a replace list drops the default" '["vendor"]'
done

# The layer list is ordered data: an extra layer slots in without a caller
# change, wins over the layers before it, and an extend list appends.
D=$(fixture layers '{"isolation":{"blockInMain":["^a"],"provision":{"symlink":["vendor"]}}}')
OUT=$(node --input-type=module -e "
  import { getSetting, LAYERS } from '$MJS';
  const machine = () => ({ name: 'machine', warnings: [],
    data: { isolation: { blockInMain: ['^b', '^a'], provision: { symlink: ['.venv'] } } } });
  const layers = [...LAYERS.slice(0, 2), machine, ...LAYERS.slice(2)];
  const r = (k) => getSetting(k, { root: '$D', env: {}, layers }).value;
  console.log(JSON.stringify([r('isolation.blockInMain'), r('isolation.provision.symlink')]));
")
expect "machine layer between project and session" "[$(jq -c '. + ["^a","^b"]' <<< "$BLOCK_DEFAULT"),[\".venv\"]]"
# shellcheck disable=SC2016 # a literal $LAYERS in the jq program
grep -qE '^\s*\[layer_default, layer_project, layer_session\] as \$LAYERS' "$SH" && ok \
  || fail "sh: the layers are one ordered list"

# --- 2. catalogue -------------------------------------------------------------
# --- 3. scripts ---------------------------------------------------------------

# Written to a file first: a quoted heredoc inside $( ) still trips bash's
# quote scanner on the apostrophes in the JS.
cat > "$ROOT/catalogue.mjs" <<'JS'
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const [schemaPath, docPath, plugin] = process.argv.slice(2);
const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
const doc = readFileSync(docPath, 'utf8');
const problems = [];
const same = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

// "### Provisioning a worktree: `.myspec.json` `isolation.provision`"
const sections = doc.split(/^### /m).slice(1);
const documented = new Set();
let rows = 0;
for (const section of sections) {
  const head = section.split('\n')[0].match(/: `([^`]+)`(?: `([^`]+)`)?\s*$/);
  if (!head) { continue; }
  const [, file, sub] = head;
  const prefix = file === schema.files.verification ? 'verification' : (sub ?? '');
  for (const line of section.split('\n')) {
    const cells = line.split('|').slice(1, -1).map((c) => c.trim());
    const key = cells[0]?.match(/^`([^`]+)`$/)?.[1];
    if (!key || cells.length < 4) { continue; }
    rows++;
    const full = prefix ? `${prefix}.${key}` : key;
    documented.add(full);
    const entry = schema.keys[full];
    if (!entry) { problems.push(`${full}: in the catalogue, not in the schema`); continue; }
    if (schema.files[entry.file] !== file) { problems.push(`${full}: catalogue file ${file}, schema file ${schema.files[entry.file]}`); }
    const t = cells[1].toLowerCase();
    const type = /^command, or list/.test(t) ? ['string', 'array'] : /^list/.test(t) ? ['array']
      : /^map/.test(t) ? ['object'] : /^bool/.test(t) ? ['boolean'] : ['string'];
    if (!same(type, entry.type)) { problems.push(`${full}: catalogue type ${type}, schema type ${entry.type}`); }
    const d = cells[2].match(/^`([^`]+)`$/)?.[1];
    let want;
    if (d !== undefined) { try { want = JSON.parse(d); } catch { want = d; } }
    // A default too long for a cell (a list of regexes) is "(see schema)":
    // the schema must then have one.
    if (/\(see schema\)/.test(cells[2])) {
      if (!Array.isArray(entry.default) || entry.default.length === 0) { problems.push(`${full}: catalogue says see schema, schema has no list default`); }
    } else if (JSON.stringify(want) !== JSON.stringify(entry.default)) {
      problems.push(`${full}: catalogue default ${JSON.stringify(want)}, schema default ${JSON.stringify(entry.default)}`);
    }
    const issue = [...new Set([...(cells[3].match(/#\d+/g) ?? []), ...(/\bexists\b/.test(cells[3]) ? ['exists'] : [])])];
    if (!same(issue, entry.issue)) { problems.push(`${full}: catalogue issue ${issue}, schema issue ${entry.issue}`); }
  }
}
if (rows < 10) { problems.push(`only ${rows} catalogue rows parsed; the table format changed`); }
for (const [key, entry] of Object.entries(schema.keys)) {
  if (entry.catalogue !== false && !documented.has(key)) { problems.push(`${key}: in the schema, not in the catalogue`); }
  for (const field of ['file', 'type', 'issue']) {
    if (!(field in entry)) { problems.push(`${key}: no ${field}`); }
  }
  if (entry.type?.includes('array') && entry.type.length === 1 && !key.includes('[]') && !entry.merge) {
    problems.push(`${key}: a list with no merge rule`);
  }
}
for (const name of new Set(doc.match(/\bMYSPEC_[A-Z_]+/g) ?? [])) {
  if (!schema.env[name]) { problems.push(`${name}: in the design doc, not in the schema env block`); }
}
for (const [name, entry] of Object.entries(schema.env)) {
  if (entry.kind === 'override' && !schema.keys[entry.key]) { problems.push(`${name}: overrides ${entry.key}, which has no schema entry`); }
}

// Scripts: hooks/*.sh and lib/**/*.{sh,mjs}, tests excluded.
const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) { if (name !== 'tests' && name !== 'node_modules') { walk(p); } }
    else if (/\.(sh|mjs)$/.test(name)) { files.push(p); }
  }
};
walk(join(plugin, 'hooks'));
walk(join(plugin, 'lib'));
const keyCovered = (k) => Object.keys(schema.keys).some((s) => s === k || s.startsWith(`${k}.`));
for (const f of files) {
  const text = readFileSync(f, 'utf8');
  const rel = f.slice(plugin.length + 1);
  // $MYSPEC_X, ${MYSPEC_X...}, env.MYSPEC_X, or an assignment MYSPEC_X=...
  for (const m of text.matchAll(/(?:\$\{?|env\.|\b(?=MYSPEC_[A-Z_]+=))(MYSPEC_[A-Z][A-Z_]*)/g)) {
    if (!schema.env[m[1]]) { problems.push(`${rel}: reads or sets ${m[1]}, which has no schema env entry`); }
  }
  if (!f.endsWith('.sh')) { continue; }
  for (const m of text.matchAll(/jq\s+(?:-[a-zA-Z]+\s+)*(['"])\(?\.([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)[^'"]*\1[^\n]*\.myspec\.json/g)) {
    if (!keyCovered(m[2])) { problems.push(`${rel}: reads .myspec.json key ${m[2]}, which has no schema entry`); }
  }
}
console.log(problems.length ? problems.join('\n') : `ok ${rows} rows`);
JS
CATALOGUE=$(node "$ROOT/catalogue.mjs" "$SCHEMA" "$DOC" "$PLUGIN" 2>&1)
case "$CATALOGUE" in
  "ok "*) ok ;;
  *) fail "catalogue, schema and scripts agree:"$'\n'"$CATALOGUE" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
