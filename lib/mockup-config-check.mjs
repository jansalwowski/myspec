#!/usr/bin/env node
// mockup-config-check.mjs
// Lists the mockup blueprint questions a project's
// ${aiDir}/conventions/mockup-design.md has never been asked (`update` runs it).
//
// The file is generated once by `/myspec:setup mockup` and holds the
// project's answers. A release that adds a question adds a row to the
// blueprint's *Added questions* table (`| Q13 | Section | 3.8.0 |`). This
// script compares each row's version with the file's frontmatter
// `myspec_version` (an unstamped file counts as BASE_VERSION, the release
// that added the blueprint) and prints the newer rows. It never parses or
// edits the body of the file: writing an answer is the blueprint's job.
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}/lib/mockup-config-check.mjs" [--root <checkout>] [--file <path>]
//        [--blueprint <path>] [--stamp <version>]
//
// Prints `file:` with the stamp, one `ask:` line per newer question, and a
// summary. --stamp only sets `myspec_version` in the frontmatter (adding the
// key when absent), keeping a BOM and the line endings.
//
// Exit: 0 no question to ask (or stamped), 3 questions to ask, 4 the file
// does not exist, 2 usage error, unreadable blueprint, a file without
// frontmatter to stamp, or a file it cannot read or write.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { aiDirFor, frontmatterOf, scalarField } from './memory-files.mjs';
import { compareVersions, normalizeVersion } from './upgrade-route.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_BLUEPRINT = join(HERE, '..', 'blueprints', 'mockup.md');
export const BASE_VERSION = '1.20.0';
const BOM = '﻿';
const ROW = /^\|\s*Q(\d+)\s*\|\s*(.+?)\s*\|\s*v?(\d+\.\d+\.\d+)\s*\|\s*$/;

// Rows of the blueprint's *Added questions* table: [{ q, section, since }].
export function addedQuestions(blueprint) {
  const lines = blueprint.split('\n').map((l) => l.replace(/\r$/, ''));
  const start = lines.indexOf('## Added questions');

  if (start < 0) {
    throw new Error('no "## Added questions" section');
  }

  const rows = [];

  for (let i = start + 1; i < lines.length && !lines[i].startsWith('## '); i++) {
    const m = ROW.exec(lines[i]);

    if (m) {
      rows.push({ q: Number(m[1]), section: m[2], since: m[3] });
    }
  }

  return rows;
}

const stripBom = (text) => (text.startsWith(BOM) ? text.slice(1) : text);

// The file's stamp as X.Y.Z, or null when absent or not a version.
export function stampOf(text) {
  const raw = scalarField(frontmatterOf(stripBom(text).replace(/\r\n/g, '\n')), 'myspec_version');

  return raw ? normalizeVersion(raw) || null : null;
}

export function pending(rows, stamp) {
  return rows.filter((r) => compareVersions(r.since, stamp ?? BASE_VERSION) > 0);
}

// Sets `myspec_version` in the frontmatter. Returns the new text, or null
// when the file has no frontmatter.
export function withStamp(text, version) {
  const bom = text.startsWith(BOM) ? BOM : '';
  const lines = stripBom(text).split('\n');
  const clean = (l) => l.replace(/\r$/, '');

  if (clean(lines[0]) !== '---') {
    return null;
  }

  const close = lines.findIndex((l, i) => i > 0 && clean(l) === '---');

  if (close < 0) {
    return null;
  }

  const cr = lines[0].endsWith('\r') ? '\r' : '';
  const at = lines.findIndex((l, i) => i > 0 && i < close && /^myspec_version:/.test(l));
  const line = `myspec_version: ${version}${cr}`;

  if (at > 0) {
    lines[at] = line;
  } else {
    lines.splice(close, 0, line);
  }

  return bom + lines.join('\n');
}

const USAGE = 'usage: mockup-config-check.mjs [--root <checkout>] [--file <path>] [--blueprint <path>] [--stamp <version>]\n';

function main(argv) {
  const opts = { '--root': process.cwd(), '--file': null, '--blueprint': DEFAULT_BLUEPRINT, '--stamp': null };

  for (let i = 0; i < argv.length; i += 2) {
    if (!(argv[i] in opts) || argv[i + 1] === undefined) {
      process.stderr.write(USAGE);

      return 2;
    }

    opts[argv[i]] = argv[i + 1];
  }

  const version = opts['--stamp'] === null ? null : normalizeVersion(opts['--stamp']);

  if (version === '' || (opts['--stamp'] !== null && !version)) {
    process.stderr.write('mockup-config-check: --stamp takes a version (X.Y.Z)\n');

    return 2;
  }

  const root = resolve(opts['--root']);
  const file = opts['--file'] ? resolve(root, opts['--file']) : resolve(root, aiDirFor(root), 'conventions', 'mockup-design.md');
  const rel = relative(root, file) || file;

  if (!existsSync(file)) {
    process.stdout.write(`mockup-config-check: ${rel} does not exist; /myspec:setup mockup generates it\n`);

    return 4;
  }

  const text = readFileSync(file, 'utf8');

  if (version) {
    const stamped = withStamp(text, version);

    if (stamped === null) {
      process.stderr.write(`mockup-config-check: ${rel} has no frontmatter to stamp\n`);

      return 2;
    }

    writeFileSync(file, stamped);
    process.stdout.write(`stamped: ${rel}  myspec_version: ${version}\n`);

    return 0;
  }

  let rows;

  try {
    rows = addedQuestions(readFileSync(opts['--blueprint'], 'utf8'));
  } catch (err) {
    process.stderr.write(`mockup-config-check: cannot read the blueprint (${opts['--blueprint']}): ${err.message}\n`);

    return 2;
  }

  const stamp = stampOf(text);
  const asks = pending(rows, stamp);
  const out = [`file: ${rel}  myspec_version: ${stamp ?? `unstamped (counted as ${BASE_VERSION})`}`];

  for (const r of asks) {
    out.push(`ask: Q${r.q}  ## ${r.section}  (since ${r.since})`);
  }

  out.push(`mockup-config-check: ${asks.length} question(s) to ask`);
  process.stdout.write(`${out.join('\n')}\n`);

  return asks.length ? 3 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let status;

  try {
    status = main(process.argv.slice(2));
  } catch (err) {
    // An unreadable or read-only file: report it, never crash with a stack.
    process.stderr.write(`mockup-config-check: ${err.message}\n`);
    status = 2;
  }

  process.exit(status);
}
