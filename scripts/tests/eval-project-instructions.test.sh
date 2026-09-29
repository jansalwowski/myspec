#!/usr/bin/env bash
# Project instructions in eval runs (evals/README.md, "Project instructions").
# `claude plugin eval` never loads a workspace's CLAUDE.md or .claude/rules/,
# so evals/_fixtures/project-instructions.sh writes each case's always-loaded
# instructions into its case.yaml as execution.append_system_prompt.
#
# Checks that every case's generated text is present and current with its
# fixture and framework-files/, matches an independent rendering, matches what
# a live Claude Code 2.1.284 session showed for a probe workspace (frontmatter
# and block-level HTML comments dropped, `**`-only paths always loaded), and
# that the generator catches a stale block, honours the description-only
# opt-out in every YAML list form and refuses what it cannot handle. No model
# calls: a stub `claude` first on PATH fails the suite if anything invokes it.
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
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$(diff <(printf '%s\n' "$3") <(printf '%s\n' "$2") | head -20)"; fi; }
expect_has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else nok "$1" "missing [$3] in:"$'\n'"$(printf '%s' "$2" | head -20)"; fi; }
expect_lacks() { if printf '%s' "$2" | grep -qF -- "$3"; then nok "$1" "unexpected [$3]"; else ok "$1"; fi; }

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "claude $*" >> "%s/claude-calls.log"\nexit 99\n' "$TMP" > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
: > "$TMP/claude-calls.log"
export PATH="$TMP/bin:$PATH"

# The generated text in a case.yaml, un-indented.
block_text() {
  awk '/^# BEGIN project-instructions/ { on = 1; next } /^# END project-instructions/ { on = 0 } on { print }' "$1" \
    | sed '1,2d' | sed 's/^    //'
}

