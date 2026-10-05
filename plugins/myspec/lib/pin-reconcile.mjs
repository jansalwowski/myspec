#!/usr/bin/env node
// pin-reconcile.mjs
// Tells `update` what each pin in .myspec.json `frameworkFiles` is still
// doing (#160). A pinned file never receives the plugin copy, so a pin
// outlives its reason in two ways: the project's edit was absorbed upstream
// (the pin keeps nothing), or upstream moved under the pin (a migration or a
// fix never reached the file). Comparing sizes, as update did until 3.0,
// could tell neither apart.
//
// Each pin records two SHA-256 hashes when it is taken or last reconciled
// (schema v2, lib/myspec-config.schema.json): `hash`, the project's file, and
// `upstreamHash`, the plugin's rendered copy (`${aiDir}` substituted) at the
// same moment. For a marker-merge file both cover only the framework-owned
// region (line 1 through the end marker), which is all drop compares: the
// project section below it is the project's to edit. Against the file and the
// plugin copy as they are now:
//
//   drop        the project's file equals the plugin's rendered copy (for a
//               marker-merge file: its framework-owned region, line 1 through
//               the end marker); the pin keeps nothing
//   review      the file is unchanged since the pin was recorded and the
//               plugin copy is not: upstream moved under the pin
//   keep        the project changed the file since the pin was recorded (it
//               is live), or nothing moved on either side
//   unrecorded  the pin has no hashes; run --backfill
//   missing     the pinned file does not exist
//   retired     the key is a `removed` manifest entry, or a hooks/ or lib/
//               copy (dropped by the 3.0.0-plugin-hooks migration)
//   unknown     no manifest entry; the key is misspelled or long gone
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}/lib/pin-reconcile.mjs" [--root <checkout>] [--plugin-root <dir>] [--json]
//   node "${CLAUDE_PLUGIN_ROOT}/lib/pin-reconcile.mjs" --backfill        record hashes for every pin that has none
//   node "${CLAUDE_PLUGIN_ROOT}/lib/pin-reconcile.mjs" --record <key>    (re)record one pin's hashes
//   node "${CLAUDE_PLUGIN_ROOT}/lib/pin-reconcile.mjs" --help             the table format and the verdicts
//
// Prints one table row per pin (key, verdict, detail) and exits 0; 2 on a
// usage error, a missing manifest, or a .myspec.json that is missing or not
// a JSON object.
// Only --backfill and --record write, and only the hash fields of a pin.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getSetting, loadSchema } from './myspec-config.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const END_MARKER = '<!-- myspec:framework-end -->';

export const VERDICTS = {
  drop: 'the project file equals the plugin copy; the pin keeps nothing, offer to drop it',
  review: 'unchanged since the pin was recorded, but upstream moved under it; show the diff and ask',
  keep: 'the project still edits the file, or nothing moved; leave it',
  unrecorded: 'no hashes recorded; run --backfill (such a pin cannot report review until the next update)',
  missing: 'the pinned file does not exist; offer to drop the pin',
  retired: 'retired upstream (a removed entry, or a hooks/ or lib/ copy); offer to drop the pin',
  unknown: 'no manifest entry for this key; a misspelled or long-gone pin',
};

const HELP = `pin-reconcile.mjs: what each pin in .myspec.json frameworkFiles is still doing (#160)

usage: node pin-reconcile.mjs [--root <checkout>] [--plugin-root <dir>] [--json]
       node pin-reconcile.mjs --backfill          record hashes for every pin that has none
       node pin-reconcile.mjs --record <key>...   (re)record the hashes of the named pins
       node pin-reconcile.mjs --help

Table: one row per pin, tab-separated columns

  key         the manifest key the pin names (rules/workflow.md, pre-flight.md)
  verdict     one of the words below
  detail      the pin reason, then what the hashes say

Verdicts:
${Object.entries(VERDICTS).map(([v, text]) => `  ${v.padEnd(11)} ${text}`).join('\n')}

Each pin carries hash (the project's file) and upstreamHash (the plugin's rendered
copy) as of the moment it was recorded. drop compares the file with the plugin copy
now; review and keep compare each side with its recorded hash. A marker-merge file
is compared and hashed on its framework-owned region (line 1 through ${END_MARKER}).
--backfill and --record write those two fields and nothing else; the verdict
after a backfill is keep, since both sides were recorded as they are now, or
drop for a pin that still equals the plugin copy. --backfill records a drop pin
too, so one the user keeps reports review when upstream next moves under it.
`;

const sha256 = (text) => createHash('sha256').update(text).digest('hex');

