#!/usr/bin/env node
// memory-doctor.mjs
// Reports where a project's memory tree has drifted from what the memory
// tooling assumes. Read-only: it never edits a file, so it is safe to run from
// a hook, from the claim script, and against someone else's checkout.
//
// WHY: an audit of four real projects found that every failure of the memory
// tooling had the same shape — the project had drifted from an assumption
// (lowercase filenames, slugless names, bare-ID index rows, legacy headers,
// no `hook:` anywhere, three anchor syntaxes, `anchors: []`, `.claude/state/`
// committable, a stray second `ai/` tree, `load_when:` in rules) and nothing
// said so. The generator emptied its tables, the allocator handed out an ID
// that already lived on a branch. This is the mechanical check that names
// each of those, so the drift is visible before a tool acts on it.
//
// Who runs it: `update` after copying lib files, `bootstrap` at session start
// (reported, non-blocking), `memory-claim-id.sh` before allocating an ID
// (blocking on errors), and the stop hook when memory files changed.
//
// Errors are conditions a tool will act wrongly on; warnings are conditions
// the tooling tolerates but a human should tidy.
//
// Usage:
//   memory-doctor.mjs [--root <path>] [--quiet] [--json]
//
//   --root   checkout to examine; defaults to the MAIN checkout, because
//            duplicate detection has to see every worktree and every ref
//   --quiet  errors and the summary only
//   --json   { "errors": [...], "warnings": [...] } of { id, detail, path }
//
// Exit 1 when any error was found, else 0.

import {
  existsSync,
  readdirSync,
  readFileSync,
  realpathSync,
  statSync,
} from 'node:fs';
import {
  basename,
  dirname,
  join,
  relative,
  resolve,
} from 'node:path';
import {
  execFileSync,
} from 'node:child_process';

import {
  TYPES,
  LEGACY_HEADINGS,
  aiDirFor,
  blobFrontmatter,
  frontmatterOf,
  mainRoot,
  memoryFilesInRefs,
  normalizeId,
  parseIndexTable,
  readMemories,
  scalarField,
  worktreeRoots,
} from './memory-files.mjs';

const TOOLING = ['memory-claim-id.sh', 'memory-index.mjs', 'memory-files.mjs'];
const INDEX_ADVICE = 'run: node .claude/lib/memory-index.mjs';
const BACKFILL_ADVICE = 'run: node .claude/lib/memory-index.mjs --backfill (update does this)';

// --- arguments ---------------------------------------------------------------

const argv = process.argv.slice(2);
let rootArg = null;
let quiet = false;
let json = false;

for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];

  if (arg === '--root') {
    rootArg = argv[i + 1];
    i += 1;
  } else if (arg.startsWith('--root=')) {
    rootArg = arg.slice('--root='.length);
  } else if (arg === '--quiet') {
    quiet = true;
  } else if (arg === '--json') {
    json = true;
  } else {
    process.stderr.write(`memory doctor: unknown argument ${arg}\n`);
    process.stderr.write('usage: memory-doctor.mjs [--root <path>] [--quiet] [--json]\n');
    process.exit(2);
  }
}

function defaultRoot() {
  try {
    return mainRoot();
  } catch {
    return process.cwd();
  }
}

const root = resolve(rootArg || defaultRoot());
const aiDir = aiDirFor(root);
const memoryRoot = join(root, aiDir, 'memory');

// --- findings ----------------------------------------------------------------

const errors = [];
const warnings = [];

function error(id, path, detail) {
  errors.push({ id, detail, path });
}

function warn(id, path, detail) {
  warnings.push({ id, detail, path });
}

function rel(path) {
  return relative(root, path).split('\\').join('/');
}

function isGitRepo(dir) {
  try {
    execFileSync('git', ['rev-parse', '--is-inside-work-tree'], { cwd: dir, stdio: 'pipe' });

    return true;
  } catch {
    return false;
  }
}

function sameDir(a, b) {
  try {
    return realpathSync(a) === realpathSync(b);
  } catch {
    return a === b;
  }
}

