#!/usr/bin/env node
// mockup-config-check.mjs
// Compares a project's ${aiDir}/conventions/mockup-design.md with the parts of
// it the framework owns, and patches in what is missing (`update` runs it).
//
// The file is generated once by `/myspec:setup mockup` (blueprints/mockup.md)
// and is project-owned afterwards: most of it is the project's answers. A few
// parts come from the blueprint's output template and are the same in every
// project, and the mockup skills read them by name:
//
//   - every `## ` / `### ` section heading;
//   - every template line starting with `| ` or `- ` (the fixed Style baseline
//     rows and the first Detection patterns line), keyed by the first table
//     cell or by the bullet text before its first `:`.
//
// Those parts are read from the blueprint itself, so a release that adds a
// section or a fixed row needs no change here. A heading missing from the
// file is a `missing-section`; a fixed line whose key is missing from its
// section is a `missing-line`; a fixed line whose key is present with other
// text is a `differs` (reported, never rewritten: projects adapt the rows).
// A missing section whose template body is a project answer names the
// blueprint question(s) behind it (`ask: Q10`).
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}/lib/mockup-config-check.mjs" [--root <checkout>] [--file <path>]
//        [--blueprint <path>] [--apply] [--stamp <version>]
//
// --apply inserts each missing section (heading plus its fixed lines, in
// template order) and each missing line into its section; nothing else in the
// file changes. --stamp sets the frontmatter `myspec_version` (with --apply).
//
// Exit: 0 nothing missing (or --apply wrote it), 3 something missing (check
// mode), 4 the file does not exist, 2 usage error or unreadable blueprint.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { getSetting } from './myspec-config.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_BLUEPRINT = join(HERE, '..', 'blueprints', 'mockup.md');
const OUTPUT_HEADING = /^### `\$\{aiDir\}\/conventions\/mockup-design\.md`/;
const HEADING = /^(#{2,3}) (.+?)\s*$/;
const PLACEHOLDER = /^<.*>$/;

const norm = (s) => s.replace(/\s+/g, ' ').trim();

// Key of a fixed line: the first table cell, or the bullet text before `:`.
export function lineKey(line) {
  const t = line.trim();

  if (t.startsWith('|')) {
    return norm(t.slice(1).split('|')[0]).toLowerCase();
  }

  if (t.startsWith('- ')) {
    return norm(t.slice(2).split(':')[0]).toLowerCase();
  }

  return null;
}

const isFixed = (line) => line.startsWith('| ') || line.startsWith('- ');

// Question numbers a placeholder names: "Q2–Q4 and Q11" -> [2, 3, 4, 11].
export function questions(text) {
  const out = new Set();

  for (const m of text.matchAll(/Q(\d+)(?:\s*[–-]\s*Q?(\d+))?/g)) {
    const from = Number(m[1]);
    const to = m[2] === undefined ? from : Number(m[2]);

    for (let q = from; q <= to; q++) {
      out.add(q);
    }
  }

  return [...out];
}

// Parses the blueprint's output template into its sections, in order.
// Each: { level, title, body: [lines to write when missing], fixed: [lines], asks: [Q numbers] }.
export function parseTemplate(blueprint) {
  const lines = blueprint.split('\n').map((l) => l.replace(/\r$/, ''));
  const start = lines.findIndex((l) => OUTPUT_HEADING.test(l));

  if (start < 0) {
    throw new Error('output template heading for mockup-design.md not found in the blueprint');
  }

  const open = lines.findIndex((l, i) => i > start && l.startsWith('```'));
  const close = lines.findIndex((l, i) => i > open && l === '```');

  if (open < 0 || close < 0) {
    throw new Error('output template fence not found in the blueprint');
  }

  const sections = [];
  let current = null;
  let inFrontmatter = false;

  for (let i = open + 1; i < close; i++) {
    const line = lines[i];

    if (i === open + 1 && line === '---') {
      inFrontmatter = true;
      continue;
    }

    if (inFrontmatter) {
      inFrontmatter = line !== '---';
      continue;
    }

    const h = HEADING.exec(line);

    if (h) {
      current = { level: h[1].length, title: h[2], body: [], fixed: [], asks: [] };
      sections.push(current);
      continue;
    }

    if (current === null) {
      continue;
    }

    if (PLACEHOLDER.test(line.trim())) {
      current.asks.push(...questions(line));
      continue;
    }

    current.body.push(line);

    if (isFixed(line)) {
      current.fixed.push(line);
    }
  }

  for (const s of sections) {
    while (s.body.length && s.body[0].trim() === '') s.body.shift();
    while (s.body.length && s.body.at(-1).trim() === '') s.body.pop();
    s.asks = [...new Set(s.asks)];
  }

  return sections;
}

// Locates the file's headings outside code fences: [{ level, title, index }].
function fileHeadings(lines) {
  const out = [];
  let fence = false;

  lines.forEach((line, index) => {
    if (/^\s*```/.test(line)) {
      fence = !fence;
      return;
    }

    const h = fence ? null : HEADING.exec(line);

    if (h) {
      out.push({ level: h[1].length, title: h[2], index });
    }
  });

  return out;
}

const sameTitle = (a, b) => norm(a).toLowerCase() === norm(b).toLowerCase();

// The line range [from, to) of a heading's section in the file.
function sectionRange(lines, heading) {
  const headings = fileHeadings(lines);
  const at = headings.findIndex((h) => h.index === heading.index);
  const to = at + 1 < headings.length ? headings[at + 1].index : lines.length;

  return { from: heading.index + 1, to };
}

export function check(fileText, sections) {
  const lines = fileText.split('\n').map((l) => l.replace(/\r$/, ''));
  const headings = fileHeadings(lines);
  const findings = [];

  for (const s of sections) {
    const heading = headings.find((h) => h.level === s.level && sameTitle(h.title, s.title));

    if (!heading) {
      findings.push({ kind: 'missing-section', section: s });
      continue;
    }

    const { from, to } = sectionRange(lines, heading);
    const body = lines.slice(from, to);

    for (const fixed of s.fixed) {
      const key = lineKey(fixed);
      const match = body.find((l) => isFixed(l.trim()) && lineKey(l) === key);

      if (!match) {
        findings.push({ kind: 'missing-line', section: s, line: fixed });
      } else if (norm(match) !== norm(fixed)) {
        findings.push({ kind: 'differs', section: s, line: fixed, current: match.trim() });
      }
    }
  }

  return findings;
}

const label = (s) => `${'#'.repeat(s.level)} ${s.title}`;

// Inserts a missing section before the next template section the file has.
function insertSection(lines, sections, s) {
  const order = sections.indexOf(s);
  const headings = fileHeadings(lines);
  let at = lines.length;

  for (const next of sections.slice(order + 1)) {
    const h = headings.find((x) => x.level === next.level && sameTitle(x.title, next.title));

    if (h) {
      at = h.index;
      break;
    }
  }

  const block = [label(s), ...(s.body.length ? ['', ...s.body] : []), ''];

  if (at === lines.length) {
    while (lines.length && lines.at(-1) === '') lines.pop();
    lines.push('', ...block);
  } else {
    lines.splice(at, 0, ...block);
  }
}

// Inserts a missing fixed line into its section: a table row after the
// section's last row, a bullet before its first bullet.
function insertLine(lines, s, fixed) {
  const heading = fileHeadings(lines).find((h) => h.level === s.level && sameTitle(h.title, s.title));
  const { from, to } = sectionRange(lines, heading);
  const range = [...Array(to - from).keys()].map((k) => from + k);
  const row = fixed.startsWith('|');
  const same = range.filter((i) => lines[i].trim().startsWith(row ? '|' : '- '));

  if (row && same.length) {
    lines.splice(same.at(-1) + 1, 0, fixed);
  } else if (!row && same.length) {
    lines.splice(same[0], 0, fixed);
  } else {
    let end = to;

    while (end > from && lines[end - 1].trim() === '') end--;

    const add = row ? ['', '| Rule | Detail |', '|---|---|', fixed] : ['', fixed];

    if (end === from) {
      add.shift();
    }

    lines.splice(end, 0, ...add);
  }
}

function stamp(lines, version) {
  if (lines[0] !== '---') {
    return false;
  }

  const close = lines.findIndex((l, i) => i > 0 && l === '---');

  if (close < 0) {
    return false;
  }

  const at = lines.slice(0, close).findIndex((l) => /^myspec_version:/.test(l));

  if (at >= 0) {
    lines[at] = `myspec_version: ${version}`;
  } else {
    lines.splice(close, 0, `myspec_version: ${version}`);
  }

  return true;
}

export function apply(fileText, sections, findings, version) {
  const lines = fileText.split('\n');
  const cr = lines.some((l) => l.endsWith('\r'));
  const clean = lines.map((l) => l.replace(/\r$/, ''));

  for (const f of findings) {
    if (f.kind === 'missing-section') {
      insertSection(clean, sections, f.section);
    }
  }

  for (const f of findings) {
    if (f.kind === 'missing-line') {
      insertLine(clean, f.section, f.line);
    }
  }

  const stamped = version ? stamp(clean, version) : false;

  return { text: clean.join(cr ? '\r\n' : '\n'), stamped };
}

export function frontmatterVersion(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  const v = m && /^myspec_version:[ \t]*["']?([^"'\s#]+)/m.exec(m[1]);

  return v ? v[1] : 'unstamped';
}

function main(argv) {
  let root = process.cwd();
  let file = null;
  let blueprint = DEFAULT_BLUEPRINT;
  let doApply = false;
  let version = null;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === '--apply') {
      doApply = true;
    } else if (['--root', '--file', '--blueprint', '--stamp'].includes(arg) && argv[i + 1] !== undefined) {
      const v = argv[++i];

      if (arg === '--root') root = v;
      if (arg === '--file') file = v;
      if (arg === '--blueprint') blueprint = v;
      if (arg === '--stamp') version = v;
    } else {
      process.stderr.write('usage: mockup-config-check.mjs [--root <checkout>] [--file <path>] [--blueprint <path>] [--apply] [--stamp <version>]\n');

      return 2;
    }
  }

  root = resolve(root);
  file = file ? resolve(root, file) : resolve(root, getSetting('aiDir', { root }).value ?? 'ai', 'conventions', 'mockup-design.md');
  const rel = relative(root, file) || file;

  if (!existsSync(file)) {
    process.stdout.write(`mockup-config-check: ${rel} does not exist; /myspec:setup mockup generates it\n`);

    return 4;
  }

  let sections;

  try {
    sections = parseTemplate(readFileSync(blueprint, 'utf8'));
  } catch (err) {
    process.stderr.write(`mockup-config-check: cannot read the blueprint template (${blueprint}): ${err.message}\n`);

    return 2;
  }

  const text = readFileSync(file, 'utf8');
  const findings = check(text, sections);
  const missing = findings.filter((f) => f.kind !== 'differs');
  const out = [`file: ${rel}  myspec_version: ${frontmatterVersion(text)}`];
  const verb = (kind) => (doApply ? kind.replace('missing', 'added') : kind);

  for (const f of findings) {
    if (f.kind === 'missing-section') {
      out.push(`${verb(f.kind)}: ${label(f.section)}${f.section.asks.length ? `  ask: ${f.section.asks.map((q) => `Q${q}`).join(', ')}` : ''}`);
    } else if (f.kind === 'missing-line') {
      out.push(`${verb(f.kind)}: ${label(f.section)}  ${f.line}`);
    } else {
      out.push(`differs: ${label(f.section)}  plugin: ${f.line}`, `         ${' '.repeat(label(f.section).length)}  file:   ${f.current}`);
    }
  }

  if (doApply && (missing.length || version)) {
    const result = apply(text, sections, missing, version);

    writeFileSync(file, result.text);

    if (result.stamped) {
      out.push(`stamped: myspec_version ${version}`);
    }
  }

  const differs = findings.length - missing.length;

  out.push(`mockup-config-check: ${missing.length} ${doApply ? 'added' : 'missing'}, ${differs} differ${differs ? ' (left as is)' : ''}`);
  process.stdout.write(`${out.join('\n')}\n`);

  return !doApply && missing.length ? 3 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)));
}
