// myspec-config.mjs
// The one reader for myspec settings, for lib scripts (docs/project-settings-
// design.md, principle 4). Same semantics as lib/myspec-config.sh, which hooks
// use; lib/tests/myspec-config.test.sh runs both on the same fixtures and
// fails when they disagree.
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}"/lib/myspec-config.mjs get <dotted.key> [--root <checkout>]
//   node "${CLAUDE_PLUGIN_ROOT}"/lib/myspec-config.mjs when '{"visualQuestions":"auto"}' [--root <checkout>]
//   import { getSetting } from './myspec-config.mjs'
//   const { value, warnings } = getSetting('isolation.worktreeRoot', { root })
//
// Layers, in order; a later layer wins key by key (LAYERS below): the schema's
// defaults, the project files in the checkout, the session's MYSPEC_*
// overrides. Objects merge key by key; a list extends or replaces by the
// schema's `merge` for that key. A file that is not a JSON object, or a value
// of a type the schema does not allow, is ignored and named in `warnings`
// (on stderr from the CLI). Unknown keys pass through unchecked.

import { existsSync, readFileSync, realpathSync } from 'node:fs';
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
// A `name[]` or `name.*` key types items or map values for doctor; the readers
// never look inside a list or a map.
const plainKeys = (schema) => Object.entries(schema.keys).filter(([k]) => !k.includes('[]') && !k.includes('.*'));
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

// whenHolds(when, opts) -> {holds, warnings}. `when` is a manifest entry's
// condition, {"<dotted.key>": <required value>, ...}: it holds when every key's
// effective value (getSetting, so schema defaults apply) equals the required
// one. An entry without `when` always holds. opts are getSetting's.
export function whenHolds(when, opts = {}) {
  if (when === undefined || when === null) { return { holds: true, warnings: [] }; }
  if (typeof when !== 'object' || Array.isArray(when)) {
    throw new Error(`myspec-config: a manifest condition must be an object of setting keys (got ${JSON.stringify(when)})`);
  }
  const warnings = [];
  let holds = true;
  for (const [key, required] of Object.entries(when)) {
    const got = getSetting(key, opts);
    warnings.push(...got.warnings);
    if (JSON.stringify(got.value) !== JSON.stringify(required)) { holds = false; }
  }
  return { holds, warnings: [...new Set(warnings)] };
}

function cli(argv) {
  const usage = () => {
    process.stderr.write('usage: myspec-config.mjs get <dotted.key> [--root <checkout>]\n       myspec-config.mjs when \'<manifest condition JSON>\' [--root <checkout>]\n');
    return 2;
  };
  if (argv.length < 2 || (argv[0] !== 'get' && argv[0] !== 'when')) { return usage(); }
  const key = argv[1];
  let root;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--root' && i + 1 < argv.length) { root = argv[++i]; } else { return usage(); }
  }
  if (argv[0] === 'when') { return cliWhen(key, root); }
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

// `when '<json>'`: prints true or false, whether a manifest entry's condition
// holds in the checkout; exits 2 on unparseable or non-object JSON.
function cliWhen(text, root) {
  let when;
  try { when = JSON.parse(text); } catch (e) {
    process.stderr.write(`myspec-config: the condition is not JSON: ${e.message}\n`);
    return 2;
  }
  if (root !== undefined && !existsSync(root)) {
    process.stderr.write(`myspec-config: --root '${root}' is not a directory\n`);
    return 2;
  }
  let result;
  try { result = whenHolds(when, { root }); } catch (e) {
    process.stderr.write(`${e.message}\n`);
    return 2;
  }
  for (const w of result.warnings) { process.stderr.write(`myspec-config: ${w}\n`); }
  process.stdout.write(`${result.holds}\n`);
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
