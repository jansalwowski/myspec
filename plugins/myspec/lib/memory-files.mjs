// memory-files.mjs
// Shared parsing for the memory tooling: index generator, doctor, claim
// script (via the doctor). Imported, never executed.
//
// WHY ONE MODULE: memory-index.mjs and memory-claim-id.sh each carried their
// own idea of what a memory file looks like — uppercase prefix, a `-slug`, one
// anchor syntax, linked index rows — and a project that disagreed on any of
// them (lowercase filenames, slugless files, block-form anchors, bare-ID rows)
// was silently invisible to both: the generator emptied its indexes, the
// allocator handed out an ID that already existed. Every reader of memory
// files goes through here so there is exactly one definition of "a memory
// file", and it is case-insensitive, slug-optional, and reads every anchor
// form the templates and real projects have produced.

import {
  existsSync,
  readFileSync,
  readdirSync,
} from 'node:fs';
import {
  basename,
  join,
} from 'node:path';
import {
  execFileSync,
} from 'node:child_process';

export const TYPES = [
  { dir: 'procedural', prefix: 'P' },
  { dir: 'semantic', prefix: 'S' },
  { dir: 'episodic', prefix: 'E' },
];

// `P001-slug.md`, `p001-slug.md`, `P001.md` — prefix and number are the ID,
// the slug is optional. The canonical ID is uppercase, zero-padded to three.
export const MEMORY_FILE_RE = /^([PSE])(\d+)(?:-([^/]*))?\.md$/i;

export function canonicalId(prefix, number) {
  return `${prefix.toUpperCase()}${String(number).padStart(3, '0')}`;
}

// 'p9' → 'P009'; anything that is not a memory ID → null.
export function normalizeId(text) {
  const match = String(text).trim().match(/^([PSE])(\d+)$/i);

  return match ? canonicalId(match[1], Number(match[2])) : null;
}

export function parseMemoryName(name) {
  const match = basename(name).match(MEMORY_FILE_RE);

  if (!match) {
    return null;
  }

  return {
    id: canonicalId(match[1], Number(match[2])),
    prefix: match[1].toUpperCase(),
    number: Number(match[2]),
    slug: match[3] || '',
    lowercase: match[1] !== match[1].toUpperCase(),
    slugless: !match[3],
  };
}

export function repoRoot(cwd = process.cwd()) {
  return execFileSync('git', ['rev-parse', '--show-toplevel'], {
    cwd,
    encoding: 'utf8',
  }).trim();
}

// The main checkout, whatever worktree we are in. The ID allocator and the
// cross-worktree scans are scoped here (see memory-claim-id.sh).
export function mainRoot(cwd = process.cwd()) {
  const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], {
    cwd,
    encoding: 'utf8',
  }).trim();

  return join(common, '..');
}

export function aiDirFor(root) {
  const configPath = join(root, '.myspec.json');
  let value = '';

  if (existsSync(configPath)) {
    try {
      value = JSON.parse(readFileSync(configPath, 'utf8')).aiDir || '';
    } catch {
      // A malformed .myspec.json is not this module's problem to report.
    }
  }

  // No configured value: the documented default, never a guess from disk.
  // aiDir is a required key since 2.0 — the setup doctor reports its absence
  // (myspec-missing-key) and the 2.0.0-schema migration in `update` writes it.
  // Every shipped consumer (memory-claim-id.sh, the three hooks) resolves the
  // same way; lib/tests/aidir-fallback.test.sh holds them to it.
  if (!value) {
    return '.ai';
  }

  // `.ai/` and `.ai` both occur in the wild; the trailing slash breaks joins.
  return value.replace(/\/+$/, '');
}

export function frontmatterOf(source) {
  if (!source.startsWith('---\n')) {
    return '';
  }

  const end = source.indexOf('\n---', 4);

  return end === -1 ? '' : source.slice(4, end);
}

