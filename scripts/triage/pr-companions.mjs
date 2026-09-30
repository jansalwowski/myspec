#!/usr/bin/env node
// Warn when a PR changes a skill without the companion change AGENTS.md asks
// for. Runs in .github/workflows/pr-labels.yml next to pr-labels.mjs, so it
// stays deterministic and free: no model call. It warns and never fails, since
// "checked and unaffected" is a valid answer only the author can give.
//
// - examples: a skills/<name>/ change with no examples/ change, unless the PR
//   template's Examples box is ticked (AGENTS.md "Examples track skills")
// - eval: a SKILL.md `description:` line changed with no evals/ change
//   (AGENTS.md "A new skill or a changed trigger gets an eval case")
//
// Usage: node scripts/triage/pr-companions.mjs [--body-file <f>] < files.json
//        files.json is the pulls/<n>/files API array: [{filename, patch}, ...]
// Output: one "<rule>: <message>" line per warning.
// Exit:   0 always on valid input, 2 on usage error.

import fs from 'node:fs';

function usage(msg) {
  process.stderr.write(`pr-companions: ${msg}\nusage: pr-companions.mjs [--body-file <f>] < files.json\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
let body = '';
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--body-file') body = fs.readFileSync(args[++i] ?? usage('--body-file needs a value'), 'utf8');
  else usage(`unknown argument ${args[i]}`);
}

let files;
try {
  files = JSON.parse(fs.readFileSync(0, 'utf8') || '[]');
} catch {
  usage('stdin is not JSON');
}
if (!Array.isArray(files)) usage('stdin is not a JSON array');

const names = files.map((f) => f.filename);
// Mirror paths follow their source, so only top-level skills/ counts.
const skills = [...new Set(names.map((n) => n.match(/^skills\/([^/]+)\//)?.[1]).filter((s) => s && s !== '_shared'))].sort();
const examplesTouched = names.some((n) => n.startsWith('examples/'));
const examplesTicked = /^\s*[-*]\s+\[[xX]\]\s+Examples\b/m.test(body);
const evalsTouched = names.some((n) => n.startsWith('evals/'));

const out = [];
if (skills.length && !examplesTouched && !examplesTicked) {
  out.push(`examples: changes ${skills.join(', ')} with no examples/ change; update examples/skills|flows or tick the Examples box once checked`);
}
// A missing patch (binary or very large file) cannot be read, so it warns nothing.
const triggers = files
  .filter((f) => /^skills\/[^/]+\/SKILL\.md$/.test(f.filename) && /^[+-]description:/m.test(f.patch ?? ''))
  .map((f) => f.filename.split('/')[1]);
if (triggers.length && !evalsTouched) {
  out.push(`eval: changes the description of ${triggers.join(', ')} with no evals/ change; add or update a case tagged skill:<name>`);
}
process.stdout.write(out.map((l) => `${l}\n`).join(''));
