// myspec-config.mjs
// The one reader for myspec settings, for lib scripts (docs/project-settings-
// design.md, principle 4). Same semantics as lib/myspec-config.sh, which hooks
// use; lib/tests/myspec-config.test.sh runs both on the same fixtures and
// fails when they disagree.
//
// Usage:
//   node .claude/lib/myspec-config.mjs get <dotted.key> [--root <checkout>]
//   import { getSetting } from './myspec-config.mjs'
//   const { value, warnings } = getSetting('isolation.worktreeRoot', { root })
//
// Layers, in order; a later layer wins key by key (LAYERS below): the schema's
// defaults, the project files in the checkout, the session's MYSPEC_*
// overrides. Objects merge key by key; a list extends or replaces by the
// schema's `merge` for that key. A file that is not a JSON object, or a value
// of a type the schema does not allow, is ignored and named in `warnings`
// (on stderr from the CLI). Unknown keys pass through unchecked.

import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const SCHEMA_PATH = join(HERE, 'myspec-config.schema.json');

export function loadSchema(path = SCHEMA_PATH) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

// jq's `type` names, so both readers word their warnings the same way.
function jsonType(v) {
  if (v === null) { return 'null'; }
  if (Array.isArray(v)) { return 'array'; }
  return typeof v;
}

const isObject = (v) => jsonType(v) === 'object';

function getp(data, path) {
  let v = data;
  for (const s of path) {
    if (!isObject(v) || !Object.hasOwn(v, s)) { return { found: false }; }
    v = v[s];
  }
  return { found: true, v };
}

function setp(data, path, value) {
  let o = data;
  for (const s of path.slice(0, -1)) {
    if (!isObject(o[s])) { o[s] = {}; }
    o = o[s];
  }
  o[path[path.length - 1]] = value;
  return data;
}

function delp(data, path) {
  const parent = getp(data, path.slice(0, -1));
  if (parent.found && isObject(parent.v)) { delete parent.v[path[path.length - 1]]; }
}

const fileOf = (key) => (key.split('.')[0] === 'verification' ? 'verification' : 'project');
const plainKeys = (schema) => Object.entries(schema.keys).filter(([k]) => !k.includes('[]'));
const relevant = (k, req) => k === req || k.startsWith(`${req}.`) || req.startsWith(`${k}.`);

function parse(path, name, schema, req) {
  if (!existsSync(path)) { return { data: {}, warnings: [] }; }
  let d;
  try { d = JSON.parse(readFileSync(path, 'utf8')); } catch { d = null; }
  if (isObject(d)) { return { data: d, warnings: [] }; }
  return {
    data: {},
    warnings: fileOf(req) === name ? [`${schema.files[name]} is not a JSON object; ${req} falls back to the default`] : [],
  };
}

function sanitize(layer, schema, req) {
  for (const [key, entry] of plainKeys(schema)) {
    const segs = key.split('.');
    for (let i = 0; i < segs.length; i++) {
      const p = segs.slice(0, i + 1);
      const g = getp(layer.data, p);
      const leaf = i === segs.length - 1;
      if (!g.found) { break; }
      if (!leaf && isObject(g.v)) { continue; }
      if (leaf && entry.type.includes(jsonType(g.v))) { continue; }
      delp(layer.data, p);
      const at = p.join('.');
      if (relevant(at, req)) {
        const expected = leaf ? entry.type.join(' or ') : 'an object';
        const after = leaf ? 'it uses the default' : 'the keys under it use their defaults';
        layer.warnings.push(`ignoring ${at} in ${schema.files[entry.file]}: expected ${expected}, got ${jsonType(g.v)}; ${after}`);
      }
      break;
    }
  }
  return layer;
}

function layerDefault({ schema }) {
  const data = {};
  for (const [key, entry] of plainKeys(schema)) {
    if (Object.hasOwn(entry, 'default')) { setp(data, key.split('.'), structuredClone(entry.default)); }
  }
  return { name: 'default', data, warnings: [] };
}

function layerProject({ schema, root, req }) {
  const p = parse(join(root, schema.files.project), 'project', schema, req);
  const vPath = join(root, schema.files.verification);
  const v = parse(vPath, 'verification', schema, req);
  const layer = sanitize({
    name: 'project',
    data: { ...p.data, verification: v.data },
    warnings: [...p.warnings, ...v.warnings],
  }, schema, req);
  if (!existsSync(vPath)) { delete layer.data.verification; }
  return layer;
}

function layerSession({ schema, env }) {
  const data = {};
  for (const [name, entry] of Object.entries(schema.env)) {
    if (entry.kind !== 'override') { continue; }
    if (new RegExp(entry.match).test(env[name] ?? '')) { setp(data, entry.key.split('.'), entry.value); }
  }
  return { name: 'session', data, warnings: [] };
}

// The ordered layer list. A later layer wins; a per-machine layer slots in
// between project and session.
export const LAYERS = [layerDefault, layerProject, layerSession];

function merge(a, b, path, schema) {
  if (isObject(a) && isObject(b)) {
    const out = { ...a };
    for (const k of Object.keys(b)) {
      out[k] = Object.hasOwn(out, k) ? merge(out[k], b[k], [...path, k], schema) : b[k];
    }
    return out;
  }
  if (Array.isArray(a) && Array.isArray(b) && schema.keys[path.join('.')]?.merge === 'extend') {
    const same = (x, y) => JSON.stringify(x) === JSON.stringify(y);
    return [...a, ...b.filter((x) => !a.some((y) => same(x, y)))];
  }
  return b;
}

function defaultRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return process.cwd();
  }
}

// getSetting(key, {root, env, schema, layers}) -> {value, warnings}; value is
// null when no layer sets the key.
export function getSetting(key, opts = {}) {
  if (typeof key !== 'string' || !/^[^.]+(\.[^.]+)*$/.test(key)) {
    throw new Error(`myspec-config: '${key}' is not a dotted key`);
  }
  const ctx = {
    schema: opts.schema ?? loadSchema(),
    root: opts.root ?? defaultRoot(),
    env: opts.env ?? process.env,
    req: key,
  };
  const layers = (opts.layers ?? LAYERS).map((fn) => fn(ctx));
  let merged = {};
  for (const l of layers) { merged = merge(merged, l.data, [], ctx.schema); }
  const warnings = [...new Set(layers.flatMap((l) => l.warnings))];
  const g = getp(merged, key.split('.'));
  return { value: g.found ? g.v : null, warnings };
}

function cli(argv) {
  const usage = () => {
    process.stderr.write('usage: myspec-config.mjs get <dotted.key> [--root <checkout>]\n');
    return 2;
  };
  if (argv.length < 2 || argv[0] !== 'get') { return usage(); }
  const key = argv[1];
  let root;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--root' && i + 1 < argv.length) { root = argv[++i]; } else { return usage(); }
  }
  if (!/^[^.]+(\.[^.]+)*$/.test(key)) {
    process.stderr.write(`myspec-config: '${key}' is not a dotted key\n`);
    return 2;
  }
  if (root !== undefined && !existsSync(root)) {
    process.stderr.write(`myspec-config: --root '${root}' is not a directory\n`);
    return 2;
  }
  if (!existsSync(SCHEMA_PATH)) {
    process.stderr.write(`myspec-config: schema not found at ${SCHEMA_PATH}\n`);
    return 2;
  }
  const { value, warnings } = getSetting(key, { root });
  for (const w of warnings) { process.stderr.write(`myspec-config: ${w}\n`); }
  process.stdout.write(`${JSON.stringify(value)}\n`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = cli(process.argv.slice(2));
}
