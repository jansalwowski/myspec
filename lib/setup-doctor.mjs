#!/usr/bin/env node
// setup-doctor.mjs
// Reports where a myspec installation has drifted from what the framework
// assumes. Read-only: it never edits a file, so it is safe to run from a hook,
// from bootstrap, and against someone else's checkout.
//
// WHY: `.myspec.json` records a per-file version for every framework file and
// nothing ever read it back — the only mechanical check was the scalar
// `frameworkVersion`, so a hand-edited rule, a half-applied update, or a hook
// copied but never registered all read as "current". Everything else in that
// space (settings wiring, hook executability, schema validity of
// `.myspec.json` / `verification.json` / `features/index.yaml`, always-loaded
// token budgets) was described in prose inside the `doctor` skill and re-derived
// by a language model on every run, non-reproducibly and at six-subagent cost.
// This is the deterministic half, extracted: same facts, same answer twice,
// in about a second.
//
// It is deliberately NOT a place for judgment. Duplication, contradictions,
// claims that disagree with the code, description quality — those stay in
// the `doctor` skill, which now runs this first and is handed the result
// instead of rediscovering it.
//
// Severity follows the Clippy rule: a check defaults to `error` only when it
// is deterministic and has no plausible false positive. Anything a project
// might be doing on purpose (an unregistered hook, a path-shaped token in
// prose, a fat rule file) is a warning and never blocks.
//
// Who runs it: `bootstrap` at session start (reported, non-blocking),
// `update` after copying files, the `doctor` skill phase 0 (as its ground
// truth), and the stop hook for the `wiring` and `schema` groups only —
// framework drift is advisory because the honest cause is usually a pending
// `/myspec:update`, and blocking on that would halt every commit made
// between a plugin release and the next update run. `features` is excluded
// from the gate too: it reads a file outside the gate trigger, so blocking on
// it would stop a session over something the session never touched.
//
// Usage:
//   setup-doctor.mjs [--root <path>] [--plugin-root <path>]
//                    [--quiet] [--json] [--list-checks] [<group|check>...]
//
//   --root         checkout to examine; defaults to this git checkout
//   --plugin-root  the myspec plugin; defaults to $CLAUDE_PLUGIN_ROOT, else a
//                  walk up from this script. Unresolvable (the normal case in
//                  an installed project, where this file lives in
//                  .claude/lib/) skips the checks that need the plugin as the
//                  reference copy, and says so.
//   --quiet        errors and the summary only
//   --json         { errors: [...], warnings: [...], notes: [...] } of
//                  { id, group, path, detail, remediation: { commands, text } }
//   positional     limit the run to one or more groups (install, wiring,
//                  schema, features, budget, refs) or to a single check id
//
// Exit 1 when any error was found, 2 on a usage error, else 0.

import {
  existsSync,
  readdirSync,
  readFileSync,
  statSync,
} from 'node:fs';
import {
  dirname,
  join,
  relative,
  resolve,
} from 'node:path';
import {
  execFileSync,
} from 'node:child_process';
import {
  fileURLToPath,
} from 'node:url';

import {
  aiDirFor,
  frontmatterOf,
} from './memory-files.mjs';

const MARKER_START = '<!-- myspec:framework-start -->';
const MARKER_END = '<!-- myspec:framework-end -->';

// wc -c / 4, the measure the rule budgets are written against.
const CLAUDE_MD_BUDGET = 800;
const RULE_BUDGET = 1000;

const GROUPS = {
  install: ['framework-missing', 'framework-drift', 'marker-missing', 'marker-header-drift', 'framework-unlisted', 'shipped-missing', 'shipped-drift'],
  wiring: ['settings-unparseable', 'hook-missing', 'hook-not-executable', 'hook-unregistered', 'hook-syntax', 'wiring-incomplete', 'tooling-absent'],
  schema: ['myspec-unparseable', 'myspec-missing-key', 'aidir-trailing-slash', 'aidir-missing', 'verification-unparseable', 'verification-empty'],
  // Separate from `schema` on purpose: the stop hook blocks on `wiring` and
  // `schema`, and it triggers on uncommitted changes under `.claude/` and
  // `.myspec.json`. The features manifest lives under ${aiDir}, so leaving it
  // in `schema` would block a stop over a settings.json edit because of a
  // months-old indent in an unrelated file.
  features: ['features-index-unreadable'],
  budget: ['over-budget'],
  refs: ['dead-path-ref', 'dead-skill-ref'],
};

