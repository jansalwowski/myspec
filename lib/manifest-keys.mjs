#!/usr/bin/env node
// manifest-keys.mjs
// The one place a framework file's key maps to its manifest entry and its
// destination in a project. The key is the .myspec.json `frameworkFiles`
// spelling: bare for a `files` entry (`anti-patterns.md`,
// `templates/session-log.md`), `<block>/<name>` for every other block
// (`rules/workflow.md`, and `hooks/x.sh` / `lib/x.sh` for the copies 3.0
// retired). Pins, the manifest's `removed` block and `renamedFrom` all use it,
// so a rename may cross blocks (#473): `"renamedFrom": "rules/x.md"` on a
// `files` entry moves a rule into the aiDir.
//
// Until #473 the doctor, pin-reconcile and the update skill each derived a
// destination on their own, from a manifest key plus the block it sat in. A
// `renamedFrom` was resolved in the entry's own block, so a rule moved to the
// aiDir resolved to `${aiDir}/rules/x.md`, and a rule renamed to a rule to
// nothing (a rule's dest lives on its entry, which is gone once renamed).
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}/lib/manifest-keys.mjs" renames [--root <checkout>] [--plugin-root <dir>]
//     one tab-separated row per manifest entry carrying renamedFrom:
//     old key, old dest, new key, new dest (aiDir substituted). Exit 0;
//     2 on a usage error or a missing or unreadable manifest.

import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { aiDirFor } from './memory-files.mjs';
import { pluginRoot as resolvePluginRoot } from './plugin-root.mjs';

export const BLOCKS = ['files', 'rules'];

// trackingKey('rules', 'workflow.md') -> 'rules/workflow.md'
export function trackingKey(block, name) {
  return block === 'files' ? name : `${block}/${name}`;
}

// splitKey('rules/workflow.md') -> {block: 'rules', name: 'workflow.md'}
export function splitKey(key) {
  const m = /^(rules|hooks|lib)\/(.+)$/.exec(key);
  return m ? { block: m[1], name: m[2] } : { block: 'files', name: key };
}

// The destination a key installs to when no manifest entry says otherwise: a
// file under the aiDir (templates under its .templates/), a rule under
// .claude/rules/ (every rules entry's dest; lib/tests/manifest-regression.test.sh
// holds the manifest to it). null for a block that installs nothing.
function defaultDest(block, name, aiDir) {
  if (block === 'files') {
    return name.startsWith('templates/') ? `${aiDir}/.templates/${name.slice('templates/'.length)}` : `${aiDir}/${name}`;
  }
  return block === 'rules' ? `.claude/rules/${name}` : null;
}

function own(obj, key) {
  return obj !== null && typeof obj === 'object' && Object.hasOwn(obj, key);
}

// resolveKey(manifest, key, aiDir) -> {key, block, name, entry, dest}: the
// live entry (null when the manifest has none under that key) and the
// project-relative destination, ${aiDir} substituted. dest is null for a
// hooks/ or lib/ key.
export function resolveKey(manifest, key, aiDir) {
  const { block, name } = splitKey(key);
  const entry = BLOCKS.includes(block) && own(manifest?.[block], name) ? manifest[block][name] : null;
  const raw = entry && typeof entry.dest === 'string' ? entry.dest : defaultDest(block, name, aiDir);
  return { key, block, name, entry, dest: raw === null ? null : raw.replace(/\$\{aiDir\}/g, aiDir) };
}

// renames(manifest, aiDir) -> [{from, to}] with each side a resolveKey result,
// one per entry carrying renamedFrom, in manifest order.
export function renames(manifest, aiDir) {
  const out = [];
  for (const block of BLOCKS) {
    for (const [name, entry] of Object.entries(manifest?.[block] || {})) {
      if (entry && typeof entry.renamedFrom === 'string') {
        out.push({ from: resolveKey(manifest, entry.renamedFrom, aiDir), to: resolveKey(manifest, trackingKey(block, name), aiDir) });
      }
    }
  }
  return out;
}

// renamedTo(manifest, aiDir) -> Map from an old key to the resolveKey result
// of the live entry whose renamedFrom names it. Build it once per run.
export function renamedTo(manifest, aiDir) {
  return new Map(renames(manifest, aiDir).map((r) => [r.from.key, r.to]));
}

function cli(argv) {
  const opts = { root: null, pluginRoot: null, command: null };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--root' && argv[i + 1]) { opts.root = argv[++i]; }
    else if (a === '--plugin-root' && argv[i + 1]) { opts.pluginRoot = argv[++i]; }
    else if (a === 'renames' && opts.command === null) { opts.command = a; }
    else { process.stderr.write(`manifest-keys: unknown argument ${a}\nusage: manifest-keys.mjs renames [--root <checkout>] [--plugin-root <dir>]\n`); return 2; }
  }
  if (opts.command === null) { process.stderr.write('usage: manifest-keys.mjs renames [--root <checkout>] [--plugin-root <dir>]\n'); return 2; }
  let root = opts.root;
  if (root === null) {
    try { root = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { root = process.cwd(); }
  }
  const pluginRoot = resolvePluginRoot(import.meta.url, { explicit: opts.pluginRoot });
  const manifestPath = pluginRoot === null ? null : join(pluginRoot, 'framework-files', 'manifest.json');
  if (manifestPath === null || !existsSync(manifestPath)) { process.stderr.write('manifest-keys: plugin manifest not found; pass --plugin-root\n'); return 2; }
  let manifest;
  try { manifest = JSON.parse(readFileSync(manifestPath, 'utf8')); } catch (e) { process.stderr.write(`manifest-keys: ${manifestPath}: ${e.message}\n`); return 2; }
  for (const { from, to } of renames(manifest, aiDirFor(root))) {
    process.stdout.write(`${from.key}\t${from.dest}\t${to.key}\t${to.dest}\n`);
  }
  return 0;
}

// import.meta.url is the realpath; argv[1] keeps any symlink on the way.
function invokedDirectly() {
  if (!process.argv[1]) { return false; }
  try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; }
}

if (invokedDirectly()) {
  process.exitCode = cli(process.argv.slice(2));
}