function shortRef(refname) {
  return refname.replace(/^refs\/(heads|remotes)\//, '');
}

// At most three names, then `+N` — a stale file can sit on a hundred refs.
function nameList(names) {
  const unique = [...new Set(names)];
  const shown = unique.slice(0, 3);
  const more = unique.length - shown.length;

  return more > 0 ? `${shown.join(', ')}, +${more}` : shown.join(', ');
}

function canonicalName(memory) {
  return `${memory.id}${memory.slug ? `-${memory.slug}` : ''}.md`;
}

// --- no tree: nothing to check -----------------------------------------------

if (!existsSync(memoryRoot)) {
  const note = `memory doctor: no memory tree at ${aiDir}/memory`;

  if (json) {
    process.stdout.write(`${JSON.stringify({ errors: [], warnings: [], note }, null, 2)}\n`);
    process.stderr.write(`${note}\n`);
  } else {
    process.stdout.write(`${note}\n`);
  }

  process.exit(0);
}

// --- on-disk memories in the examined root -----------------------------------

const byType = TYPES.map((type) => {
  const dir = join(memoryRoot, type.dir);
  const memories = existsSync(dir) ? readMemories(dir) : [];
  const indexPath = join(dir, 'index.md');
  const indexSource = existsSync(indexPath) ? readFileSync(indexPath, 'utf8') : null;
  const table = indexSource === null ? null : parseIndexTable(indexSource);

  return { ...type, dir, memories, indexPath, indexSource, table };
});

const allMemories = byType.flatMap((type) => type.memories);
const idsOnDisk = new Set(allMemories.map((memory) => memory.id));

// --- duplicate-id: one ID, several files, anywhere the repo can be seen -------
//
// Sources, in order: the examined root, every linked worktree (their files may
// be uncommitted), every local and remote ref. Entries are keyed by
// repo-relative path so the same file seen twice (on disk and at a ref tip)
// is one file, not a duplicate. The key is case-folded: a project that fixed
// `p001-x.md` to `P001-x.md` on main still has the lowercase name on every
// older branch, and that is the same memory mid-rename (filename-case covers
// it), not a second one. `status: superseded` is the documented tombstone — a
// superseded file keeps its ID on purpose — so those are exempt.

const gitRoot = isGitRepo(root);
const filesById = new Map();

function noteFile(id, path, source) {
  if (!filesById.has(id)) {
    filesById.set(id, new Map());
  }

  const paths = filesById.get(id);
  const key = path.toLowerCase();

  if (!paths.has(key)) {
    paths.set(key, { path, onDisk: false, worktrees: [], refs: [], sha: null, superseded: null });
  }

  const entry = paths.get(key);

  if (source.kind === 'disk') {
    entry.path = path;
    entry.onDisk = true;
    entry.superseded = source.superseded;
  } else if (source.kind === 'worktree') {
    entry.worktrees.push(source.name);

    if (entry.superseded === null) {
      entry.superseded = source.superseded;
    }
  } else {
    entry.refs.push(...source.refs);
    entry.sha = entry.sha || source.sha;
  }
}

allMemories.forEach((memory) => {
  noteFile(memory.id, rel(memory.path), { kind: 'disk', superseded: memory.superseded });
});

if (gitRoot) {
  worktreeRoots(root)
    .filter((wt) => wt && existsSync(wt) && !sameDir(wt, root))
    .forEach((wt) => {
      TYPES.forEach((type) => {
        readMemories(join(wt, aiDir, 'memory', type.dir)).forEach((memory) => {
          const path = relative(wt, memory.path).split('\\').join('/');

          noteFile(memory.id, path, { kind: 'worktree', name: basename(wt), superseded: memory.superseded });
        });
      });
    });

  // The one slow step (one ls-tree per distinct ref tip); done exactly once.
  memoryFilesInRefs(root, aiDir).forEach((entries, id) => {
    entries.forEach(({ path, refs, sha }) => {
      noteFile(id, path, { kind: 'ref', refs, sha });
    });
  });
}

[...filesById.keys()].sort().forEach((id) => {
  const entries = [...filesById.get(id).values()];

  if (entries.length < 2) {
    return;
  }

  const live = entries.filter((entry) => {
    if (entry.superseded === null) {
      // Ref-only: read the frontmatter at the tip without checking it out.
      entry.superseded = scalarField(blobFrontmatter(root, entry.sha, entry.path), 'status') === 'superseded';
    }

    return !entry.superseded;
  });

  if (live.length < 2) {
    return;
  }

  const described = live.map((entry) => {
    const where = [];

    if (!entry.onDisk) {
      if (entry.worktrees.length > 0) {
        where.push(`worktree ${nameList(entry.worktrees)}`);
      }

      if (entry.refs.length > 0) {
        where.push(nameList(entry.refs.map(shortRef)));
      }
    }

    return where.length > 0 ? `${entry.path} (${where.join('; ')})` : entry.path;
  });

  const first = live.find((entry) => entry.onDisk) || live[0];

  error('duplicate-id', first.path, `${id}: ${described.join(', ')}`);
});

// --- per-index checks ---------------------------------------------------------

byType.forEach((type) => {
  const active = type.memories.filter((memory) => !memory.superseded);
  const indexRel = rel(type.indexPath);

  if (!existsSync(type.dir)) {
    return;
  }

  if (type.table === null) {
    if (active.length > 0) {
      error('index-drift', indexRel, `${indexRel}: missing, ${active.length} memory file(s) unindexed — create it from the index template, then ${INDEX_ADVICE}`);
      active.filter((memory) => !memory.hook).forEach((memory) => {
        error('missing-hook', rel(memory.path), `${rel(memory.path)}: no hook: in frontmatter — ${BACKFILL_ADVICE}`);
      });
    }

    return;
  }

  const withoutHook = active.filter((memory) => !memory.hook);

  if (type.table.legacy) {
    const legacy = type.table.header.filter((cell) => LEGACY_HEADINGS.includes(cell));

    error('legacy-index', indexRel, `${indexRel}: legacy columns (${legacy.join(', ')}) — ${BACKFILL_ADVICE}`);

    if (withoutHook.length > 0) {
      warn('missing-hook', indexRel, `${indexRel}: ${withoutHook.length} memories without hook: will be backfilled by the migration`);
    }

    return;
  }

  withoutHook.forEach((memory) => {
    error('missing-hook', rel(memory.path), `${rel(memory.path)}: no hook: in frontmatter — ${BACKFILL_ADVICE}`);
  });

  if (type.table.start === -1) {
    if (active.length > 0) {
      error('index-drift', indexRel, `${indexRel}: no ID table, ${active.length} memory file(s) unindexed — ${INDEX_ADVICE}`);
    }

    return;
  }

  const tableIds = new Set(type.table.rows.map((row) => row.id).filter(Boolean));
  const typeIds = new Set(type.memories.map((memory) => memory.id));
  const drift = [];

  active.forEach((memory) => {
    if (!tableIds.has(memory.id)) {
      drift.push(`${memory.id} on disk but not in the table`);
    }
  });

  type.table.rows.forEach((row) => {
    if (!row.id) {
      drift.push(`row with unreadable ID cell ${JSON.stringify(row.cells[0] || '')}`);

      return;
    }

    if (!typeIds.has(row.id)) {
      drift.push(`${row.id} in the table but no file`);

      return;
    }

    if (row.linked) {
      const target = (row.cells[0].match(/\]\(([^)]+)\)/) || [])[1];

      if (target && !existsSync(join(dirname(type.indexPath), target.split('#')[0]))) {
        drift.push(`${row.id} links to ${target}, which does not exist`);
      }
    }
  });

  drift.forEach((item) => {
    error('index-drift', indexRel, `${indexRel}: ${item} — ${INDEX_ADVICE}`);
  });
});

