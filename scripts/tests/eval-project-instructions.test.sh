#!/usr/bin/env bash
# Project instructions in eval runs (evals/README.md, "Project instructions").
# `claude plugin eval` never loads a workspace's CLAUDE.md or .claude/rules/,
# so evals/_fixtures/project-instructions.sh writes each case's always-loaded
# instructions into its case.yaml as execution.append_system_prompt.
#
# Checks that every case's generated text is present and current with its
# fixture and framework-files/, matches an independent rendering, and that the
# generator catches a stale block, honours the description-only opt-out and
# refuses what it cannot handle. No model calls: a stub `claude` first on PATH
# fails the suite if anything invokes it.
#
# Usage: scripts/tests/eval-project-instructions.test.sh

set -uo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN=evals/_fixtures/project-instructions.sh
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
nok() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: [$3]"$'\n'"actual:   [$2]"; fi; }
expect_has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else nok "$1" "missing [$3] in:"$'\n'"$2"; fi; }
expect_lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then nok "$1" "unexpected [$3] in:"$'\n'"$2"; else ok "$1"; fi; }

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "claude $*" >> "%s/claude-calls.log"\nexit 99\n' "$TMP" > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
: > "$TMP/claude-calls.log"
export PATH="$TMP/bin:$PATH"

# The generated text in a case.yaml, un-indented.
block_text() {
  awk '/^# BEGIN project-instructions/ { on = 1; next } /^# END project-instructions/ { on = 0 }
       on && NR > 0 { print }' "$1" | sed '1,2d' | sed 's/^    //'
}

# Independent rendering: CLAUDE.md, then every .claude/rules/**/*.md whose
# frontmatter has no `paths:`, sorted by path, under Claude Code's headers.
cat > "$TMP/expect.cjs" <<'JS'
const fs = require('fs'), path = require('path');
const ws = process.argv[2];
const files = fs.existsSync(path.join(ws, 'CLAUDE.md')) ? ['CLAUDE.md'] : [];
const walk = (d) => fs.existsSync(path.join(ws, d)) ? fs.readdirSync(path.join(ws, d), { withFileTypes: true })
  .flatMap((e) => e.isDirectory() ? walk(`${d}/${e.name}`) : e.name.endsWith('.md') ? [`${d}/${e.name}`] : []) : [];
const scoped = (f) => { const m = fs.readFileSync(path.join(ws, f), 'utf8').match(/^---\n([\s\S]*?)\n---/); return !!m && /^paths:/m.test(m[1]); };
files.push(...walk('.claude/rules').sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)).filter((f) => !scoped(f)));
if (files.length) process.stdout.write('Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.\n' +
  files.map((f) => `\nContents of ${f} (project instructions, checked into the codebase):\n\n` + fs.readFileSync(path.join(ws, f), 'utf8')).join(''));
JS

echo "# the real suite"
out=$(cd "$SRC_ROOT" && bash "$GEN" --check 2>&1); rc=$?
expect_eq "every case.yaml's project instructions are current (run $GEN if not)" "$rc" "0"
[ "$rc" = 0 ] || printf '%s\n' "$out" | sed 's/^/     /'

