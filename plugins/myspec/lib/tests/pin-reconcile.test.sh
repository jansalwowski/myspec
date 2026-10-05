#!/usr/bin/env bash
# Tests for lib/pin-reconcile.mjs (#160, #265): the three-way verdict per pin
# that replaced update's `wc -c` size compare.
#
# The two new-sporticos-frontend pins #160 reported, as this fixture plays
# them: a stale pin (rules/ideas.md, pinned "gated with paths" while the
# upstream copy was ungated; upstream is path-gated now, so the file equals
# the plugin copy) and a pin whose local fix was upstreamed (the project's
# copy equals the plugin's). Both are `drop`. The sizes update compared could
# tell neither: a path-gated rule is the same size pinned or not.
#
# Usage: pin-reconcile.test.sh [plugin-root]

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_PLUGIN="${1:-$(cd "$HERE/../.." && pwd)}"
SCRIPT="$REAL_PLUGIN/lib/pin-reconcile.mjs"

ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

# A plugin of its own: the real reader beside the script, a small manifest
# and framework files the cases below move.
PLUGIN="$ROOT/plugin"
mkdir -p "$PLUGIN/lib" "$PLUGIN/framework-files/rules" "$PLUGIN/framework-files/templates"
cp "$SCRIPT" "$REAL_PLUGIN/lib/myspec-config.mjs" "$REAL_PLUGIN/lib/myspec-config.schema.json" "$PLUGIN/lib/"
cat > "$PLUGIN/framework-files/manifest.json" <<'EOF'
{
  "frameworkVersion": "3.0.0",
  "migrations": ["3.0.0-schema-v2"],
  "files": {
    "pre-flight.md": { "type": "marker-merge" },
    "work-isolation.md": { "type": "overwrite" },
    "templates/session-log.md": { "type": "overwrite" }
  },
  "rules": {
    "ideas.md": { "type": "overwrite", "dest": ".claude/rules/ideas.md" },
    "workflow.md": { "type": "overwrite", "dest": ".claude/rules/workflow.md" }
  },
  "removed": {
    "memory-system.md": { "dest": "${aiDir}/memory-system.md", "since": "2.0.0" }
  }
}
EOF
# shellcheck disable=SC2016 # a literal ${aiDir} placeholder, as the plugin files carry it
printf -- '---\ntitle: Ideas\npaths:\n  - ${aiDir}/ideas/**\n---\n# Ideas\n\nRead ${aiDir}/ideas/PRIORITY-LISTING.md first.\n' > "$PLUGIN/framework-files/rules/ideas.md"
# shellcheck disable=SC2016
printf -- '---\ntitle: Workflow\n---\n# Workflow\n\nSpecs live in ${aiDir}/features/.\n' > "$PLUGIN/framework-files/rules/workflow.md"
# shellcheck disable=SC2016
printf -- '---\ntitle: Pre-flight\n---\n# Pre-flight\n\n<!-- myspec:framework-start -->\n- [ ] Read ${aiDir}/memory/index.md\n<!-- myspec:framework-end -->\n\n## Project checks\n' > "$PLUGIN/framework-files/pre-flight.md"
printf -- '# Work isolation\n\nWorktrees live under .claude/worktrees/.\n' > "$PLUGIN/framework-files/work-isolation.md"
printf -- '# Session {date}\n' > "$PLUGIN/framework-files/templates/session-log.md"

# project <aiDir> -> a fresh checkout with the plugin's files installed
# (${aiDir} substituted), no pins yet.
REPO=""
project() {
  REPO="$ROOT/proj-$RANDOM"
  mkdir -p "$REPO/.claude/rules" "$REPO/$1/.templates"
  git init -q -b main "$REPO"
  sed "s#\${aiDir}#$1#g" "$PLUGIN/framework-files/rules/ideas.md" > "$REPO/.claude/rules/ideas.md"
  sed "s#\${aiDir}#$1#g" "$PLUGIN/framework-files/rules/workflow.md" > "$REPO/.claude/rules/workflow.md"
  sed "s#\${aiDir}#$1#g" "$PLUGIN/framework-files/pre-flight.md" > "$REPO/$1/pre-flight.md"
  cp "$PLUGIN/framework-files/work-isolation.md" "$REPO/$1/work-isolation.md"
  cp "$PLUGIN/framework-files/templates/session-log.md" "$REPO/$1/.templates/session-log.md"
  printf '{\n  "aiDir": "%s",\n  "frameworkVersion": "2.11.0",\n  "frameworkFiles": {}\n}\n' "$1" > "$REPO/.myspec.json"
}