function frameworkRegion(text) {
  const at = text.indexOf(END_MARKER);
  if (at === -1) { return null; }
  const end = text.indexOf('\n', at);
  return end === -1 ? text : text.slice(0, end + 1);
}

// manifestEntry(manifest, key, aiDir, pluginRoot) -> {source, dest, type} for a
// files or rules entry, {retired: true} for a removed one or a hooks/lib copy,
// null when the manifest has no such key.
export function manifestEntry(manifest, key, aiDir, pluginRoot) {
  if (manifest.files && Object.hasOwn(manifest.files, key)) {
    const dest = key.startsWith('templates/') ? `${aiDir}/.templates/${key.slice('templates/'.length)}` : `${aiDir}/${key}`;
    return { source: join(pluginRoot, 'framework-files', key), dest, type: manifest.files[key].type };
  }
  // A rule's pin key is rules/<name> (README, update); the manifest lists
  // <name> under its rules block.
  if (key.startsWith('rules/') && manifest.rules && Object.hasOwn(manifest.rules, key.slice('rules/'.length))) {
    const name = key.slice('rules/'.length);
    const entry = manifest.rules[name];
    return { source: join(pluginRoot, 'framework-files', 'rules', name), dest: entry.dest, type: entry.type };
  }
  if ((manifest.removed && Object.hasOwn(manifest.removed, key)) || /^(hooks|lib)\//.test(key)) {
    return { retired: true };
  }
  return null;
}

// reconcile({root, pluginRoot, manifest, pins, aiDir}) -> rows [{key, verdict,
// detail, reason, hashes}], one per pin, in the pins' order.
export function reconcile({ root, pluginRoot, manifest, pins, aiDir }) {
  return Object.entries(pins).map(([key, pin]) => {
    const reason = pin && typeof pin === 'object' && typeof pin.pinned === 'string' ? pin.pinned : '';
    const row = (verdict, detail, hashes = {}) => ({ key, verdict, detail: reason ? `pinned: ${reason}; ${detail}` : detail, reason, hashes });
    const entry = manifestEntry(manifest, key, aiDir, pluginRoot);
    if (entry === null) { return row('unknown', 'no manifest entry'); }
    if (entry.retired) { return row('retired', 'retired upstream'); }
    const dest = join(root, entry.dest);
    if (!existsSync(dest)) { return row('missing', `${entry.dest} does not exist`); }
    if (!existsSync(entry.source)) { return row('unknown', `plugin copy ${entry.source} does not exist`); }
    const project = readFileSync(dest, 'utf8');
    const plugin = readFileSync(entry.source, 'utf8').split('${aiDir}').join(aiDir);
    // A marker-merge file is compared and hashed on its framework-owned
    // region: the project section is the project's to edit, so neither an
    // edit there nor a change to the plugin's template for it moves a pin.
    const regions = entry.type === 'marker-merge' && frameworkRegion(project) !== null && frameworkRegion(plugin) !== null;
    const ours = regions ? frameworkRegion(project) : project;
    const theirs = regions ? frameworkRegion(plugin) : plugin;
    const hashes = { file: sha256(ours), upstream: sha256(theirs) };
    const same = ours === theirs;
    if (same) {
      return row('drop', regions ? 'the framework-owned region equals the plugin copy' : 'the file equals the plugin copy', hashes);
    }
    const recorded = typeof pin?.hash === 'string' ? pin.hash : null;
    const recordedUpstream = typeof pin?.upstreamHash === 'string' ? pin.upstreamHash : null;
    if (recorded === null) { return row('unrecorded', 'no hash recorded; run --backfill', hashes); }
    if (recorded !== hashes.file) { return row('keep', 'the project changed the file since the pin was recorded', hashes); }
    if (recordedUpstream !== null && recordedUpstream !== hashes.upstream) {
      return row('review', 'unchanged since the pin was recorded; the plugin copy moved under it', hashes);
    }
    return row('keep', recordedUpstream === null ? 'unchanged since the pin was recorded; no upstreamHash, so an upstream move cannot be told until recorded' : 'nothing moved on either side', hashes);
  });
}

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

// writePins(path, update) rewrites .myspec.json with update(frameworkFiles)
// applied, in the file's own indentation, touching nothing else.
function writePins(path, update) {
  const text = readFileSync(path, 'utf8');
  const data = JSON.parse(text);
  const indent = text.match(/^\{\n(\s+)"/)?.[1] ?? '  ';
  update(data.frameworkFiles);
  writeFileSync(path, `${JSON.stringify(data, null, indent)}\n`);
}

function defaultRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return process.cwd();
  }
}

