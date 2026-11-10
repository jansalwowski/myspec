#!/usr/bin/env node
// doc-status-normalize.mjs
// The doc-status vocabulary for spec.md / tech-spec.md frontmatter, and the
// one-shot rewrite `update` runs as the 3.1.0-doc-status migration (#261).
//
// Doc status is `draft | approved | deprecated` (framework-files/rules/
// workflow.md, "Status State Machine"). Projects wrote manifest words into
// it: `complete` and `implemented` for a shipped feature, `superseded` for a
// replaced one. Since 3.0 doc status gates work (feature-plan refuses a spec
// that is not `approved`), so those docs read as unapproved. This script
// rewrites the three known values and reports every other one:
//
//   complete, implemented  -> approved
//   superseded             -> deprecated
//
// It walks ${aiDir}/features/ for files named spec.md or tech-spec.md and
// touches only the first `status:` line of a leading `---` frontmatter block:
// the value is replaced in place, keeping its quotes, trailing comment and
// line ending. Re-running it rewrites nothing. A doc without frontmatter or
// without a status line is not reported.
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}/lib/doc-status-normalize.mjs" [--root <checkout>] [--ai-dir <path>] [--dry-run]
//
// Prints one line per rewritten file (`rewrote: <path>  status: <old> -> <new>`)
// and per off-vocabulary value (`off-vocabulary: <path>  status: <value>`),
// paths relative to the root, then a summary line. Exits 0, also when there is
// no features directory; 2 on a usage error.

import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { getSetting } from './myspec-config.mjs';

export const DOC_STATUSES = ['draft', 'approved', 'deprecated'];

export const DOC_STATUS_RENAMES = {
  complete: 'approved',
  implemented: 'approved',
  superseded: 'deprecated',
};

const DOC_FILES = new Set(['spec.md', 'tech-spec.md']);
// status: <value> with optional matching quotes and an optional # comment.
const STATUS_LINE = /^(status:[ \t]*)(["']?)(.*?)\2([ \t]*(?:#.*)?)$/;

// Locates the frontmatter status line of a document.
// Returns { index, prefix, quote, value, suffix } or null.
export function findStatus(lines) {
  if (lines[0]?.replace(/\r$/, '') !== '---') {
    return null;
  }

  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, '');

    if (line.trim() === '---') {
      return null;
    }

    const m = STATUS_LINE.exec(line);

    if (m) {
      return { index: i, prefix: m[1], quote: m[2], value: m[3].trim(), suffix: m[4] };
    }
  }

  return null;
}

// Classifies one document's text.
// Returns { kind: 'none' | 'ok' | 'rewrite' | 'off', value, to?, text? }.
export function normalizeText(text) {
  const lines = text.split('\n');
  const found = findStatus(lines);

  if (found === null) {
    return { kind: 'none' };
  }

  const { index, prefix, quote, value, suffix } = found;

  if (DOC_STATUSES.includes(value)) {
    return { kind: 'ok', value };
  }

  const to = DOC_STATUS_RENAMES[value];

  if (to === undefined) {
    return { kind: 'off', value };
  }

  const cr = lines[index].endsWith('\r') ? '\r' : '';

  lines[index] = `${prefix}${quote}${to}${quote}${suffix}${cr}`;

  return { kind: 'rewrite', value, to, text: lines.join('\n') };
}

function docFiles(dir) {
  const out = [];
  let entries;

  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }

  for (const entry of entries) {
    if (entry.name.startsWith('.')) {
      continue;
    }

    const path = join(dir, entry.name);

    if (entry.isDirectory()) {
      out.push(...docFiles(path));
    } else if (entry.isFile() && DOC_FILES.has(entry.name)) {
      out.push(path);
    }
  }

  return out;
}

export function normalizeTree(featuresDir, { dryRun = false } = {}) {
  const rewritten = [];
  const off = [];
  const files = docFiles(featuresDir).sort();

  for (const path of files) {
    const result = normalizeText(readFileSync(path, 'utf8'));

    if (result.kind === 'rewrite') {
      if (!dryRun) {
        writeFileSync(path, result.text);
      }

      rewritten.push({ path, from: result.value, to: result.to });
    } else if (result.kind === 'off') {
      off.push({ path, value: result.value });
    }
  }

  return { checked: files.length, rewritten, off };
}

function main(argv) {
  let root = process.cwd();
  let aiDirArg = null;
  let dryRun = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === '--dry-run') {
      dryRun = true;
    } else if (arg === '--root' && argv[i + 1] !== undefined) {
      root = argv[++i];
    } else if (arg === '--ai-dir' && argv[i + 1] !== undefined) {
      aiDirArg = argv[++i];
    } else {
      process.stderr.write('usage: doc-status-normalize.mjs [--root <checkout>] [--ai-dir <path>] [--dry-run]\n');

      return 2;
    }
  }

  root = resolve(root);
  const aiDir = aiDirArg ?? getSetting('aiDir', { root }).value;
  const featuresDir = resolve(root, aiDir, 'features');
  const { checked, rewritten, off } = normalizeTree(featuresDir, { dryRun });
  const rel = (p) => relative(root, p);
  const lines = [
    ...rewritten.map((r) => `${dryRun ? 'would rewrite' : 'rewrote'}: ${rel(r.path)}  status: ${r.from} -> ${r.to}`),
    ...off.map((o) => `off-vocabulary: ${rel(o.path)}  status: ${o.value === '' ? '(empty)' : o.value} (left as is; doc status is ${DOC_STATUSES.join(' | ')})`),
  ];

  lines.push(`doc-status-normalize: ${rewritten.length} ${dryRun ? 'to rewrite' : 'rewritten'}, ${off.length} off-vocabulary, ${checked} doc(s) checked${dryRun ? ' (dry run, nothing written)' : ''}`);
  process.stdout.write(`${lines.join('\n')}\n`);

  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)));
}