// Undoes the quoting style a scalar was written in. Stripping the surrounding
// quotes is not enough: `"no \\b here"` is YAML for `no \b here`.
export function unquote(raw) {
  const text = raw.trim();

  if (text.length > 1 && text.startsWith('"') && text.endsWith('"')) {
    return text.slice(1, -1).replace(/\\(["\\])/g, '$1');
  }

  if (text.length > 1 && text.startsWith("'") && text.endsWith("'")) {
    return text.slice(1, -1).replace(/''/g, "'");
  }

  return text;
}

export function scalarField(frontmatter, field) {
  const match = frontmatter.match(new RegExp(`^${field}:[ \\t]*(.*)$`, 'm'));

  if (!match) {
    return null;
  }

  return unquote(match[1]);
}

// `related: [P001, "S002"]` or a block list; returns the raw items.
export function listField(frontmatter, field) {
  const lines = frontmatter.split('\n');
  const start = lines.findIndex((line) => new RegExp(`^${field}:`).test(line));

  if (start === -1) {
    return [];
  }

  const rest = lines[start].slice(lines[start].indexOf(':') + 1).trim();

  if (rest.startsWith('[')) {
    const inner = rest.slice(1, rest.lastIndexOf(']'));

    return inner.split(',').map((item) => unquote(item)).filter(Boolean);
  }

  const items = [];

  for (let i = start + 1; i < lines.length; i += 1) {
    const item = lines[i].match(/^\s+-\s*(.*)$/);

    if (!item) {
      break;
    }

    items.push(unquote(item[1]));
  }

  return items;
}

// `{file: "x", pattern: "y"}` → { file, pattern }
function parseFlowMap(text) {
  const map = {};
  const body = text.trim().replace(/^\{/, '').replace(/\}$/, '');

  // Split on commas that are not inside quotes.
  body.split(/,(?=(?:[^"']*["'][^"']*["'])*[^"']*$)/).forEach((pair) => {
    const idx = pair.indexOf(':');

    if (idx === -1) {
      return;
    }

    map[pair.slice(0, idx).trim()] = unquote(pair.slice(idx + 1));
  });

  return map;
}

// Every anchor form seen in templates and real projects:
//   anchors: [{file: "x", pattern: "y"}, ...]        flow list
//   anchors:\n  - {file: "x", pattern: "y"}          block list of flow maps
//   anchors:\n  - file: "x"\n    pattern: "y"        block list of maps
//   anchor:\n  file: "x"\n  pattern: "y"             single map (semantic)
//   anchor: {file: "x", pattern: "y"}                single flow map
//   anchors: []  /  anchor: (blank fields)           empty
//   anchor: false / yes / "---"                      malformed
//
// Returns { anchors: [{file, pattern}], form, malformed: [text] }.
export function parseAnchors(frontmatter) {
  const lines = frontmatter.split('\n');
  const start = lines.findIndex((line) => /^anchors?:/.test(line));
  const result = { anchors: [], form: 'none', malformed: [] };

  if (start === -1) {
    return result;
  }

  const rest = lines[start].slice(lines[start].indexOf(':') + 1).trim();
  const block = [];

  for (let i = start + 1; i < lines.length; i += 1) {
    if (!/^\s/.test(lines[i]) || lines[i].trim() === '') {
      break;
    }

    block.push(lines[i]);
  }

  const push = (map) => {
    if (map.file && map.file !== '---') {
      result.anchors.push({ file: map.file, pattern: map.pattern || '' });
    }
  };

  if (/^\[\s*\]$/.test(rest)) {
    result.form = 'empty';

    return result;
  }

  if (rest.startsWith('[')) {
    result.form = 'flow';
    (rest.match(/\{[^}]*\}/g) || []).forEach((item) => push(parseFlowMap(item)));

    return result;
  }

  if (rest.startsWith('{')) {
    result.form = 'map';
    push(parseFlowMap(rest));

    return result;
  }

  if (rest !== '' && block.length === 0) {
    const scalar = unquote(rest);

    // `anchor: src/foo.js` — a bare path with no pattern. Readable, but the
    // doctor reports the missing pattern. `false`, `yes`, `---` are not paths.
    if (/[./]/.test(scalar) && !/^(false|true|yes|no|-+)$/i.test(scalar)) {
      result.form = 'scalar';
      push({ file: scalar });

      return result;
    }

    result.form = 'malformed';
    result.malformed.push(rest);

    return result;
  }

  if (block.length === 0) {
    result.form = 'empty';

    return result;
  }

  if (block.some((line) => /^\s*-/.test(line))) {
    result.form = 'block';
    let current = null;

    block.forEach((line) => {
      const item = line.match(/^\s*-\s*(.*)$/);

      if (item) {
        if (current) {
          push(current);
        }

        if (item[1].startsWith('{')) {
          push(parseFlowMap(item[1]));
          current = null;

          return;
        }

        current = {};
        const pair = item[1].match(/^(\w+):\s*(.*)$/);

        if (pair) {
          current[pair[1]] = unquote(pair[2]);
        }

        return;
      }

      const pair = line.match(/^\s+(\w+):\s*(.*)$/);

      if (pair && current) {
        current[pair[1]] = unquote(pair[2]);
      }
    });

    if (current) {
      push(current);
    }

    return result;
  }

  result.form = 'map';
  const map = {};

  block.forEach((line) => {
    const pair = line.match(/^\s+(\w+):\s*(.*)$/);

    if (pair) {
      map[pair[1]] = unquote(pair[2]);
    }
  });

  if (map.file) {
    push(map);
  } else {
    result.form = 'empty';
  }

  return result;
}

export function headingOf(source) {
  const match = source.match(/^#\s+(.+)$/m);

  return match ? match[1].trim() : null;
}

// Every memory file in a type directory, superseded ones included (the caller
// decides). Sorted by number so generated output is stable.
export function readMemories(memoryDir) {
  if (!existsSync(memoryDir)) {
    return [];
  }

  return readdirSync(memoryDir)
    .map((name) => ({ name, parsed: parseMemoryName(name) }))
    .filter(({ parsed }) => parsed)
    .map(({ name, parsed }) => {
      const path = join(memoryDir, name);
      const source = readFileSync(path, 'utf8');
      const frontmatter = frontmatterOf(source);

      return {
        name,
        path,
        ...parsed,
        source,
        frontmatter,
        hook: scalarField(frontmatter, 'hook'),
        heading: headingOf(source),
        status: scalarField(frontmatter, 'status'),
        superseded: scalarField(frontmatter, 'status') === 'superseded',
        created: scalarField(frontmatter, 'created'),
        date: scalarField(frontmatter, 'date'),
        declaredId: scalarField(frontmatter, 'id'),
        related: listField(frontmatter, 'related').map((item) => normalizeId(item) || item),
        anchors: parseAnchors(frontmatter),
      };
    })
    .sort((a, b) => a.number - b.number || a.name.localeCompare(b.name));
}

// Splits an index into header cells and data rows. Row IDs are read from a
// linked cell (`[P001](P001-slug.md)`) or a bare one (`P001`), either case.
export function parseIndexTable(source) {
  const lines = source.split('\n');
  const start = lines.findIndex((line) => /^\|\s*ID\s*\|/i.test(line));

  if (start === -1) {
    return { start: -1, end: -1, header: [], rows: [] };
  }

  const splitCells = (line) => line.split(/(?<!\\)\|/).map((cell) => cell.trim()).slice(1, -1);
  const header = splitCells(lines[start]);
  const rows = [];
  let end = start + 1;

  while (end < lines.length && /^\|/.test(lines[end])) {
    if (end > start + 1) {
      const cells = splitCells(lines[end]);
      const idText = (cells[0] || '').replace(/^\[([^\]]+)\].*$/, '$1');
      const id = normalizeId(idText);

      rows.push({ line: lines[end], cells, id, linked: /^\[/.test(cells[0] || '') });
    }

    end += 1;
  }

  return {
    start,
    end,
    header,
    rows,
  };
}

// Every checkout of the repo: the main one plus each linked worktree.
export function worktreeRoots(root) {
  try {
    return execFileSync('git', ['worktree', 'list', '--porcelain'], { cwd: root, encoding: 'utf8' })
      .split('\n')
      .filter((line) => line.startsWith('worktree '))
      .map((line) => line.slice('worktree '.length));
  } catch {
    return [root];
  }
}

// Memory files reachable from any local or remote ref, keyed by canonical ID:
// Map<id, Array<{ path, refs: [refname], sha }>>. Tips shared by several refs
// are listed once per path. This is how a memory that only ever lived on a
// pushed branch still reserves its number.
export function memoryFilesInRefs(root, aiDir) {
  const byId = new Map();
  let refs;

  try {
    refs = execFileSync('git', ['for-each-ref', '--format=%(objectname) %(refname)', 'refs/heads', 'refs/remotes'], {
      cwd: root,
      encoding: 'utf8',
    }).trim().split('\n').filter(Boolean);
  } catch {
    return byId;
  }

  const byTip = new Map();

  refs.forEach((line) => {
    const [sha, refname] = line.split(' ');

    if (refname.endsWith('/HEAD')) {
      return;
    }

    if (!byTip.has(sha)) {
      byTip.set(sha, []);
    }

    byTip.get(sha).push(refname);
  });

  const dirs = TYPES.map((type) => `${aiDir}/memory/${type.dir}`);

  byTip.forEach((refnames, sha) => {
    // Bare, like `refs` above: the catch returns, so nothing reads it before
    // the assignment. An initializer here is dead weight a consumer's lint gate
    // flags inside a file it can only silence by pinning.
    let listing;

    try {
      listing = execFileSync('git', ['ls-tree', '-r', '--name-only', sha, '--', ...dirs], {
        cwd: root,
        encoding: 'utf8',
      });
    } catch {
      return;
    }

    listing.split('\n').filter(Boolean).forEach((path) => {
      const parsed = parseMemoryName(path);

      if (!parsed) {
        return;
      }

      if (!byId.has(parsed.id)) {
        byId.set(parsed.id, []);
      }

      const entries = byId.get(parsed.id);
      const existing = entries.find((entry) => entry.path === path);

      if (existing) {
        existing.refs.push(...refnames);
      } else {
        entries.push({ path, refs: [...refnames], sha });
      }
    });
  });

  return byId;
}

// Frontmatter of a file at a given commit, for the rare duplicate that needs
// its `status:` read without checking the branch out.
export function blobFrontmatter(root, sha, path) {
  try {
    return frontmatterOf(execFileSync('git', ['show', `${sha}:${path}`], { cwd: root, encoding: 'utf8' }));
  } catch {
    return '';
  }
}