// --- arguments ---------------------------------------------------------------

const argv = process.argv.slice(2);
let rootArg = null;
let pluginArg = null;
let quiet = false;
let json = false;
let listChecks = false;
const selectors = [];

function usage(stream = process.stderr) {
  stream.write('usage: setup-doctor.mjs [--root <path>] [--plugin-root <path>] [--quiet] [--json] [--list-checks] [<group|check>...]\n');
}

for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];

  if (arg === '--root') {
    rootArg = argv[i + 1];
    i += 1;
  } else if (arg.startsWith('--root=')) {
    rootArg = arg.slice('--root='.length);
  } else if (arg === '--plugin-root') {
    pluginArg = argv[i + 1];
    i += 1;
  } else if (arg.startsWith('--plugin-root=')) {
    pluginArg = arg.slice('--plugin-root='.length);
  } else if (arg === '--quiet') {
    quiet = true;
  } else if (arg === '--json') {
    json = true;
  } else if (arg === '--list-checks') {
    listChecks = true;
  } else if (arg.startsWith('-')) {
    process.stderr.write(`setup doctor: unknown argument ${arg}\n`);
    usage();
    process.exit(2);
  } else {
    selectors.push(arg);
  }
}

if (listChecks) {
  Object.entries(GROUPS).forEach(([group, ids]) => {
    ids.forEach((id) => process.stdout.write(`${group.padEnd(8)} ${id}\n`));
  });
  process.exit(0);
}

// A selector is a group name or a single check id; an id also selects its
// group, so the group runs and the report is filtered to that one check.
const selectedGroups = new Set();
const selectedIds = new Set();

selectors.forEach((selector) => {
  if (GROUPS[selector]) {
    selectedGroups.add(selector);

    return;
  }

  const owner = Object.keys(GROUPS).find((group) => GROUPS[group].includes(selector));

  if (!owner) {
    process.stderr.write(`setup doctor: unknown group or check ${selector} (see --list-checks)\n`);
    process.exit(2);
  }

  selectedGroups.add(owner);
  selectedIds.add(selector);
});

if (selectedGroups.size === 0) {
  Object.keys(GROUPS).forEach((group) => selectedGroups.add(group));
}

function wants(group) {
  return selectedGroups.has(group);
}

// --- roots -------------------------------------------------------------------

function gitRoot(cwd) {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch {
    return null;
  }
}

const root = resolve(rootArg || gitRoot(process.cwd()) || process.cwd());

// The plugin is the reference copy every install check compares against.
// Walk up from this file looking for framework-files/manifest.json: that finds
// the plugin when the script runs from the plugin's own lib/, and finds
// nothing when it runs from a project .claude/lib/, which is correct.
function resolvePluginRoot() {
  if (pluginArg) {
    return resolve(pluginArg);
  }

  if (process.env.CLAUDE_PLUGIN_ROOT && existsSync(join(process.env.CLAUDE_PLUGIN_ROOT, 'framework-files', 'manifest.json'))) {
    return resolve(process.env.CLAUDE_PLUGIN_ROOT);
  }

  let dir = dirname(fileURLToPath(import.meta.url));

  for (let i = 0; i < 6; i += 1) {
    if (existsSync(join(dir, 'framework-files', 'manifest.json'))) {
      return dir;
    }

    const parent = dirname(dir);

    if (parent === dir) {
      break;
    }

    dir = parent;
  }

  return null;
}

const pluginRoot = resolvePluginRoot();

// --- findings ----------------------------------------------------------------

const errors = [];
const warnings = [];
const notes = [];

