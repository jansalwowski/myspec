#!/usr/bin/env node
// memory-index.mjs
// Regenerates `<aiDir>/memory/<type>/index.md` tables from the memory files.
//
// WHY DERIVED: the index is one shared file that every session appends to, so
// two parallel sessions conflict on it routinely. When the table is derived, a
// conflict stops being a merge to reason about — take either side and re-run
// this. Unique IDs (memory-claim-id.sh) stop two entries claiming one number;
// this stops the index itself being the merge hazard.
//
// WHY REFUSE: hook text has two durable sources — `hook:` in the memory's
// frontmatter, or the row already in the index. The previous generator fell
// back to the H1 when both were missing, which turned an absent hook into a
// plausible row nobody reviewed. Now an index is not regenerated until every
// memory in it has a hook; `--backfill` writes the derived value into the file
// where it can be reviewed, and says which ones had to come from a heading.
//
// Memory files are discovered and parsed only through memory-files.mjs, so a
// lowercase, slugless, or block-anchor file is seen here exactly as the doctor
// and the ID allocator see it.
//
// Usage:
//   memory-index.mjs               rewrite indexes that are out of date
//   memory-index.mjs --check       exit 1 if stale, a hook is missing, or an ID is duplicated
//   memory-index.mjs --backfill    write resolved hooks into frontmatter, then regenerate
//   memory-index.mjs --dry-run     report what a run would change; write nothing