// --- per-file checks ----------------------------------------------------------

allMemories.forEach((memory) => {
  const path = rel(memory.path);
  const { anchors } = memory;

  if (anchors.form === 'malformed') {
    error('malformed-anchor', path, `${path}: anchor value ${JSON.stringify(anchors.malformed[0] || '')} is not a {file, pattern} map`);
  }

  // `anchors: []`, or an `anchor:` block with blank fields: the key is there
  // and says nothing, which reads the same as "no anchors" to every tool.
  if (anchors.form === 'empty') {
    warn('empty-anchors', path, `${path}: anchors key present but empty — ambiguous with no anchors — remove the key or add one`);
  }

  anchors.anchors
    .filter((anchor) => !anchor.pattern)
    .forEach((anchor) => {
      warn('anchor-no-pattern', path, `${path}: anchor ${anchor.file} has no pattern — it can never fire`);
    });

  if (memory.lowercase) {
    warn('filename-case', path, `${path}: lowercase prefix — tooling reads it, but rename to ${canonicalName(memory)} for consistency`);
  }

  if (memory.slugless) {
    warn('filename-slugless', path, `${path}: no -slug in the filename — rename to ${memory.id}-<slug>.md`);
  }

  if (memory.declaredId !== null && memory.declaredId !== '') {
    const declared = normalizeId(memory.declaredId) || memory.declaredId;

    if (declared !== memory.id) {
      warn('id-mismatch', path, `${path}: id: ${memory.declaredId} but the filename says ${memory.id}`);
    }
  }

  memory.related
    .filter((item) => /^[PSE]\d{3}$/.test(item) && !idsOnDisk.has(item))
    .forEach((item) => {
      warn('dangling-related', path, `${path}: related ${item} has no file`);
    });
});