function cli(argv) {
  const opts = { root: null, pluginRoot: null, json: false, backfill: false, record: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { process.stdout.write(HELP); return 0; }
    if (a === '--json') { opts.json = true; }
    else if (a === '--backfill') { opts.backfill = true; }
    else if (a === '--root' && argv[i + 1]) { opts.root = argv[++i]; }
    else if (a === '--plugin-root' && argv[i + 1]) { opts.pluginRoot = argv[++i]; }
    else if (a === '--record' && argv[i + 1]) { opts.record.push(argv[++i]); }
    else { process.stderr.write(`pin-reconcile: unknown argument ${a}\n${HELP}`); return 2; }
  }
  const root = opts.root ?? defaultRoot();
  const pluginRoot = opts.pluginRoot ?? dirname(HERE);
  const configPath = join(root, loadSchema().files.project);
  const manifestPath = join(pluginRoot, 'framework-files', 'manifest.json');
  if (!existsSync(configPath)) { process.stderr.write(`pin-reconcile: no ${configPath}\n`); return 2; }
  if (!existsSync(manifestPath)) { process.stderr.write(`pin-reconcile: no manifest at ${manifestPath}\n`); return 2; }
  let manifest;
  try { manifest = readJsonFile(manifestPath); } catch (e) { process.stderr.write(`pin-reconcile: ${manifestPath}: ${e.message}\n`); return 2; }
  // The reader turns a file that is not a JSON object into the defaults,
  // which would read as "no pins" and let a backfill pass having recorded
  // nothing; and writePins could not rewrite it anyway.
  let config;
  try { config = readJsonFile(configPath); } catch (e) { process.stderr.write(`pin-reconcile: ${configPath}: ${e.message}\n`); return 2; }
  if (config === null || typeof config !== 'object' || Array.isArray(config)) {
    process.stderr.write(`pin-reconcile: ${configPath} is not a JSON object\n`);
    return 2;
  }

  const settings = (key) => getSetting(key, { root });
  const aiDirSetting = settings('aiDir');
  for (const w of [...aiDirSetting.warnings, ...settings('frameworkFiles').warnings]) { process.stderr.write(`pin-reconcile: ${w}\n`); }
  const aiDir = String(aiDirSetting.value || loadSchema().keys.aiDir.default).replace(/^\.\//, '').replace(/\/+$/, '');
  const pins = settings('frameworkFiles').value;
  const hasPins = pins !== null && typeof pins === 'object' && !Array.isArray(pins) && Object.keys(pins).length > 0;
  for (const key of opts.record) {
    if (!hasPins || !Object.hasOwn(pins, key)) { process.stderr.write(`pin-reconcile: --record ${key}: no such pin\n`); return 2; }
  }
  if (!hasPins) {
    if (opts.json) { process.stdout.write('[]\n'); } else { process.stdout.write('no pins in .myspec.json frameworkFiles\n'); }
    return 0;
  }

  let rows = reconcile({ root, pluginRoot, manifest, pins, aiDir });
  // --backfill takes every pin without a hash, a drop one included: a drop
  // the user declines would otherwise stay hashless, show unrecorded when
  // upstream next moves, and be backfilled as keep, hiding the move.
  const hashless = (key) => typeof pins[key]?.hash !== 'string';
  const toRecord = rows.filter((r) => r.hashes.file && (opts.record.includes(r.key) || (opts.backfill && hashless(r.key))));
  if (toRecord.length > 0) {
    writePins(configPath, (ff) => {
      for (const r of toRecord) {
        ff[r.key].hash = r.hashes.file;
        ff[r.key].upstreamHash = r.hashes.upstream;
      }
    });
    rows = reconcile({ root, pluginRoot, manifest, pins: readJsonFile(configPath).frameworkFiles, aiDir });
    for (const r of toRecord) {
      const now = rows.find((x) => x.key === r.key);
      now.detail = `${now.detail}; recorded hash and upstreamHash now`;
      now.recorded = true;
    }
  }
  for (const key of opts.record) {
    const r = rows.find((x) => x.key === key);
    if (!r.recorded) { process.stderr.write(`pin-reconcile: --record ${key}: nothing to hash (${r.verdict}: ${r.detail})\n`); }
  }

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(rows.map(({ key, verdict, detail, reason, hashes, recorded }) => ({ key, verdict, detail, reason, hashes, recorded: recorded === true })), null, 2)}\n`);
    return 0;
  }
  process.stdout.write('key\tverdict\tdetail\n');
  for (const r of rows) { process.stdout.write(`${r.key}\t${r.verdict}\t${r.detail}\n`); }
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