# pin <key> <reason> [hash] [upstreamHash]
pin() {
  node -e '
const fs = require("fs"); const [p, key, reason, hash, up] = process.argv.slice(1);
const d = JSON.parse(fs.readFileSync(p, "utf8")); d.frameworkFiles ??= {};
d.frameworkFiles[key] = { pinned: reason }; if (hash) d.frameworkFiles[key].hash = hash; if (up) d.frameworkFiles[key].upstreamHash = up;
fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");' "$REPO/.myspec.json" "$@"
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
field() { node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const v=d.frameworkFiles[process.argv[2]][process.argv[3]]; process.stdout.write(v === undefined ? "" : String(v))' "$REPO/.myspec.json" "$1" "$2"; }

run() {  # run [args...] -> OUT, ERR, RC
  OUT=$(node "$PLUGIN/lib/pin-reconcile.mjs" --root "$REPO" --plugin-root "$PLUGIN" "$@" 2>"$ROOT/err"); RC=$?
  ERR=$(cat "$ROOT/err")
}
verdict() {  # verdict <key> -> the verdict column of that row
  printf '%s\n' "$OUT" | awk -F'\t' -v k="$1" '$1 == k { print $2 }'
}
expect_verdict() {  # expect_verdict <key> <want> <desc>
  local got
  got=$(verdict "$1")
  if [ "$got" = "$2" ]; then ok; else fail "$3: $1 is '$got', want '$2'"$'\n'"$OUT"$'\n'"$ERR"; fi
}

# --- the #160 cases: both drop --------------------------------------------------
project .ai
pin rules/ideas.md "gated with paths: .ai/ideas/**; the upstream copy is ungated and always-loaded"
pin pre-flight.md "local fix: the session-age tiering line"
printf '\n- project check\n' >> "$REPO/.ai/pre-flight.md"
run
[ "$RC" -eq 0 ] && ok || fail "the report exits 0 (rc=$RC: $ERR)"
expect_verdict rules/ideas.md drop "a stale pin whose upstream is now path-gated (the file equals the plugin copy)"
expect_verdict pre-flight.md drop "a pin whose fix was upstreamed on a marker-merge file (the framework region equals the plugin copy; the project section differs)"
printf '%s\n' "$OUT" | grep -q 'pinned: gated with paths' && ok || fail "the detail column carries the pin reason"
printf '%s\n' "$OUT" | head -1 | grep -qE '^key\s+verdict\s+detail$' && ok || fail "the table has a header row"

# --- unrecorded, backfill, review, keep ---------------------------------------
project .ai
printf '\nProject rule: never skip the listing.\n' >> "$REPO/.claude/rules/ideas.md"
pin rules/ideas.md "project rule appended"
run
expect_verdict rules/ideas.md unrecorded "a pin without hashes is unrecorded"
run --backfill
expect_verdict rules/ideas.md keep "after --backfill the verdict is keep"
printf '%s\n' "$OUT" | grep -q 'recorded hash and upstreamHash now' && ok || fail "--backfill says what it recorded"
[ "$(field rules/ideas.md hash)" = "$(sha "$REPO/.claude/rules/ideas.md")" ] && ok || fail "--backfill records the project file's sha256"
# shellcheck disable=SC2016 # the literal placeholder is what sed replaces
[ "$(field rules/ideas.md upstreamHash)" = "$(sed 's#${aiDir}#.ai#g' "$PLUGIN/framework-files/rules/ideas.md" | shasum -a 256 | cut -d' ' -f1)" ] && ok \
  || fail "--backfill records the rendered plugin copy's sha256 (\${aiDir} substituted)"
[ "$(field rules/ideas.md pinned)" = "project rule appended" ] && ok || fail "--backfill keeps the pin reason"
grep -q '^  "aiDir"' "$REPO/.myspec.json" && ok || fail "--backfill keeps the file's indentation"
run
expect_verdict rules/ideas.md keep "nothing moved on either side: keep"

# Upstream moves under the pin: review. The project then keeps it and
# re-records, which silences the review until upstream moves again.
cp "$PLUGIN/framework-files/rules/ideas.md" "$ROOT/ideas.orig"
printf '\nUpstream addition since the pin.\n' >> "$PLUGIN/framework-files/rules/ideas.md"
run
expect_verdict rules/ideas.md review "upstream moved under an unchanged pin: review"
run --record rules/ideas.md
expect_verdict rules/ideas.md keep "--record on a reviewed pin re-records it"
run
expect_verdict rules/ideas.md keep "a re-recorded pin stays keep until upstream moves again"

# The project changes the file after the pin: keep, whatever upstream did.
printf '\nAnother project line.\n' >> "$REPO/.claude/rules/ideas.md"
printf '\nMore upstream.\n' >> "$PLUGIN/framework-files/rules/ideas.md"
run
expect_verdict rules/ideas.md keep "the project changed the file since the pin: keep"
cp "$ROOT/ideas.orig" "$PLUGIN/framework-files/rules/ideas.md"

# A pin backfilled with hash only (a hand-written one) cannot tell an upstream
# move: keep, with the reason in the detail.
project .ai
printf '\nlocal\n' >> "$REPO/.claude/rules/workflow.md"
pin rules/workflow.md "local" "$(sha "$REPO/.claude/rules/workflow.md")"
printf '\nupstream moved\n' >> "$PLUGIN/framework-files/rules/workflow.md"
run
expect_verdict rules/workflow.md keep "hash without upstreamHash cannot report review"
printf '%s\n' "$OUT" | grep -q 'no upstreamHash' && ok || fail "the detail says why review cannot be told"
# shellcheck disable=SC2016
printf -- '---\ntitle: Workflow\n---\n# Workflow\n\nSpecs live in ${aiDir}/features/.\n' > "$PLUGIN/framework-files/rules/workflow.md"

# --- missing, retired, unknown, and a non-default aiDir -----------------------
project docs/ai
pin templates/session-log.md "trimmed"
pin work-isolation.md "custom procedure"
pin memory-system.md "kept the 1.x file"
pin lib/memory-files.mjs "local lint fix"
pin rules/no-such.md "typo"
rm "$REPO/docs/ai/.templates/session-log.md"
printf '\nOur worktrees live elsewhere.\n' >> "$REPO/docs/ai/work-isolation.md"
run
expect_verdict templates/session-log.md missing "a pinned file that is gone is missing"
expect_verdict work-isolation.md unrecorded "a files entry under a non-default aiDir is found"
expect_verdict memory-system.md retired "a removed manifest entry is retired"
expect_verdict lib/memory-files.mjs retired "a lib copy pin is retired (the 3.0.0-plugin-hooks migration drops it)"
expect_verdict rules/no-such.md unknown "a key with no manifest entry is unknown"
run --backfill
expect_verdict work-isolation.md keep "--backfill records the pin it can"
[ -z "$(field templates/session-log.md hash)" ] && ok || fail "--backfill records nothing for a missing file"
[ -z "$(field lib/memory-files.mjs hash)" ] && ok || fail "--backfill records nothing for a retired pin"
printf '\nOur worktrees live elsewhere.\n' >> "$REPO/docs/ai/work-isolation.md"
run --json
printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0,"utf8")); const w=r.find((x)=>x.key==="work-isolation.md"); process.exit(w && w.verdict==="keep" && /^[0-9a-f]{64}$/.test(w.hashes.file) ? 0 : 1)' && ok \
  || fail "--json carries key, verdict and hashes"