function record(bucket, id, group, path, detail, remediation) {
  if (!wants(group)) {
    return;
  }

  if (selectedIds.size > 0 && !selectedIds.has(id)) {
    return;
  }

  bucket.push({
    id,
    group,
    path,
    detail,
    remediation: { commands: remediation?.commands || [], text: remediation?.text || '' },
  });
}

function error(id, group, path, detail, remediation) {
  record(errors, id, group, path, detail, remediation);
}

function warn(id, group, path, detail, remediation) {
  record(warnings, id, group, path, detail, remediation);
}

function note(text) {
  notes.push(text);
}

function rel(path) {
  return relative(root, path).split('\\').join('/');
}

function read(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
}

function readJson(path) {
  const source = read(path);

  if (source === null) {
    return { present: false, value: null, error: null };
  }

  try {
    return { present: true, value: JSON.parse(source), error: null };
  } catch (err) {
    return { present: true, value: null, error: err.message };
  }
}

function tokens(source) {
  return Math.round(Buffer.byteLength(source, 'utf8') / 4);
}

// Line endings and end-of-file whitespace are not drift; an update writing a
// file through a different tool changes them and nothing behaves differently.
function normalize(source) {
  return source.replace(/\r\n/g, '\n').replace(/\s+$/, '');
}

// `init` and `update` both replace `${aiDir}` in the files they copy, so the
// installed copy never matches the plugin source byte-for-byte — without this,
// every rule file carrying the placeholder reads as drift on every project.
//
// Both forms are accepted rather than one, because the two skills disagree
// about scope: `update` step 3 substitutes every manifest entry, while `init`
// step 4 substitutes only the ${aiDir} docs and leaves `.claude/rules/*` with
// the literal placeholder. A freshly initialised project and the same project
// after one update therefore hold different bytes for the same file, and
// neither is drift. Tighten this to one form once those two agree.
function matchesShipped(installed, shipped) {
  const target = normalize(installed);

  return target === normalize(shipped)
    || target === normalize(shipped.replace(/\$\{aiDir\}/g, aiDir));
}

// Everything above the framework marker: frontmatter, title, and the standing
// note. `marker-merge` cannot update it, which is the whole finding.
function markerHeader(source) {
  const start = source.indexOf(MARKER_START);

  return start === -1 ? null : normalize(source.slice(0, start));
}

function markerRegion(source) {
  const start = source.indexOf(MARKER_START);
  const end = source.indexOf(MARKER_END);

  if (start === -1 || end === -1 || end < start) {
    return null;
  }

  return normalize(source.slice(start + MARKER_START.length, end));
}

// --- config ------------------------------------------------------------------

const configPath = join(root, '.myspec.json');
const config = readJson(configPath);

if (!config.present) {
  const text = 'setup doctor: no .myspec.json — not a myspec project';

  if (json) {
    process.stdout.write(`${JSON.stringify({ errors: [], warnings: [], notes: [text] }, null, 2)}\n`);
  } else {
    process.stdout.write(`${text}\n`);
  }

  process.exit(0);
}

if (config.error) {
  error('myspec-unparseable', 'schema', '.myspec.json', `.myspec.json is not valid JSON: ${config.error} — every skill and hook reads it, so all of them silently fall back to defaults`, {
    commands: ['node -e "JSON.parse(require(\'fs\').readFileSync(\'.myspec.json\',\'utf8\'))"'],
  });
}

const settings = config.value || {};
const rawAiDir = typeof settings.aiDir === 'string' ? settings.aiDir : null;
const aiDir = aiDirFor(root);
const projectVersion = typeof settings.frameworkVersion === 'string' ? settings.frameworkVersion : null;
const frameworkFiles = settings.frameworkFiles && typeof settings.frameworkFiles === 'object' ? settings.frameworkFiles : {};

// --- schema ------------------------------------------------------------------