import {
  existsSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import {
  join,
  relative,
} from 'node:path';
import {
  TYPES,
  aiDirFor,
  parseIndexTable,
  readMemories,
  repoRoot,
} from './memory-files.mjs';

const FLAGS = new Set(['--check', '--backfill', '--dry-run']);
const args = process.argv.slice(2);
const unknown = args.filter((arg) => !FLAGS.has(arg));

if (unknown.length > 0) {
  process.stderr.write(`unknown argument: ${unknown.join(' ')}\nusage: memory-index.mjs [--check] [--backfill] [--dry-run]\n`);
  process.exit(2);
}

const CHECK = args.includes('--check');
// --check never writes, so a backfill under it would report files it did not touch.
const BACKFILL = args.includes('--backfill') && !CHECK;
const WRITE = !CHECK && !args.includes('--dry-run');

if (CHECK && args.includes('--backfill')) {
  process.stderr.write('--backfill ignored under --check (nothing is written)\n');
}

const ANCHOR_HEADER = ['| ID | Hook | Anchor |', '|----|------|--------|'];
const DATE_HEADER = ['| ID | Hook | Date |', '|----|------|------|'];

// The prose around the table — frontmatter, title, agent note — is the
// template's and the project's; only the table is generated.
const CANONICAL = {
  procedural: ANCHOR_HEADER,
  semantic: ANCHOR_HEADER,
  episodic: DATE_HEADER,
};

// Only unescaped pipes are escaped: a `hook:` value copied from a cell already
// carries `\|`, and escaping it again drifts the row on every run.
function escapeCell(text) {
  return text.replace(/(?<!\\)\|/g, '\\|');
}

function unescapeCell(text) {
  return text.replace(/\\\|/g, '|');
}

// A row's cell by header name.
function cell(previous, name) {
  const index = previous.header.findIndex((heading) => heading.toLowerCase() === name.toLowerCase());

  return index === -1 ? '' : (previous.row.cells[index] || '').trim();
}

// Hook text carried by an existing row, escaped as it sits in the cell.
function hookFromRow(previous) {
  return previous ? cell(previous, 'Hook') : '';
}

// Frontmatter first, the existing row second, nothing third — the caller
// refuses when this returns null.
function resolveHook(memory, previous) {
  if (memory.hook) {
    return escapeCell(memory.hook);
  }

  return hookFromRow(previous) || null;
}

// Third column. Anchor: an author's cell wins, `---` included — leaving it
// blank was a choice, and re-deriving it would rewrite the index for no gain.
// Date: the file's `date:` is the truth; the cell only fills in when the file
// has none.
function resolveThird(memory, previous, type) {
  if (type.dir === 'episodic') {
    return (memory.date && escapeCell(memory.date))
      || (previous && cell(previous, 'Date'))
      || '---';
  }

  if (previous && cell(previous, 'Anchor')) {
    return cell(previous, 'Anchor');
  }

  const first = memory.anchors.anchors[0];

  return first ? escapeCell(first.file) : '---';
}

// Link text is the canonical ID; the target is the filename as it is on disk,
// so a lowercase or slugless file links correctly without being renamed.
function renderRow(memory, previous, type) {
  return `| [${memory.id}](${memory.name}) | ${resolveHook(memory, previous)} | ${resolveThird(memory, previous, type)} |`;
}

// Rows already in the index keyed by canonical ID, whatever their format.
function previousRows(table) {
  const rows = new Map();

  table.rows.forEach((row) => {
    if (row.id && !rows.has(row.id)) {
      rows.set(row.id, { row, header: table.header });
    }
  });

  return rows;
}

// The value --backfill writes: the row's hook with the cell escaping undone,
// else the H1 — flagged for review, because a heading is a title, not a
// trigger.
function backfillValue(memory, previous) {
  const fromRow = hookFromRow(previous);

  if (fromRow) {
    return { value: unescapeCell(fromRow), from: 'row' };
  }

  if (memory.heading) {
    return { value: memory.heading, from: 'heading' };
  }

  return null;
}

// Inserts `hook:` after `id:` when there is one, else first, replacing an
// empty `hook:` line if that is what was missing. Quoted for YAML so `"` and
// `\` round-trip through memory-files' unquote.
function withHook(memory, value) {
  const line = `hook: "${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  const { source, frontmatter } = memory;

  if (!source.startsWith('---\n')) {
    return `---\n${line}\n---\n\n${source}`;
  }

  const lines = frontmatter.split('\n');
  const existing = lines.findIndex((entry) => /^hook:/.test(entry));
  const id = lines.findIndex((entry) => /^id:/.test(entry));

  if (existing !== -1) {
    lines[existing] = line;
  } else {
    lines.splice(id === -1 ? 0 : id + 1, 0, line);
  }

  return `---\n${lines.join('\n')}${source.slice(4 + frontmatter.length)}`;
}

// The prose on either side of the table, verbatim.
function proseAround(source, table) {
  if (table.start === -1) {
    const trimmed = source.replace(/\s*$/, '');

    return { before: trimmed ? `${trimmed}\n\n` : '', after: '' };
  }

  const lines = source.split('\n');

  return { before: `${lines.slice(0, table.start).join('\n')}\n`, after: lines.slice(table.end).join('\n') };
}

function withUpdatedDate(before) {
  const today = new Date().toISOString().slice(0, 10);

  return before.replace(/^updated:\s*.+$/m, `updated: ${today}`);
}

function rowDiff(previous, rendered) {
  const diff = { added: 0, removed: 0, changed: 0 };

  rendered.forEach((line, id) => {
    if (!previous.has(id)) {
      diff.added += 1;
    } else if (previous.get(id).row.line !== line) {
      diff.changed += 1;
    }
  });

  previous.forEach((entry, id) => {
    if (!rendered.has(id)) {
      diff.removed += 1;
    }
  });

  return `rows: +${diff.added} -${diff.removed} ~${diff.changed}`;
}

const root = repoRoot();
const memoryRoot = join(root, aiDirFor(root), 'memory');
const rel = (path) => relative(root, path);
const script = rel(process.argv[1]).startsWith('..') ? process.argv[1] : rel(process.argv[1]);

let stale = 0;
let rewritten = 0;
let refused = 0;
let missingHooks = 0;

TYPES.forEach((type) => {
  const memoryDir = join(memoryRoot, type.dir);
  const indexPath = join(memoryDir, 'index.md');

  if (!existsSync(indexPath)) {
    return;
  }

  const label = rel(indexPath);
  const source = readFileSync(indexPath, 'utf8');
  const table = parseIndexTable(source);
  const previous = previousRows(table);
  let memories = readMemories(memoryDir);
  const notes = [];

  if (BACKFILL) {
    const verb = WRITE ? 'backfilled' : 'would backfill';
    const pending = memories
      .filter((memory) => !memory.hook)
      .map((memory) => ({ memory, ...backfillValue(memory, previous.get(memory.id)) }))
      .filter((entry) => entry.value);

    pending.forEach(({ memory, value, from }) => {
      if (from === 'heading') {
        process.stdout.write(`${verb} from heading (review): ${rel(memory.path)}\n`);
      }

      if (WRITE) {
        writeFileSync(memory.path, withHook(memory, value));
      } else {
        memory.hook = value;
      }
    });

    if (WRITE) {
      memories = readMemories(memoryDir);
    }

    const fromHeading = pending.filter((entry) => entry.from === 'heading').length;
    notes.push(`${verb} hook: ${pending.length} file(s) [${fromHeading} from heading]`);
  }

  const live = memories.filter((memory) => !memory.superseded);
  const problems = [];
  const byId = new Map();

  live.forEach((memory) => {
    byId.set(memory.id, [...(byId.get(memory.id) || []), memory]);
  });

  byId.forEach((entries, id) => {
    if (entries.length > 1) {
      problems.push(`duplicate id ${id}: ${entries.map((memory) => rel(memory.path)).sort().join(', ')}`);
    }
  });

  live.forEach((memory) => {
    if (!resolveHook(memory, previous.get(memory.id))) {
      problems.push(`missing hook: ${rel(memory.path)}`);
      missingHooks += 1;
    }
  });

  notes.forEach((note) => process.stdout.write(`${label}: ${note}\n`));

  if (problems.length > 0) {
    problems.forEach((problem) => process.stderr.write(`${problem}\n`));
    process.stderr.write(`refusing to regenerate ${label}\n`);
    refused += 1;

    return;
  }

  const rendered = new Map(live.map((memory) => [memory.id, renderRow(memory, previous.get(memory.id), type)]));
  const { before, after } = proseAround(source, table);
  const tableLines = [...CANONICAL[type.dir], ...rendered.values()];
  const next = `${before}${tableLines.join('\n')}\n${after}`.replace(/\n+$/, '\n');

  if (next === source) {
    if (!WRITE && !CHECK) {
      process.stdout.write(`${label}: up to date\n`);
    }

    return;
  }

  stale += 1;

  const detail = [rowDiff(previous, rendered)];

  if (CHECK) {
    process.stderr.write(`stale: ${label} — ${detail.join('; ')}\n`);

    return;
  }

  detail.forEach((line) => process.stdout.write(`${label}: ${line}\n`));

  if (!WRITE) {
    return;
  }

  // The date only moves when the table does, so --check stays stable overnight.
  const oldTable = source.split('\n').slice(table.start, table.end).join('\n');
  const prose = oldTable === tableLines.join('\n') ? before : withUpdatedDate(before);

  writeFileSync(indexPath, `${prose}${tableLines.join('\n')}\n${after}`.replace(/\n+$/, '\n'));
  rewritten += 1;
});

if (missingHooks > 0) {
  process.stderr.write('add a hook: line, or run --backfill to derive it from the index row / heading\n');
}

if (CHECK) {
  if (stale > 0) {
    process.stderr.write(`\n${stale} index file(s) out of date. Run: node ${script}\n`);
  }

  if (stale === 0 && refused === 0) {
    process.stdout.write('memory indexes are up to date\n');
  }

  process.exit(stale > 0 || refused > 0 ? 1 : 0);
}

if (WRITE) {
  process.stdout.write(`rewrote ${rewritten} index file(s)\n`);
} else {
  process.stdout.write('dry run — nothing written\n');
}

process.exit(refused > 0 ? 1 : 0);
