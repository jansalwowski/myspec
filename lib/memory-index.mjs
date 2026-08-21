#!/usr/bin/env node
// memory-index.mjs
// Regenerates `<aiDir>/memory/<type>/index.md` tables from the memory files.
//
// WHY: the index is one shared file that every session appends to, so two
// parallel sessions conflict on it routinely. When the table is *derived*, a
// conflict stops being a merge to reason about — take either side and re-run
// this. Unique IDs (memory-claim-id.sh) stop two entries claiming one number;
// this stops the index itself being the merge hazard.
//
// The table is generated; everything around it (frontmatter, headings, the
// agent notes) is authored prose and is preserved verbatim.
//
// Hook text resolution, in order:
//   1. `hook:` in the memory file's frontmatter — the durable home
//   2. the row already in the index — so nothing is lost before backfill
//   3. the file's H1
//
// Usage:
//   memory-index.mjs                 rewrite indexes that are out of date
//   memory-index.mjs --check         exit 1 if any index is stale (CI)
//   memory-index.mjs --backfill      write resolved hooks into frontmatter

import {
  readFileSync,
  readdirSync,
  writeFileSync,
  existsSync,
} from 'node:fs';
import {
  join,
} from 'node:path';
import {
  execFileSync,
} from 'node:child_process';

const TYPES = [
  { dir: 'procedural', prefix: 'P' },
  { dir: 'semantic', prefix: 'S' },
  { dir: 'episodic', prefix: 'E' },
];

const args = new Set(process.argv.slice(2));
const CHECK = args.has('--check');
const BACKFILL = args.has('--backfill');

// The tree the agent is working in, not the main checkout: memory files are
// tracked, so a worktree session writes and indexes its own copies. Only the
// ID lock is main-checkout-scoped (see memory-claim-id.sh).
function repoRoot() {
  return execFileSync('git', ['rev-parse', '--show-toplevel'], {
    encoding: 'utf8',
  }).trim();
}

function aiDirFor(root) {
  const configPath = join(root, '.myspec.json');

  if (!existsSync(configPath)) {
    return '.ai';
  }

  try {
    return JSON.parse(readFileSync(configPath, 'utf8')).aiDir || '.ai';
  } catch {
    // A malformed .myspec.json is not this tool's problem to report.
    return '.ai';
  }
}

function frontmatterOf(source) {
  if (!source.startsWith('---\n')) {
    return '';
  }

  const end = source.indexOf('\n---', 4);

  return end === -1 ? '' : source.slice(4, end);
}