if (config.value) {
  if (rawAiDir === null) {
    error('myspec-missing-key', 'schema', '.myspec.json', '.myspec.json has no aiDir — every ${aiDir} path in every skill resolves to the .ai default instead', {
      text: 'add "aiDir": "<your docs dir>" to .myspec.json',
    });
  } else if (/\/$/.test(rawAiDir)) {
    error('aidir-trailing-slash', 'schema', '.myspec.json', `.myspec.json aiDir is ${JSON.stringify(rawAiDir)} — a trailing slash makes derived globs read ${rawAiDir}/*, which matches nothing, and the consumer goes silently dead`, {
      text: `set aiDir to ${JSON.stringify(rawAiDir.replace(/\/+$/, ''))}`,
    });
  } else if (!existsSync(join(root, rawAiDir))) {
    error('aidir-missing', 'schema', '.myspec.json', `.myspec.json aiDir points at ${rawAiDir}/, which does not exist`, {
      text: 'create the directory or correct aiDir',
    });
  }

  if (projectVersion === null) {
    error('myspec-missing-key', 'schema', '.myspec.json', '.myspec.json has no frameworkVersion — update and bootstrap cannot tell whether the install is current', {
      commands: ['/myspec:update'],
    });
  }
}

const verificationPath = join(root, '.claude', 'verification.json');
const verification = readJson(verificationPath);

if (verification.present && verification.error) {
  error('verification-unparseable', 'schema', '.claude/verification.json', `.claude/verification.json is not valid JSON: ${verification.error} — verify-before-stop.sh degrades to approve, so lint, type-check and tests stop running at all`, {
    commands: ['jq . .claude/verification.json'],
  });
} else if (verification.value && Array.isArray(verification.value.checks)) {
  // One finding, not one per check: a fresh init leaves all three blank, and
  // three lines saying the same thing is how a report starts being skimmed.
  const blank = verification.value.checks
    .filter((check) => check && check.required === true && !String(check.command || '').trim())
    .map((check) => String(check.name || '?'));

  if (blank.length > 0) {
    warn('verification-empty', 'schema', '.claude/verification.json', `.claude/verification.json: required check(s) ${blank.join(', ')} have an empty command — the stop gate reports them as passing without running anything`, {
      text: 'fill in the commands, or set "required": false',
    });
  }
}

// The features audit engine parses this file with a purpose-built reader that
// ignores what it does not recognise, so a mis-indented entry does not error —
// it disappears, and the manifest silently under-reports.
const featuresIndexPath = join(root, aiDir, 'features', 'index.yaml');
const featuresIndex = read(featuresIndexPath);

if (featuresIndex !== null) {
  const lines = featuresIndex.split(/\r?\n/);
  const hasFeaturesKey = lines.some((line) => /^features:/.test(line));

  if (!hasFeaturesKey) {
    error('features-index-unreadable', 'features', rel(featuresIndexPath), `${rel(featuresIndexPath)}: no top-level features: key — the manifest audit reads zero features from it`, {
      commands: ['node "${CLAUDE_PLUGIN_ROOT}/lib/features-status-audit/audit.mjs"'],
    });
  }

  lines.forEach((line, index) => {
    const entry = line.match(/^(\s*)-\s+name:/);

    if (entry && entry[1].length !== 2) {
      error('features-index-unreadable', 'features', `${rel(featuresIndexPath)}:${index + 1}`, `${rel(featuresIndexPath)}:${index + 1}: entry indented ${entry[1].length} space(s); the manifest parser only reads entries at exactly 2 — this feature is invisible to every status audit`, {
        text: 'reindent the entry to "  - name:" with 4-space fields',
      });
    }
  });
}

// --- install -----------------------------------------------------------------

const manifest = pluginRoot ? readJson(join(pluginRoot, 'framework-files', 'manifest.json')) : { present: false, value: null, error: null };

// Which always-loaded files the plugin owns. A finding in one of these is a
// myspec bug, not a project finding: the file is overwrite-managed, so acting
// on it means editing something the next update reverts. They are measured and
// reported as a note, never as a warning the reader cannot act on.
const managedDests = new Set();