# Independent rendering in JS of what Claude Code 2.1.284 shows: frontmatter
# removed with its pattern, a rule left out when its `paths:` globs (minus a
# trailing /**) are not all `**`, block-level <!-- --> comments removed
# outside fenced code, each file trimmed, entries joined by blank lines.
# `node expect.cjs render <ws>` or `node expect.cjs always <rule-file>`.
cat > "$TMP/expect.cjs" <<'JS'
const fs = require('fs'), path = require('path');
const [mode, arg] = process.argv.slice(2);
const read = (p) => fs.readFileSync(p, 'utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n');
const splitFm = (s) => { const m = s.match(/^---\s*\n([\s\S]*?)---\s*\n?/); return m ? [m[1], s.slice(m[0].length)] : ['', s]; };
const unq = (v) => v.trim().replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
function globs(fm) {
  const lines = fm.split('\n');
  const i = lines.findIndex((l) => /^paths:/.test(l));
  if (i < 0) return null;
  const v = lines[i].replace(/^paths:\s*/, '').trim();
  if (v) return v.replace(/^\[|\]$/g, '').split(',').map(unq).filter(Boolean);
  const out = [];
  for (let j = i + 1; j < lines.length && /^\s*-\s+/.test(lines[j]); j++) out.push(unq(lines[j].replace(/^\s*-\s+/, '')));
  return out.filter(Boolean);
}
function alwaysLoaded(fm) {
  const g = globs(fm);
  if (g === null) return true;
  const s = g.map((x) => x.replace(/\/\*\*$/, '')).filter(Boolean);
  return s.length === 0 || s.every((x) => x === '**');
}
function stripComments(s) {
  if (!s.includes('<!--')) return s;
  const lines = s.match(/[^\n]*\n|[^\n]+$/g) || [];
  let out = '', fence = null;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (fence) { out += l; if (fence.test(l)) fence = null; continue; }
    const f = l.match(/^ {0,3}(`{3,}|~{3,})/);
    if (f) { fence = new RegExp(`^ {0,3}${f[1][0] === '`' ? '`' : '~'}{${f[1].length},}[ \\t]*\\n?$`); out += l; continue; }
    if (/^ {0,3}<!--/.test(l)) {
      let raw = l;
      while (!/<!--[\s\S]*?-->/.test(raw) && i + 1 < lines.length) raw += lines[++i];
      while (i + 1 < lines.length && lines[i + 1] === '\n') raw += lines[++i];
      const kept = raw.replace(/<!--[\s\S]*?-->/g, '');
      if (kept.trim()) out += kept;
      continue;
    }
    out += l;
  }
  return out;
}
if (mode === 'always') { process.stdout.write(alwaysLoaded(splitFm(read(arg))[0]) ? 'yes' : 'no'); process.exit(0); }
const ws = arg;
const walk = (d) => fs.existsSync(path.join(ws, d)) ? fs.readdirSync(path.join(ws, d), { withFileTypes: true })
  .flatMap((e) => e.isDirectory() ? walk(`${d}/${e.name}`) : e.name.endsWith('.md') ? [`${d}/${e.name}`] : []) : [];
const files = (fs.existsSync(path.join(ws, 'CLAUDE.md')) ? ['CLAUDE.md'] : [])
  .concat(walk('.claude/rules').sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)));
const entries = [];
for (const f of files) {
  const [fm, body] = splitFm(read(path.join(ws, f)));
  if (f !== 'CLAUDE.md' && !alwaysLoaded(fm)) continue;
  const c = stripComments(body).trim();
  if (c) entries.push(`Contents of ${f} (project instructions, checked into the codebase):\n\n${c}`);
}
if (entries.length) process.stdout.write(['Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.', ...entries].join('\n\n'));
JS

echo "# the real suite"
out=$(cd "$SRC_ROOT" && bash "$GEN" --check 2>&1); rc=$?
expect_eq "every case.yaml's project instructions are current (run $GEN if not)" "$rc" "0"
[ "$rc" = 0 ] || printf '%s\n' "$out" | sed 's/^/     /'

n=0
for yaml in "$SRC_ROOT"/evals/*/case.yaml; do
  dir=$(dirname "$yaml") name=$(basename "$(dirname "$yaml")")
  n=$((n + 1))
  if awk 'NR == 1 { next } /^---/ { exit } { print }' "$dir/prompt.md" | grep -q 'description-only'; then
    expect_lacks "$name: description-only, no instructions" "$(cat "$yaml")" "append_system_prompt"
    continue
  fi
  expect_has "$name: has a generated append_system_prompt" "$(cat "$yaml")" "  append_system_prompt: |-"
  root="$TMP/run-$name"; mkdir -p "$root/home/cwd"
  if ! err=$(cd "$root/home/cwd" && env -i PATH="$PATH" HOME="$root/home" TMPDIR="$TMP" bash "$dir/fixture.sh" 2>&1 >/dev/null); then
    nok "$name: fixture runs" "$err"; continue
  fi
  expect_eq "$name: text matches an independent rendering of the workspace" \
    "$(block_text "$yaml")" "$(node "$TMP/expect.cjs" render "$root/home/cwd")"
done
[ "$n" -gt 0 ] && ok "checked $n cases" || nok "no case.yaml found under evals/"

text=$(block_text "$SRC_ROOT/evals/trigger-new-feature/case.yaml")
for rule in "$SRC_ROOT"/framework-files/rules/*.md; do
  r=$(basename "$rule")
  if [ "$(node "$TMP/expect.cjs" always "$rule")" = yes ]; then
    expect_has "always-loaded $r is included" "$text" "Contents of .claude/rules/$r "
  else
    expect_lacks "path-scoped $r is left out" "$text" "Contents of .claude/rules/$r "
  fi
done
expect_has "CLAUDE.md carries the \${aiDir} binding" "$text" 'Resolve to **`.ai/`**'
expect_lacks "no rule frontmatter reaches the prompt" "$text" "purpose:"
expect_lacks "no HTML comment reaches the prompt" "$text" "<!--"

echo "# the generator, on a copy"
R="$TMP/repo"
mkdir -p "$R/evals"
cp -R "$SRC_ROOT/framework-files" "$SRC_ROOT/scaffolding" "$R/"
cp -R "$SRC_ROOT/evals/_fixtures" "$SRC_ROOT/evals/trigger-new-feature" "$SRC_ROOT/evals/trigger-memorize" "$R/evals/"
gen() { (cd "$R" && bash "$GEN" "$@" 2>&1); }

out=$(gen --check); rc=$?
expect_eq "copy: current" "$rc" "0"

# A probe workspace, and the text a live `claude -p` (2.1.284) echoed for it:
# frontmatter gone, the block comment gone with its line, the inline and the
# fenced comment kept, `paths: ["**"]` and a `- "**"` list always loaded,
# `src/**` left out. Two deliberate differences: repo-relative paths (Claude
# Code prints the absolute path of the run's scratch workspace) and sorted
# order (Claude Code uses the directory-listing order, which varies by
# filesystem).
mkdir -p "$R/evals/fidelity"
printf 'schema_version: "1.1"\nname: fidelity\ncontext:\n  scaffold_script: fixture.sh\n' > "$R/evals/fidelity/case.yaml"
printf -- '---\ntags: [probe]\n---\n\nprompt\n' > "$R/evals/fidelity/prompt.md"
cat > "$R/evals/fidelity/fixture.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .claude/rules/sub
cat > CLAUDE.md <<'MD'
---
owner: FRONTMATTER-FIELD-1111
---
# Fid project

Intro line PARA-2222 with <!-- INLINE-COMMENT-3333 --> inline.
<!-- BLOCK-COMMENT-4444 -->
After block comment AFTER-5555.

```
<!-- FENCED-COMMENT-6666 -->
```
MD
printf -- '---\ntitle: "All"\npaths: ["**"]\n---\n\nStar rule STAR-7777.\n' > .claude/rules/a-star.md
printf -- '---\ntitle: "Scoped"\npaths:\n  - src/**\n---\n\nScoped rule SCOPED-8888.\n' > .claude/rules/b-scoped.md
printf -- '---\ntitle: "Plain"\nupdated: 2026-01-01\n---\n\nPlain rule PLAIN-9999.\n' > .claude/rules/sub/c-plain.md
printf -- '---\npaths:\n  - "**"\n---\n\n<!--\nA multi-line\ncomment -->\n\nBlock-list star DSTAR-1212.\n' > .claude/rules/sub/d-star.md
SH
gen fidelity >/dev/null
expected=$(cat <<'TXT'
Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.

Contents of CLAUDE.md (project instructions, checked into the codebase):

# Fid project

Intro line PARA-2222 with <!-- INLINE-COMMENT-3333 --> inline.
After block comment AFTER-5555.

```
<!-- FENCED-COMMENT-6666 -->
```

Contents of .claude/rules/a-star.md (project instructions, checked into the codebase):

Star rule STAR-7777.

Contents of .claude/rules/sub/c-plain.md (project instructions, checked into the codebase):

Plain rule PLAIN-9999.

Contents of .claude/rules/sub/d-star.md (project instructions, checked into the codebase):

Block-list star DSTAR-1212.
TXT
)
expect_eq "fidelity: the text Claude Code shows (frontmatter, comments, ** paths)" "$(block_text "$R/evals/fidelity/case.yaml")" "$expected"
mkdir -p "$TMP/fid-ws" && (cd "$TMP/fid-ws" && bash "$R/evals/fidelity/fixture.sh")
expect_eq "fidelity: the independent rendering agrees" "$(node "$TMP/expect.cjs" render "$TMP/fid-ws")" "$expected"
rm -rf "$R/evals/fidelity"

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

orig_prompt=$(cat "$R/evals/trigger-memorize/prompt.md")
set_tags() { printf '%s\n' "$orig_prompt" | T="$1" awk '/^tags:/ && !done { print ENVIRON["T"]; done = 1; next } { print }' > "$R/evals/trigger-memorize/prompt.md"; }
for form in 'tags: [description-only, trigger]' \
            'tags: ["description-only", "trigger"]' \
            "tags: [trigger, 'description-only']" \
            $'tags:\n  - trigger\n  - description-only' \
            $'tags:\n  - "description-only"'; do
  label=$(printf '%s' "$form" | tr '\n' ' ')
  set_tags "$form"
  out=$(gen --check trigger-memorize); rc=$?
  expect_eq "description-only as [$label]: --check flags the block" "$rc" "1"
  gen trigger-memorize >/dev/null
  expect_lacks "description-only as [$label]: block removed" "$(cat "$R/evals/trigger-memorize/case.yaml")" "append_system_prompt"
  expect_eq "description-only as [$label]: the hand-written case.yaml is left as it was" "$(cat "$R/evals/trigger-memorize/case.yaml")" \
    "$(printf 'schema_version: "1.1"\nname: trigger-memorize\ncontext:\n  scaffold_script: fixture.sh')"
  printf '%s\n' "$orig_prompt" > "$R/evals/trigger-memorize/prompt.md"
  gen trigger-memorize >/dev/null
done
set_tags 'tags: [trigger, not-description-only]'
out=$(gen --check trigger-memorize); rc=$?
expect_eq "a tag that only contains the word is not the opt-out" "$rc" "0"
printf '%s\n' "$orig_prompt" > "$R/evals/trigger-memorize/prompt.md"

printf '%s\n' "$orig_prompt" | awk '/^tags:/ { print; print "append_system_prompt: \"Be terse.\""; next } { print }' > "$R/evals/trigger-memorize/prompt.md"
out=$(gen --check trigger-memorize); rc=$?
expect_eq "append_system_prompt in prompt.md: exits 2" "$rc" "2"
expect_has "append_system_prompt in prompt.md: says it would replace the block" "$out" "prompt.md sets append_system_prompt, which replaces the generated project instructions"
printf '%s\n' "$orig_prompt" > "$R/evals/trigger-memorize/prompt.md"

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
