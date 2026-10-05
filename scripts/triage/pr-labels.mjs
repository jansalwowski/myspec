#!/usr/bin/env node
// Label a pull request from its title, changed files and closing issues. Runs
// in .github/workflows/pr-labels.yml on every opened or updated PR, so it stays
// deterministic and free: no model call.
//
// - type:*   from the Conventional Commit type in the title (AGENTS.md)
// - area:*   from the changed files, by the path table in the /triage skill
// - breaking from `type!:` in the title, a ticked "Breaking: yes" box in the body,
//            or a closing issue labelled breaking
// - P1-P3    the highest priority among the closing issues
//
// Usage: node scripts/triage/pr-labels.mjs --title "<title>" [--body-file <f>]
//          [--issue-labels a,b,...] < changed-files
// Output: one label per line, in a stable order.
// Exit:   0 always on valid input, 2 on usage error.

import fs from 'node:fs';

function usage(msg) {
  process.stderr.write(`pr-labels: ${msg}\nusage: pr-labels.mjs --title "<title>" [--body-file <f>] [--issue-labels a,b] < files\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
let title;
let body = '';
let issueLabels = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--title') title = args[++i] ?? usage('--title needs a value');
  else if (args[i] === '--body-file') body = fs.readFileSync(args[++i] ?? usage('--body-file needs a value'), 'utf8');
  else if (args[i] === '--issue-labels') issueLabels = (args[++i] ?? usage('--issue-labels needs a value')).split(',').map((s) => s.trim()).filter(Boolean);
  else usage(`unknown argument ${args[i]}`);
}
if (title === undefined) usage('--title is required');

const files = fs.readFileSync(0, 'utf8').split('\n').map((s) => s.trim()).filter(Boolean);

// refactor, chore, ci and test change no shipped behaviour a type label describes.
const TYPES = { feat: 'type:enhancement', refine: 'type:enhancement', perf: 'type:enhancement', fix: 'type:bug', docs: 'type:docs' };

// First match wins. Order is the output order.
const AREAS = [
  ['area:skills', /^skills\//],
  ['area:hooks', /^hooks\//],
  ['area:lib', /^lib\//],
  ['area:framework-files', /^(framework-files|blueprints|templates)\//],
  ['area:plugin', /^\.claude-plugin\//],
  ['area:tooling', /^(scripts|evals|quality|\.github|\.githooks|\.claude)\//],
];

const labels = [];
const head = title.match(/^([a-z]+)(\([^)]*\))?(!)?:\s/);
if (head && TYPES[head[1]]) labels.push(TYPES[head[1]]);

const areas = new Set();
for (const f of files) {
  const hit = AREAS.find(([, re]) => re.test(f));
  if (hit) areas.add(hit[0]);
}
for (const [label] of AREAS) if (areas.has(label)) labels.push(label);

const ticked = /^\s*[-*]\s+\[[xX]\]\s+Breaking: yes\b/m.test(body);
if ((head && head[3]) || ticked || issueLabels.includes('breaking')) labels.push('breaking');

const priority = ['P1', 'P2', 'P3'].find((p) => issueLabels.includes(p));
if (priority) labels.push(priority);

process.stdout.write(labels.map((l) => `${l}\n`).join(''));