if (manifest.value) {
  Object.entries(manifest.value.files || {}).forEach(([key, entry]) => {
    managedDests.add((entry && entry.dest) || (key.startsWith('templates/')
      ? `${aiDir}/.templates/${key.slice('templates/'.length)}`
      : `${aiDir}/${key}`));
  });

  Object.values(manifest.value.rules || {}).forEach((entry) => {
    if (entry && entry.dest) {
      managedDests.add(entry.dest);
    }
  });
}

if (!pluginRoot && wants('install')) {
  note('install checks skipped: plugin root not resolved (pass --plugin-root, or run from a skill where $CLAUDE_PLUGIN_ROOT is set)');
}

if (manifest.value && wants('install')) {
  const pluginVersion = manifest.value.frameworkVersion || null;
  const updatePending = Boolean(pluginVersion && projectVersion && pluginVersion !== projectVersion);

  // Drift while an update is pending is expected and the fix is one command;
  // drift at a matching version means the file was hand-edited or the update
  // half-applied, which nothing else will ever tell you.
  const driftSeverity = updatePending ? warn : error;
  const driftWhy = updatePending
    ? `project is on v${projectVersion}, plugin ships v${pluginVersion}`
    : `both sides claim v${projectVersion} — the file was hand-edited or an update half-applied`;
  const driftFix = { commands: ['/myspec:update'] };

  function sourceFor(block, key) {
    if (block === 'files') {
      return join(pluginRoot, 'framework-files', key);
    }

    if (block === 'rules') {
      return join(pluginRoot, 'framework-files', 'rules', key);
    }

    return join(pluginRoot, block, key);
  }

  function destFor(block, key, entry) {
    if (entry && entry.dest) {
      return entry.dest;
    }

    if (block !== 'files') {
      return null;
    }

    return key.startsWith('templates/')
      ? `${aiDir}/.templates/${key.slice('templates/'.length)}`
      : `${aiDir}/${key}`;
  }

  function trackingKey(block, key) {
    if (block === 'files') {
      return key;
    }

    return block === 'rules' ? `rules/${key}` : null;
  }

  function compare(block, key, entry, missingId, driftId) {
    const dest = destFor(block, key, entry);

    if (!dest) {
      return;
    }

    const tracked = trackingKey(block, key);
    const tracking = tracked ? frameworkFiles[tracked] : null;

    // A pin is a deliberate local fork; update refuses to touch it and so do we.
    if (tracking && tracking.pinned) {
      return;
    }

    const destPath = join(root, dest);
    const sourcePath = sourceFor(block, key);
    const installed = read(destPath);
    const shipped = read(sourcePath);

    if (shipped === null) {
      return;
    }

    if (installed === null) {
      error(missingId, 'install', dest, `${dest}: listed in the plugin manifest but not installed`, { commands: ['/myspec:update'] });

      return;
    }

    if (entry && entry.type === 'marker-merge') {
      const installedRegion = markerRegion(installed);
      const shippedRegion = markerRegion(shipped);

      if (installedRegion === null) {
        error('marker-missing', 'install', dest, `${dest}: no ${MARKER_START} / ${MARKER_END} markers — the next update cannot merge into it and will leave it stale forever`, {
          text: `wrap the framework section in ${MARKER_START} … ${MARKER_END}, using the plugin copy as the reference`,
        });

        return;
      }

      if (shippedRegion !== null && !matchesShipped(installedRegion, shippedRegion)) {
        driftSeverity(driftId, 'install', dest, `${dest}: framework section differs from the plugin copy (${driftWhy})`, driftFix);
      }

      // --- defect 2: what marker-merge structurally cannot deliver ---------
      // A title or frontmatter corrected upstream stays outside the markers,
      // so `update` reports the file synced while the stale text survives
      // forever. Always a warning, never an error: no command fixes it, and a
      // gate that blocks on something update cannot repair is a dead end.
      const installedHeader = markerHeader(installed);
      const shippedHeader = markerHeader(shipped);

      if (installedHeader !== null && shippedHeader !== null && !matchesShipped(installedHeader, shippedHeader)) {
        warn('marker-header-drift', 'install', dest, `${dest}: the header above ${MARKER_START} differs from the plugin copy — update merges only the marked region, so a correction shipped upstream can never reach this file`, {
          text: 'apply the plugin copy header by hand, or keep the local wording deliberately',
        });
      }

      return;
    }

    if (!matchesShipped(installed, shipped)) {
      driftSeverity(driftId, 'install', dest, `${dest}: differs from the plugin copy (${driftWhy})`, driftFix);
    }
  }

  ['files', 'rules'].forEach((block) => {
    Object.entries(manifest.value[block] || {}).forEach(([key, entry]) => {
      compare(block, key, entry, 'framework-missing', 'framework-drift');

      const tracked = trackingKey(block, key);

      if (tracked && !frameworkFiles[tracked]) {
        warn('framework-unlisted', 'install', '.myspec.json', `.myspec.json frameworkFiles has no entry for ${tracked} — its version is untracked, so update cannot tell whether it is current`, {
          commands: ['/myspec:update'],
        });
      }
    });
  });

  // Hooks and lib are the executing surface and are not tracked in
  // frameworkFiles at all, so drift here is both the most consequential and
  // the least visible: a stale hook keeps passing, a stale lib helper keeps
  // being sourced. Only checked when the project installed them.
  if (existsSync(join(root, '.claude', 'hooks'))) {
    ['hooks', 'lib'].forEach((block) => {
      Object.entries(manifest.value[block] || {}).forEach(([key, entry]) => {
        compare(block, key, entry, 'shipped-missing', 'shipped-drift');
      });
    });
  }
}