# A files entry whose rendered copy equals the project's under docs/ai: drop
# only after ${aiDir} substitution (the raw plugin text never matches).
project docs/ai
pin rules/ideas.md "stale"
run
expect_verdict rules/ideas.md drop "drop compares the plugin copy with \${aiDir} substituted"

# --- no pins, usage, help ---------------------------------------------------------
project .ai
run
[ "$OUT" = "no pins in .myspec.json frameworkFiles" ] && ok || fail "no pins is said in one line (got: $OUT)"
run --record rules/ideas.md
[ "$RC" -eq 2 ] && ok || fail "--record of a key that is not a pin is a usage error (rc=$RC)"
run --bogus
[ "$RC" -eq 2 ] && ok || fail "an unknown flag is a usage error"
run --help
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^  review ' && printf '%s\n' "$OUT" | grep -q 'Table:' && ok \
  || fail "--help prints the table format and the verdicts"
# A .myspec.json that is not a JSON object cannot say what is pinned: an
# error, not "no pins", or the 3.0.0-schema-v2 migration would record a
# backfill that recorded nothing.
printf '{\n  "aiDir": ".ai",\n  "frameworkFiles": {"rules/ideas.md": {"pinned": "x"}},\n}\n' > "$REPO/.myspec.json"
run --backfill
[ "$RC" -eq 2 ] && ok || fail "an unparseable .myspec.json exits 2 (rc=$RC: $OUT)"
[ -z "$OUT" ] && ok || fail "an unparseable .myspec.json prints no table (got: $OUT)"
printf '[]\n' > "$REPO/.myspec.json"
run
[ "$RC" -eq 2 ] && ok || fail "a .myspec.json that is an array exits 2 (rc=$RC)"
rm "$REPO/.myspec.json"
run
[ "$RC" -eq 2 ] && ok || fail "no .myspec.json is an error (rc=$RC)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
