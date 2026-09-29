#!/usr/bin/env node
// Label a new issue from its title. Runs in .github/workflows/issue-triage.yml
// on every opened issue, so it stays deterministic and free: no model call.
//
// Issue titles lead with the component they are about ("feature-plan: …",
// "mark-code-changed.sh marks …", "feature-implement/plan/session-complete: …").
// Each leading token is looked up in the repo tree; a token that names a skill,
// hook or lib helper yields that area label. Anything the title does not name
// is left for the triage skill, which reads the body.
//
// Usage: node scripts/triage/area-labels.mjs [--root <dir>] [--existing a,b] "<title>"
// Output: one label per line: the area labels found, then status:needs-triage
//         unless --existing already holds a status:* label.
// Exit:   0 always on valid input, 2 on usage error.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function usage(msg) {
  process.stderr.write(`area-labels: ${msg}\nusage: area-labels.mjs [--root <dir>] [--existing a,b] "<title>"\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
let root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
let existing = [];
const rest = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--root') root = args[++i] ?? usage('--root needs a value');
  else if (args[i] === '--existing') existing = (args[++i] ?? usage('--existing needs a value')).split(',').map((s) => s.trim()).filter(Boolean);
  else rest.push(args[i]);
}
if (rest.length !== 1) usage('exactly one title argument');
const title = rest[0];

// Where a component can live, and the label it earns. Order is the output order.
const AREAS = [
  ['area:skills', (t) => [`skills/${t}/SKILL.md`]],
  ['area:hooks', (t) => [`hooks/${t}`, `hooks/${t}.sh`]],
  ['area:lib', (t) => [`lib/${t}`, `lib/${t}.sh`, `lib/${t}.mjs`]],
];

// The component list is the text before the first ": " (several components
// joined by "/" or ","). Without a colon, only the first word can name one.
const colon = title.match(/^([^:]+?):\s/);
const head = colon ? colon[1] : title.split(/\s/)[0];
const tokens = head.split(/[\s/,]+/).map((t) => t.replace(/[`()]/g, '')).filter((t) => /^[a-z0-9][a-z0-9._-]*$/.test(t));

const labels = [];
for (const [label, candidates] of AREAS) {
  const hit = tokens.some((t) => candidates(t).some((p) => fs.existsSync(path.join(root, p))));
  if (hit) labels.push(label);
}
if (!existing.some((l) => l.startsWith('status:'))) labels.push('status:needs-triage');
process.stdout.write(labels.map((l) => `${l}\n`).join(''));