function scalarField(frontmatter, field) {
  const match = frontmatter.match(new RegExp(`^${field}:\\s*(.+)$`, 'm'));

  if (!match) {
    return null;
  }

  return match[1].trim().replace(/^['"]|['"]$/g, '');
}

function firstAnchorFile(frontmatter) {
  const match = frontmatter.match(/^\s*-\s*\{file:\s*["']([^"']+)["']/m);

  return match ? match[1] : null;
}

function headingOf(source) {
  const match = source.match(/^#\s+(.+)$/m);

  return match ? match[1].trim() : null;
}

function escapeCell(text) {
  return text.replace(/\|/g, '\\|');
}

// Rows already in the index, keyed by ID — the fallback source for hook text
// and the reason a pre-backfill run loses nothing.
//
// Cells are split on UNESCAPED pipes: hook text routinely contains `\|`
// (`mongoose.models.X \|\| ...`), and a naive `[^|]*` truncates the cell at the
// first one, silently shortening the hook on every regeneration.
function existingRows(indexSource, prefix) {
  const idPattern = new RegExp(`^\\|\\s*\\[(${prefix}\\d+)\\]`);
  const rows = new Map();

  indexSource.split('\n').forEach((line) => {
    const match = line.match(idPattern);

    if (!match) {
      return;
    }

    const cells = line.split(/(?<!\\)\|/).map((cell) => cell.trim());

    // ['', '[Pnnn](file)', hook, anchor, '']
    if (cells.length < 4) {
      return;
    }

    rows.set(match[1], { hook: cells[2], anchor: cells[3] });
  });

  return rows;
}

function readMemories(memoryDir, prefix) {
  const filePattern = new RegExp(`^(${prefix}\\d+)(?:-[^/]*)?\\.md$`);

  return readdirSync(memoryDir)
    .filter((name) => filePattern.test(name))
    .map((name) => {
      const source = readFileSync(join(memoryDir, name), 'utf8');
      const frontmatter = frontmatterOf(source);

      return {
        name,
        path: join(memoryDir, name),
        id: name.match(filePattern)[1],
        source,
        frontmatter,
        hook: scalarField(frontmatter, 'hook'),
        anchor: firstAnchorFile(frontmatter),
        heading: headingOf(source),
        superseded: scalarField(frontmatter, 'status') === 'superseded',
      };
    })
    .filter((memory) => !memory.superseded)
    .sort((a, b) => Number(a.id.slice(1)) - Number(b.id.slice(1)));
}

// Returns cells ready to drop into the table. Text taken from an existing row
// is already pipe-escaped; text pulled from frontmatter or a heading is not.
// Escaping both alike turns `\|\|` into `\\|\\|` on every run.
function resolveRow(memory, previous) {
  const hook = memory.hook
    ? escapeCell(memory.hook)
    : (previous && previous.hook)
      || escapeCell(memory.heading || '(no hook — add a `hook:` line to the memory frontmatter)');

  // The existing row wins for the anchor, `---` included: an author who left it
  // blank chose that, and re-deriving it from frontmatter would rewrite the
  // index on first run for no gain.
  const anchor = (previous && previous.anchor)
    || (memory.anchor && escapeCell(memory.anchor))
    || '---';

  return { hook, anchor };
}

// The header is taken from the file, not hardcoded: the episodic index's third
// column is `Date`, not `Anchor`.
function renderTable(memories, previousRows, header) {
  const lines = [...header];

  memories.forEach((memory) => {
    const { hook, anchor } = resolveRow(memory, previousRows.get(memory.id));
    lines.push(`| [${memory.id}](${memory.name}) | ${hook} | ${anchor} |`);
  });

  return lines.join('\n');
}

// Splits the index into the prose before the table, the table, and anything
// after it. Only the middle is ours to rewrite.
function splitIndex(source) {
  const lines = source.split('\n');
  const start = lines.findIndex((line) => /^\|\s*ID\s*\|/.test(line));

  if (start === -1) {
    return {
      before: source.replace(/\s*$/, '\n'),
      header: ['| ID | Hook | Anchor |', '|----|------|--------|'],
      after: '',
    };
  }

  let end = start + 1;
  while (end < lines.length && /^\|/.test(lines[end])) {
    end += 1;
  }

  // Header row plus its separator, kept verbatim.
  const headerEnd = Math.min(start + 2, end);

  return {
    before: `${lines.slice(0, start).join('\n')}\n`,
    header: lines.slice(start, headerEnd),
    after: lines.slice(end).join('\n'),
  };
}

function withUpdatedDate(before) {
  const today = new Date().toISOString().slice(0, 10);

  return before.replace(/^updated:\s*.+$/m, `updated: ${today}`);
}

function backfillHooks(memories, previousRows) {
  let written = 0;

  memories.forEach((memory) => {
    if (memory.hook) {
      return;
    }

    const previous = previousRows.get(memory.id);
    const hook = (previous && previous.hook) || memory.heading;

    if (!hook) {
      return;
    }

    // Unescape the index's cell escaping on the way back into YAML.
    const value = hook.replace(/\\\|/g, '|').replace(/"/g, '\\"');
    const updated = memory.source.replace(/^(id:\s*.+)$/m, `$1\nhook: "${value}"`);

    if (updated !== memory.source) {
      writeFileSync(memory.path, updated);
      written += 1;
    }
  });

  return written;
}

const root = repoRoot();
const memoryRoot = join(root, aiDirFor(root), 'memory');

let stale = 0;
let rewritten = 0;
let backfilled = 0;

TYPES.forEach(({ dir, prefix }) => {
  const memoryDir = join(memoryRoot, dir);
  const indexPath = join(memoryDir, 'index.md');

  if (!existsSync(indexPath)) {
    return;
  }

  const indexSource = readFileSync(indexPath, 'utf8');
  const previousRows = existingRows(indexSource, prefix);
  const memories = readMemories(memoryDir, prefix);

  if (BACKFILL) {
    backfilled += backfillHooks(memories, previousRows);
  }

  const { before, header, after } = splitIndex(indexSource);
  const table = renderTable(BACKFILL ? readMemories(memoryDir, prefix) : memories, previousRows, header);
  const current = `${before}${table}\n${after}`.replace(/\n+$/, '\n');

  if (current === indexSource) {
    return;
  }

  stale += 1;

  if (CHECK) {
    process.stderr.write(`stale: ${indexPath}\n`);
    return;
  }

  // The date only moves when the table does, so --check stays stable overnight.
  writeFileSync(indexPath, `${withUpdatedDate(before)}${table}\n${after}`.replace(/\n+$/, '\n'));
  rewritten += 1;
});

if (BACKFILL) {
  process.stdout.write(`backfilled hook: into ${backfilled} memory file(s)\n`);
}

if (CHECK) {
  if (stale > 0) {
    process.stderr.write(`\n${stale} index file(s) out of date. Run: yarn memory:index\n`);
    process.exit(1);
  }

  process.stdout.write('memory indexes are up to date\n');
  process.exit(0);
}

process.stdout.write(`rewrote ${rewritten} index file(s)\n`);