n=0
for yaml in "$SRC_ROOT"/evals/*/case.yaml; do
  dir=$(dirname "$yaml") name=$(basename "$(dirname "$yaml")")
  n=$((n + 1))
  if grep -E '^tags:' "$dir/prompt.md" | grep -q 'description-only'; then
    expect_lacks "$name: description-only, no instructions" "$(cat "$yaml")" "append_system_prompt"
    continue
  fi
  expect_has "$name: has a generated append_system_prompt" "$(cat "$yaml")" "  append_system_prompt: |"
  root="$TMP/run-$name"; mkdir -p "$root/home/cwd"
  if ! err=$(cd "$root/home/cwd" && env -i PATH="$PATH" HOME="$root/home" TMPDIR="$TMP" bash "$dir/fixture.sh" 2>&1 >/dev/null); then
    nok "$name: fixture runs" "$err"; continue
  fi
  expect_eq "$name: text is the workspace's CLAUDE.md and always-loaded rules, byte for byte" \
    "$(block_text "$yaml" | od -An -c)" "$(node "$TMP/expect.cjs" "$root/home/cwd" | od -An -c)"
done
[ "$n" -gt 0 ] && ok "checked $n cases" || nok "no case.yaml found under evals/"

text=$(block_text "$SRC_ROOT/evals/trigger-new-feature/case.yaml")
for rule in "$SRC_ROOT"/framework-files/rules/*.md; do
  r=$(basename "$rule")
  if awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } /^paths:/ { f = 1; exit } END { exit !f }' "$rule"; then
    expect_lacks "path-scoped $r is left out" "$text" "Contents of .claude/rules/$r "
  else
    expect_has "always-loaded $r is included" "$text" "Contents of .claude/rules/$r "
  fi
done
expect_has "CLAUDE.md carries the \${aiDir} binding" "$text" 'Resolve to **`.ai/`**'

echo "# the generator, on a copy"
R="$TMP/repo"
mkdir -p "$R/evals"
cp -R "$SRC_ROOT/framework-files" "$SRC_ROOT/scaffolding" "$R/"
cp -R "$SRC_ROOT/evals/_fixtures" "$SRC_ROOT/evals/trigger-new-feature" "$SRC_ROOT/evals/trigger-memorize" "$R/evals/"
gen() { (cd "$R" && bash "$GEN" "$@" 2>&1); }

out=$(gen --check); rc=$?
expect_eq "copy: current" "$rc" "0"

printf '\nA new always-loaded line.\n' >> "$R/framework-files/rules/workflow.md"
out=$(gen --check); rc=$?
expect_eq "an always-loaded rule changes: --check exits 1" "$rc" "1"
expect_has "an always-loaded rule changes: names the stale cases" "$out" "stale in trigger-memorize trigger-new-feature"
out=$(gen); rc=$?
expect_eq "regenerate: exits 0" "$rc" "0"
expect_has "regenerate: the new line is in the prompt" "$(cat "$R/evals/trigger-new-feature/case.yaml")" "    A new always-loaded line."
out=$(gen --check); rc=$?
expect_eq "regenerate: then current" "$rc" "0"

printf -- '---\ntitle: "Scoped"\npaths:\n  - src/**\n---\n\nOnly under src/.\n' > "$R/framework-files/rules/zz-scoped.md"
out=$(gen --check); rc=$?
expect_eq "a new path-scoped rule does not change the prompt" "$rc" "0"

sed -i.bak 's/^tags: \[/tags: [description-only, /' "$R/evals/trigger-memorize/prompt.md" && rm -f "$R/evals/trigger-memorize/prompt.md.bak"
out=$(gen --check); rc=$?
expect_eq "description-only on a case with a block: --check exits 1" "$rc" "1"
gen trigger-memorize >/dev/null
expect_lacks "description-only: block removed" "$(cat "$R/evals/trigger-memorize/case.yaml")" "append_system_prompt"
expect_eq "description-only: the hand-written case.yaml is left as it was" "$(od -An -c < "$R/evals/trigger-memorize/case.yaml")" \
  "$(printf 'schema_version: "1.1"\nname: trigger-memorize\ncontext:\n  scaffold_script: fixture.sh\n' | od -An -c)"

printf 'execution:\n  model: sonnet\n' >> "$R/evals/trigger-new-feature/case.yaml"
out=$(gen --check trigger-new-feature); rc=$?
expect_eq "a hand-written execution: block: exits 2" "$rc" "2"
expect_has "a hand-written execution: block: says where the keys go" "$out" "move those keys to prompt.md frontmatter"
cp "$SRC_ROOT/evals/trigger-new-feature/case.yaml" "$R/evals/trigger-new-feature/case.yaml"

printf '\nfalse\n' >> "$R/evals/trigger-new-feature/fixture.sh"
out=$(gen --check trigger-new-feature); rc=$?
expect_eq "a failing fixture: exits 2" "$rc" "2"
expect_has "a failing fixture: names it" "$out" "trigger-new-feature/fixture.sh failed"

expect_eq "nothing invoked claude" "$(cat "$TMP/claude-calls.log")" ""

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