// --- wiring ------------------------------------------------------------------

function hookCommands(value) {
  const found = [];

  function walk(node) {
    if (Array.isArray(node)) {
      node.forEach(walk);

      return;
    }

    if (!node || typeof node !== 'object') {
      return;
    }

    if (typeof node.command === 'string') {
      found.push(node.command);
    }

    Object.values(node).forEach(walk);
  }

  walk(value);

  return found;
}

// Every event -> command pair, so a hook wired under the wrong event reads as
// missing rather than as present.
function hookPairs(value) {
  const pairs = new Set();
  const hooks = value && value.hooks && typeof value.hooks === 'object' ? value.hooks : {};

  Object.entries(hooks).forEach(([event, entries]) => {
    hookCommands(entries).forEach((command) => pairs.add(`${event} ${command}`));
  });

  return pairs;
}

const settingsPath = join(root, '.claude', 'settings.json');
const projectSettings = readJson(settingsPath);
const localSettings = readJson(join(root, '.claude', 'settings.local.json'));

[[projectSettings, '.claude/settings.json'], [localSettings, '.claude/settings.local.json']]
  .filter(([file]) => file.present && file.error)
  .forEach(([file, path]) => {
    error('settings-unparseable', 'wiring', path, `${path} is not valid JSON: ${file.error} — the harness loads no hooks at all from it`, {
      commands: [`jq . ${path}`],
    });
  });

const hooksDir = join(root, '.claude', 'hooks');
const registered = [
  ...hookCommands(projectSettings.value),
  ...hookCommands(localSettings.value),
];