// --- project-level checks -----------------------------------------------------

const libDir = join(root, '.claude', 'lib');

if (existsSync(join(root, '.myspec.json')) && existsSync(libDir)) {
  const missing = TOOLING.filter((name) => !existsSync(join(libDir, name)));

  if (missing.length > 0) {
    error('tooling-missing', '.claude/lib/', `.claude/lib/: missing ${missing.join(', ')} — run /myspec:update`);
  }
}

if (gitRoot) {
  let ignored = true;

  try {
    execFileSync('git', ['check-ignore', '-q', '.claude/state/probe'], { cwd: root, stdio: 'pipe' });
  } catch (err) {
    // 1 = not ignored; anything else is git failing, which is not this check.
    ignored = err.status !== 1;
  }

  if (!ignored) {
    warn('state-not-ignored', '.claude/state/', '.claude/state/ is not gitignored — the memory ID registry would be committable; add .claude/state/ to .gitignore');
  }
}

['ai', '.ai']
  .filter((candidate) => candidate !== aiDir)
  .filter((candidate) => existsSync(join(root, candidate, 'memory')))
  .forEach((candidate) => {
    warn('second-ai-tree', `${candidate}/memory`, `${candidate}/memory exists beside ${aiDir}/memory — the tooling only reads ${aiDir}; merge or delete the other tree`);
  });

function ruleFiles(dir) {
  if (!existsSync(dir)) {
    return [];
  }

  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);

    if (statSync(path).isDirectory()) {
      return ruleFiles(path);
    }

    return name.endsWith('.md') ? [path] : [];
  });
}

ruleFiles(join(root, '.claude', 'rules'))
  .filter((path) => /^load_when:/m.test(frontmatterOf(readFileSync(path, 'utf8'))))
  .forEach((path) => {
    warn('inert-rule-key', rel(path), `${rel(path)}: load_when: is not a Claude Code frontmatter key — the rule loads every session; use paths: globs or remove the key`);
  });

// --- report -------------------------------------------------------------------

const summary = errors.length === 0 && warnings.length === 0
  ? 'memory doctor: clean'
  : `memory doctor: ${errors.length} error(s), ${warnings.length} warning(s)`;

if (json) {
  process.stdout.write(`${JSON.stringify({ errors, warnings }, null, 2)}\n`);
} else {
  const lines = errors.map((finding) => `ERROR ${finding.id}: ${finding.detail}`);

  if (!quiet) {
    lines.push(...warnings.map((finding) => `WARN ${finding.id}: ${finding.detail}`));
  }

  lines.push(summary);
  process.stdout.write(`${lines.join('\n')}\n`);
}

process.exit(errors.length > 0 ? 1 : 0);
