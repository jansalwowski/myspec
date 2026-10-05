#!/usr/bin/env node
// retired-hashes.mjs
// Regenerates framework-files/retired-hashes.json: the SHA-256 of every hook
// and lib file the manifest retired since 3.0, as they were at the last 2.x
// release tag. Maintainer tooling (the release that retires more files, or
// moves the upgrade floor, re-runs it); the shipped file is what `update`'s
// 3.0.0-plugin-hooks migration compares a project's .claude/hooks and
// .claude/lib copies against: a copy that matches is the one 2.x installed
// and is moved in silence, one that differs was hand-patched and is named
// "locally modified, compare before discarding". The 3.0 plugin copies are
// no reference: this release rewrote every one of them.
//
// A retired file with no blob at the tag was added after the last 2.x release
// (lib/stop-gate/*, #257, lands with 3.0): no 2.x release installed it, so it
// is listed under `unreleased` and a copy of it on disk can only come from an
// unreleased build, which the migration treats as "locally modified".
//
// Usage: node scripts/retired-hashes.mjs [--tag v2.12.0] [--write]
//   default: print the JSON; --write replaces framework-files/retired-hashes.json
//   The tag is the 3.0 upgrade floor (skills/update/SKILL.md, "Upgrade base").
// Exit 0; 2 on a usage error or when the tag is unknown to git.

import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const argv = process.argv.slice(2);
let tag = 'v2.12.0';
let write = false;

for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === '--tag' && argv[i + 1]) {
    tag = argv[i + 1];
    i += 1;
  } else if (argv[i].startsWith('--tag=')) {
    tag = argv[i].slice('--tag='.length);
  } else if (argv[i] === '--write') {
    write = true;
  } else {
    process.stderr.write(`retired-hashes: unknown argument ${argv[i]}\n`);
    process.exit(2);
  }
}

try {
  execFileSync('git', ['rev-parse', '-q', '--verify', `refs/tags/${tag}`], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
} catch {
  process.stderr.write(`retired-hashes: tag ${tag} is unknown to git (git fetch origin tag ${tag})\n`);
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(join(root, 'framework-files', 'manifest.json'), 'utf8'));
const files = {};
const unreleased = [];

Object.entries(manifest.removed || {})
  .filter(([key, entry]) => (key.startsWith('hooks/') || key.startsWith('lib/')) && entry && /^(?:[3-9]|\d{2,})\./.test(String(entry.since || '')))
  .map(([key]) => key)
  .sort()
  .forEach((key) => {
    try {
      const blob = execFileSync('git', ['show', `${tag}:${key}`], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });

      files[key] = createHash('sha256').update(blob).digest('hex');
    } catch {
      unreleased.push(key);
    }
  });

const out = `${JSON.stringify({ tag, algorithm: 'sha256', files, unreleased }, null, 2)}\n`;

if (write) {
  writeFileSync(join(root, 'framework-files', 'retired-hashes.json'), out);
  process.stdout.write(`retired-hashes: wrote ${Object.keys(files).length} hashes at ${tag} (${unreleased.length} unreleased there) to framework-files/retired-hashes.json\n`);
} else {
  process.stdout.write(out);
}