registered.forEach((command) => {
  // The command may carry arguments; the script is the first token.
  const script = command.trim().split(/\s+/)[0];

  if (!script.endsWith('.sh')) {
    return;
  }

  const scriptPath = join(root, script.replace(/^\.\//, ''));

  if (!existsSync(scriptPath)) {
    error('hook-missing', 'wiring', script, `${script} is registered in settings but does not exist — the harness fails the hook on every matching tool call`, {
      commands: ['/myspec:update'],
    });

    return;
  }

  if ((statSync(scriptPath).mode & 0o111) === 0) {
    error('hook-not-executable', 'wiring', script, `${script} is registered but not executable — it never runs, and nothing reports that it did not`, {
      commands: [`chmod +x ${script}`],
    });
  }
});

if (existsSync(hooksDir)) {
  const registeredScripts = new Set(registered.map((command) => command.trim().split(/\s+/)[0].replace(/^\.\//, '')));

  readdirSync(hooksDir)
    .filter((name) => name.endsWith('.sh'))
    .forEach((name) => {
      const script = `.claude/hooks/${name}`;

      if (!registeredScripts.has(script)) {
        warn('hook-unregistered', 'wiring', script, `${script} exists but is registered in no settings file — copying a hook does nothing until it is wired`, {
          text: 'add it to .claude/settings.json under the right event, using the plugin templates/settings-hooks.json as the shape',
        });
      }
    });
}

// bash -n on everything that gets sourced or executed: a syntax error in a
// hook is silent at write time and only shows up as a mangled harness error.
[hooksDir, join(root, '.claude', 'lib')]
  .filter((dir) => wants('wiring') && existsSync(dir))
  .forEach((dir) => {
    readdirSync(dir)
      .filter((name) => name.endsWith('.sh'))
      .forEach((name) => {
        const path = join(dir, name);

        try {
          execFileSync('bash', ['-n', path], { stdio: 'pipe' });
        } catch (err) {
          const detail = String(err.stderr || err.message).trim().split('\n')[0];

          error('hook-syntax', 'wiring', rel(path), `${rel(path)}: bash -n fails — ${detail}`, {
            commands: [`bash -n ${rel(path)}`],
          });
        }
      });
  });

if (pluginRoot && projectSettings.value && existsSync(hooksDir)) {
  const template = readJson(join(pluginRoot, 'templates', 'settings-hooks.json'));

  if (template.value) {
    const have = hookPairs(projectSettings.value);
    const localHave = hookPairs(localSettings.value);

    [...hookPairs(template.value)]
      .filter((pair) => !have.has(pair) && !localHave.has(pair))
      .forEach((pair) => {
        const [event, ...rest] = pair.split(' ');

        warn('wiring-incomplete', 'wiring', '.claude/settings.json', `.claude/settings.json: ${rest.join(' ')} is not wired under ${event} — the plugin template registers it there`, {
          text: 'copy the entry from the plugin templates/settings-hooks.json',
        });
      });
  }
}

// The hooks degrade to approve when these are absent, which reads as a green
// gate rather than as a skipped one.
if (existsSync(hooksDir)) {
  ['jq', 'node'].forEach((binary) => {
    try {
      execFileSync('/bin/bash', ['-c', `command -v ${binary}`], { stdio: 'pipe' });
    } catch {
      warn('tooling-absent', 'wiring', '.claude/hooks/', `${binary} is not on PATH — the hooks that need it exit approve, so the gate passes without running`, {
        text: `install ${binary}`,
      });
    }
  });
}

// --- budget ------------------------------------------------------------------

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

const alwaysLoaded = [];

['CLAUDE.md', 'AGENTS.md'].forEach((name) => {
  const path = join(root, name);
  const source = read(path);

  if (source !== null) {
    alwaysLoaded.push({ path, source, budget: CLAUDE_MD_BUDGET, managed: managedDests.has(rel(path)) });
  }
});

ruleFiles(join(root, '.claude', 'rules')).forEach((path) => {
  const source = read(path);

  if (source === null) {
    return;
  }

  // A rule with paths: globs loads only for matching work; it is not on the
  // always-loaded budget and flagging it would be a false positive.
  if (/^paths:/m.test(frontmatterOf(source))) {
    return;
  }

  alwaysLoaded.push({ path, source, budget: RULE_BUDGET, managed: managedDests.has(rel(path)) });
});

const overBudget = alwaysLoaded.filter(({ source, budget }) => tokens(source) > budget);

overBudget
  .filter(({ managed }) => !managed)
  .forEach(({ path, source, budget }) => {
    warn('over-budget', 'budget', rel(path), `${rel(path)}: ~${tokens(source)} tokens against a ~${budget} budget — this is paid on every session`, {
      text: 'compress, or move activity-specific content behind paths: frontmatter',
    });
  });

const managedOverBudget = overBudget.filter(({ managed }) => managed);

if (managedOverBudget.length > 0 && wants('budget')) {
  note(`framework files over their always-loaded budget (plugin-owned — update overwrites local edits, report upstream): ${managedOverBudget.map(({ path, source }) => `${rel(path)} ~${tokens(source)}`).join(', ')}`);
}

// --- refs --------------------------------------------------------------------

const CODE_SPAN = /`([^`\n]+)`/g;
const PATH_SHAPE = /^[\w.@/-]+$/;

// Only a token that (a) looks like a path, (b) does not resolve, and (c) whose
// parent directory does exist. That last condition is what keeps the false
// positive rate down: a reference into a tree that is absent entirely is
// almost always illustrative prose, while a wrong filename inside a directory
// that is really there is a dead reference.
function deadPathRefs(source) {
  const dead = [];
  let match = CODE_SPAN.exec(source);

  while (match !== null) {
    const raw = match[1].replace(/\$\{aiDir\}/g, aiDir).replace(/^\.\//, '');

    // A trailing slash is how prose names a location ("ideas live under
    // `ai/ideas/`"), and `..` covers both parent traversal and the `foo/...`
    // ellipsis. Neither is a reference to a file that ought to exist.
    const looksLikePath = raw.includes('/')
      && PATH_SHAPE.test(raw)
      && !/^https?:/.test(raw)
      && !raw.endsWith('/')
      && !raw.includes('..');

    if (looksLikePath) {
      const target = join(root, raw);

      if (!existsSync(target) && existsSync(dirname(target))) {
        dead.push(raw);
      }
    }

    match = CODE_SPAN.exec(source);
  }

  return [...new Set(dead)];
}

const skillNames = pluginRoot && existsSync(join(pluginRoot, 'skills'))
  ? new Set(readdirSync(join(pluginRoot, 'skills')).filter((name) => existsSync(join(pluginRoot, 'skills', name, 'SKILL.md'))))
  : null;

alwaysLoaded.filter(({ managed }) => !managed).forEach(({ path, source }) => {
  deadPathRefs(source).forEach((raw) => {
    warn('dead-path-ref', 'refs', rel(path), `${rel(path)}: references ${raw}, which does not exist (its parent directory does)`, {
      text: 'correct the path or drop the reference',
    });
  });

  if (skillNames === null) {
    return;
  }

  const referenced = new Set([...source.matchAll(/\/myspec:([a-z0-9-]+)/g)].map((hit) => hit[1]));

  [...referenced]
    .filter((name) => !skillNames.has(name))
    .forEach((name) => {
      warn('dead-skill-ref', 'refs', rel(path), `${rel(path)}: routes to /myspec:${name}, which the installed plugin does not ship`, {
        text: 'correct the skill name, or update the plugin',
      });
    });
});

// --- report -------------------------------------------------------------------

const fixable = [...errors, ...warnings].filter((finding) => finding.remediation.commands.length > 0).length;
const summary = errors.length === 0 && warnings.length === 0
  ? 'setup doctor: clean'
  : `setup doctor: ${errors.length} error(s), ${warnings.length} warning(s)${fixable > 0 ? `, ${fixable} with a fix command` : ''}`;

if (json) {
  process.stdout.write(`${JSON.stringify({ errors, warnings, notes }, null, 2)}\n`);
} else {
  const lines = [];

  function render(level, finding) {
    lines.push(`${level} ${finding.id}: ${finding.detail}`);

    if (finding.remediation.commands.length > 0) {
      lines.push(`      run: ${finding.remediation.commands.join(' && ')}`);
    } else if (finding.remediation.text) {
      lines.push(`      fix: ${finding.remediation.text}`);
    }
  }

  errors.forEach((finding) => render('ERROR', finding));

  if (!quiet) {
    warnings.forEach((finding) => render('WARN ', finding));
    notes.forEach((text) => lines.push(`NOTE  ${text}`));
  }

  lines.push(summary);
  process.stdout.write(`${lines.join('\n')}\n`);
}

process.exit(errors.length > 0 ? 1 : 0);
