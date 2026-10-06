#!/usr/bin/env node
// setup-doctor.mjs
// Reports where a myspec installation has drifted from what the framework
// assumes. Read-only: it never edits a file, so it is safe to run from a hook,
// from bootstrap, and against someone else's checkout.
//
// WHY: until 2.0 `.myspec.json` recorded a per-file version for every framework
// file and nothing ever read it back — the only mechanical check was the scalar
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
//                  walk up from this script, which finds it since 3.0 (the
//                  doctor runs from the plugin's lib/, never from a copy).
//                  Unresolvable skips the checks that need the plugin as the
//                  reference copy, and says so.
//
// Hooks: since 3.0 the framework's hooks run from the plugin's hooks.json,
// which the harness merges with the project's own settings hooks. The wiring
// group therefore reports a framework hook that a settings file still runs
// (hook-wired-locally: it would run twice, from a stale copy) and a copy of a
// hook or lib still under .claude/ (hook-copy-retired), and checks the
// project's own hooks as before. The framework hook names come from the
// plugin's hooks.json through lib/settings-unwire.mjs, which update runs to
// remove those entries: one matcher for the finding and the fix. A hook
// started without CLAUDE_PLUGIN_ROOT says so itself (its lib-missing
// preamble); the doctor cannot observe that condition.
//   --quiet        errors and the summary only (no warnings, notes or settings)
//   --json         { errors: [...], warnings: [...], notes: [...] } of
//                  { id, group, path, detail, remediation: { commands, text } },
//                  plus settings: [...] of { key, value, source, loosens },
//                  and added: the entries over a list's default
//   positional     limit the run to one or more groups (install, wiring,
//                  schema, features, budget, refs, worktree, settings) or to a single
//                  check id
//
// Exit 1 when any error was found, 2 on a usage error, else 0.

import {
  existsSync,
  readdirSync,
  readFileSync,
  statSync,
} from 'node:fs';
import {
  basename,
  dirname,
  isAbsolute,
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
import {
  HOOK_INTERPRETERS,
  frameworkHookNames,
  frameworkHookOf as frameworkHookNamed,
  hookCommands,
} from './settings-unwire.mjs';
import { lstatSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';

const MARKER_START = '<!-- myspec:framework-start -->';
const MARKER_END = '<!-- myspec:framework-end -->';

// wc -c / 4, the measure the rule budgets are written against.
const CLAUDE_MD_BUDGET = 800;
const RULE_BUDGET = 1000;

const GROUPS = {
  install: ['framework-missing', 'framework-renamed', 'framework-removed', 'framework-drift', 'marker-missing'],
  wiring: ['settings-unparseable', 'hook-wired-locally', 'hook-copy-retired', 'hook-missing', 'hook-not-executable', 'hook-unregistered', 'hook-syntax', 'hook-command-relative', 'tooling-absent'],
  schema: ['myspec-unparseable', 'myspec-missing-key', 'aidir-trailing-slash', 'aidir-missing', 'verification-unparseable', 'verification-empty', 'verification-diff-unscoped', 'verification-exec-no-runin', 'verification-runin-no-workdir', 'setting-unknown-key', 'setting-wrong-type', 'setting-unknown-ref', 'setting-unmatched-item', 'setting-glob-unusable', 'setting-dir-missing'],
  // Separate from `schema` on purpose: the stop hook blocks on `wiring` and
  // `schema`, and it triggers on uncommitted changes under `.claude/` and
  // `.myspec.json`. The features manifest lives under ${aiDir}, so leaving it
  // in `schema` would block a stop over a settings.json edit because of a
  // months-old indent in an unrelated file.
  features: ['features-index-unreadable', 'note-over-cap', 'note-volatile', 'manifest-unknown-key'],
  budget: ['over-budget', 'over-budget-pinned'],
  refs: ['dead-path-ref', 'dead-skill-ref', 'topology-missing'],
  // Linked dependencies the Stop hook does not compare (#239). Not in the
  // stop hook's groups: a hand-made link is a lead, not a block.
  worktree: ['link-unrecorded', 'provision-stale', 'provision-link-dangling', 'provision-link-moved', 'provision-record-unreadable', 'provision-link-loads-main'],
  // Not findings: the settings that differ from their defaults, as SET lines
  // (`settings` in --json). Never in the stop hook's groups.
  settings: ['setting-in-force'],
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
// nothing only when the script was copied out of the plugin, which 3.0 never does.
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

// `init` and `update` replace `${aiDir}` in the DOCUMENTS they copy — the
// `files` and `rules` blocks — so an installed doc never matches the plugin
// source byte-for-byte and both spellings have to pass. `init` substitutes only
// the ${aiDir} docs while `update` also does the rules, so a freshly
// initialised project and the same project after one update legitimately hold
// different bytes for the same rule file.
//
// `hooks` and `lib` are the opposite case: they resolve aiDir at runtime and
// carry `${aiDir}` as live shell and JS template-literal syntax. Substituting
// there is corruption, not installation — it freezes every path to the
// installing project's value and leaves helpers ignoring their own aiDir
// argument. Accepting the substituted form for them is what let that go
// unnoticed indefinitely (issue #74), so code is compared byte-for-byte and a
// substituted copy is reported as drift for `update` to overwrite.
function matchesShipped(installed, shipped, block) {
  const target = normalize(installed);

  if (target === normalize(shipped)) {
    return true;
  }

  if (block === 'hooks' || block === 'lib') {
    return false;
  }

  return target === normalize(shipped.replace(/\$\{aiDir\}/g, aiDir));
}

// Everything above the framework marker: frontmatter, title, and the standing
// note. Framework-owned since 2.0 — `update` rewrites it on every sync — so a
// difference here is ordinary framework drift, not a separate finding.
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
  // A check configured only as a diffCommand still counts as configured — the
  // stop gate runs that one in place of `command`.
  const blank = verification.value.checks
    .filter((check) => check && check.required === true
      && !String(check.command || '').trim()
      && !String(check.diffCommand || '').trim())
    .map((check) => String(check.name || '?'));

  if (blank.length > 0) {
    warn('verification-empty', 'schema', '.claude/verification.json', `.claude/verification.json: required check(s) ${blank.join(', ')} have an empty command — the stop gate reports them as passing without running anything`, {
      text: 'fill in the commands, or set "required": false',
    });
  }

  // A diffCommand that never reads $MYSPEC_BASE_REF is not diff-scoped: it
  // replaces the whole-repo command with something narrower for reasons the
  // gate cannot see, and the check silently stops covering the branch.
  // The gate exports the variable, so a diffCommand that hands off to a
  // script in the repo is scoped when that script reads it (issue #180).
  // $CLAUDE_PROJECT_DIR names the repo root, so a script behind it is
  // resolved and read like a relative one; any other variable stays unknown.
  const readsBaseRef = (diffCommand) => diffCommand.includes('MYSPEC_BASE_REF')
    || diffCommand.split(/[\s;&|()]+/)
      .filter((token) => token && !token.startsWith('-')
        && !token.replace(/\$\{CLAUDE_PROJECT_DIR\}|\$CLAUDE_PROJECT_DIR/g, '').includes('$'))
      .map((token) => normalizeHookScript(token))
      .some((token) => {
        const path = isAbsolute(token) ? token : join(root, token);

        try {
          return statSync(path).isFile() && (read(path) || '').includes('MYSPEC_BASE_REF');
        } catch {
          return false;
        }
      });
  const unscoped = verification.value.checks
    .filter((check) => check && String(check.diffCommand || '').trim()
      && !readsBaseRef(String(check.diffCommand)))
    .map((check) => String(check.name || '?'));

  if (unscoped.length > 0) {
    warn('verification-diff-unscoped', 'schema', '.claude/verification.json', `.claude/verification.json: diffCommand on ${unscoped.join(', ')} never references $MYSPEC_BASE_REF — it runs instead of the full command without being scoped to what this branch changed`, {
      text: 'scope the command to the base ref, e.g. git diff --name-only --diff-filter=ACMR "$MYSPEC_BASE_REF"',
    });
  }
}

// --- container checks (#220, #221) ---------------------------------------------
//
// The stop gate does not read a check's exec options. In a linked worktree it
// refuses a check without runIn whose command contains a container exec form
// (CONTAINER_EXEC_FORMS in lib/stop-gate/run.sh, matched the same way
// here), and it trusts a runIn check to use the workdir it exports. Both are
// knowable from the file, so they are warned about here, before a stop.

const CONTAINER_EXEC_FORMS = ['docker exec', 'docker container exec', 'docker compose exec', 'docker-compose exec', 'podman exec', 'podman container exec', 'podman compose exec', 'podman-compose exec'];
// Options that take a separate value, among the program and the exec
// options; any other option is a flag. -w/--workdir is handled apart.
const CONTAINER_VALUE_OPTS = new Set(['-f', '--file', '-p', '--project-name', '--project-directory', '--env-file', '--profile', '--ansi', '--progress', '--parallel', '-H', '--host', '-c', '--context', '--config', '-l', '--log-level', '--connection', '--url', '--identity', '--root', '--runroot', '-e', '--env', '-u', '--user', '--index', '--detach-keys', '--preserve-fds']);
// The short options among those, for a cluster such as -it or -Tw.
const CONTAINER_VALUE_SHORT = 'fpHcleu';
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// The hook's match: a form's words, options (and a value after each)
// allowed between them, the program called by any path.
function containerExecForm(command) {
  const c = ` ${command.replace(/[\t\n;|&()"']/g, ' ').replace(/ {2,}/g, ' ')} `;

  return CONTAINER_EXEC_FORMS.some((form) => new RegExp(`[ /]${form.split(' ').map(escapeRegExp).join('( -[^ ]+( [^ -][^ ]*)?)* ')} `).test(c));
}

// A short-flag cluster: 'workdir' when it sets the workdir (a w in it),
// 'value' when its last option takes the next word, 'flags' otherwise. The
// rest of a cluster after an option that takes a value is that value, as in
// the engines' parsers: -ew is -e w, not -e -w.
function shortCluster(word) {
  const s = word.slice(1);

  for (let i = 0; i < s.length; i += 1) {
    if (s[i] === 'w') {
      return 'workdir';
    }

    if (CONTAINER_VALUE_SHORT.includes(s[i])) {
      return i === s.length - 1 ? 'value' : 'flags';
    }
  }

  return 'flags';
}

// True when one of the command's simple commands is a container exec whose
// exec options, those before the container or service name, carry no
// -w/--workdir. A -w after the name belongs to the command run in the
// container. Quotes are dropped, so a `sh -c "docker exec ..."` is read too.
function execWithoutWorkdir(command) {
  const forms = CONTAINER_EXEC_FORMS.map((form) => form.split(' '));
  const segments = command.replace(/["']/g, '').split(/&&|\|\||[;|&()\n]/);

  return segments.some((segment) => {
    const words = segment.split(/\s+/).filter(Boolean);
    let path = null;
    let state = 'scan';

    for (let i = 0; i < words.length; i += 1) {
      const word = words[i];

      if (state === 'scan') {
        const name = word.split('/').pop();

        if (forms.some((form) => form[0] === name)) {
          path = [name];
          state = 'words';
        }
      } else if (state === 'words') {
        if (word.startsWith('-')) {
          if (CONTAINER_VALUE_OPTS.has(word)) {
            i += 1;
          }
        } else {
          path = [...path, word];
          const prefix = forms.filter((form) => path.every((w, j) => form[j] === w));

          if (prefix.some((form) => form.length === path.length)) {
            state = 'opts';
          } else if (prefix.length === 0) {
            state = 'scan';
          }
        }
      } else if (word === '--workdir' || word.startsWith('--workdir=')) {
        return false;
      } else if (word.startsWith('--')) {
        if (CONTAINER_VALUE_OPTS.has(word)) {
          i += 1;
        }
      } else if (word.length > 1 && word.startsWith('-')) {
        const kind = shortCluster(word);

        if (kind === 'workdir') {
          return false;
        }

        if (kind === 'value') {
          i += 1;
        }
      } else {
        return true;
      }
    }

    return state === 'opts';
  });
}

if (verification.value && Array.isArray(verification.value.checks)) {
  verification.value.checks.forEach((check) => {
    if (!check || typeof check !== 'object' || Array.isArray(check) || check.required !== true) {
      return;
    }

    const name = String(check.name || '?');
    const commands = [check.command, check.diffCommand].filter((command) => typeof command === 'string' && command.trim());
    const runIn = typeof check.runIn === 'string' && check.runIn !== '';

    if (!runIn && commands.some(containerExecForm)) {
      warn('verification-exec-no-runin', 'schema', '.claude/verification.json', `.claude/verification.json: check ${name} runs a container exec without runIn — in a linked worktree this check will be refused, because the container mounts another checkout`, {
        text: 'in .claude/verification.json, declare runIn and a containers entry: give the check "runIn": "<name>", add "containers": {"<name>": {"mountSource": ".", "mountTarget": "<the container path the checkout is mounted at>"}}, and pass -w "$MYSPEC_CHECK_WORKDIR" in its exec options, before the container or service name (https://github.com/jansalwowski/myspec/blob/main/docs/stop-gate.md, Per-check settings)',
      });
    }

    if (runIn && commands.some((command) => !command.includes('MYSPEC_CHECK_WORKDIR') && execWithoutWorkdir(command))) {
      warn('verification-runin-no-workdir', 'schema', '.claude/verification.json', `.claude/verification.json: check ${name} has runIn but its container exec passes neither -w/--workdir nor $MYSPEC_CHECK_WORKDIR — it will verify the container's default workdir, which mounts the main checkout, not a worktree`, {
        text: 'pass -w "$MYSPEC_CHECK_WORKDIR" in the exec options, before the container or service name',
      });
    }
  });
}

// --- settings schema (#233) ----------------------------------------------------
//
// Every key, type, format and cross-reference comes from
// lib/myspec-config.schema.json; this code names none of them. A setting the
// readers cannot use keeps its default, so a typo or a wrong type would
// otherwise change nothing and say nothing (docs/project-settings-design.md,
// principle 5).
//
// Severity: a wrong type and a reference to an undefined entry are errors.
// Both are deterministic, the readers drop the value (or the stop gate
// refuses the check), and the stop hook only sees them when this session
// edited the file. An unknown key, an unusable glob and a missing directory
// are warnings: a project or another tool may keep its own keys in the file,
// the readers skip a bad glob and keep the rest, and a directory can exist on
// the branch a worktree is created from without existing here.

let configLib = null;

try {
  configLib = await import('./myspec-config.mjs');
} catch {
  configLib = null;
}

let configSchema = null;

if (configLib) {
  try {
    configSchema = configLib.loadSchema();
  } catch {
    configSchema = null;
  }
}

if (!configSchema && (wants('schema') || wants('settings'))) {
  note('settings schema unavailable (myspec-config.mjs or myspec-config.schema.json missing next to setup-doctor.mjs) — project settings were not validated or listed; run /myspec:update');
}

function jsonType(value) {
  if (value === null) {
    return 'null';
  }

  return Array.isArray(value) ? 'array' : typeof value;
}

const isPlainObject = (value) => jsonType(value) === 'object';
const stableJson = (value) => JSON.stringify(value, (key, v) => (isPlainObject(v)
  ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, v[k]]))
  : v));

function editDistance(a, b) {
  const row = Array.from({ length: b.length + 1 }, (_, j) => j);

  for (let i = 1; i <= a.length; i += 1) {
    let diagonal = row[0];

    row[0] = i;

    for (let j = 1; j <= b.length; j += 1) {
      const above = row[j];

      row[j] = Math.min(row[j] + 1, row[j - 1] + 1, diagonal + (a[i - 1] === b[j - 1] ? 0 : 1));
      diagonal = above;
    }
  }

  return row[b.length];
}

// The closest candidate within a third of the name's length (at least 2
// edits), compared case-insensitively; null when none is that close.
function nearMiss(name, candidates) {
  let best = null;
  let bestDistance = Infinity;

  candidates.forEach((candidate) => {
    const distance = editDistance(name.toLowerCase(), candidate.toLowerCase());

    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  });

  return bestDistance <= Math.max(2, Math.floor(name.length / 3)) ? best : null;
}

// Keys under a non-project file are written with the file's name as their
// first segment (schema $comment); in the file itself that segment is absent.
function fileLabel(entryFile, key) {
  return entryFile === 'project' ? key : key.slice(entryFile.length + 1);
}

// name -> the parsed object of each schema file, or null when it is absent,
// unparseable or not an object.
function projectFiles(schema) {
  return Object.fromEntries(Object.keys(schema.files).map((name) => {
    const parsed = name === 'project' ? config : readJson(join(root, schema.files[name]));

    return [name, isPlainObject(parsed.value) ? parsed.value : null];
  }));
}

// The readers' shape: .myspec.json at the top, each other file under its name.
function projectData(files) {
  const data = { ...(files.project || {}) };

  Object.keys(files).filter((name) => name !== 'project').forEach((name) => {
    if (files[name]) {
      data[name] = files[name];
    } else {
      delete data[name];
    }
  });

  return data;
}

// occurrences(data, key) -> [{ label, value }] for every place data sets the
// schema key; a `name[]` segment visits each item of that list, a `*` segment
// each value of the map above it.
function occurrences(data, key) {
  const segments = key.split('.');
  const found = [];

  function visit(node, index, label) {
    if (index === segments.length) {
      found.push({ label, value: node });

      return;
    }

    const segment = segments[index];

    if (segment === '*') {
      if (isPlainObject(node)) {
        Object.keys(node).forEach((name) => visit(node[name], index + 1, label ? `${label}.${name}` : name));
      }

      return;
    }

    const list = segment.endsWith('[]');
    const name = list ? segment.slice(0, -2) : segment;

    if (!isPlainObject(node) || !Object.hasOwn(node, name)) {
      return;
    }

    const at = label ? `${label}.${name}` : name;

    if (!list) {
      visit(node[name], index + 1, at);
    } else if (Array.isArray(node[name])) {
      node[name].forEach((item, i) => visit(item, index + 1, `${at}[${i}]`));
    }
  }

  visit(data, 0, '');

  return found;
}

// A glob the readers accept: non-empty, not absolute, no `..` segment
// (hooks/verify-before-stop.sh glob_ere, hooks/mark-code-changed.sh, the clean
// step of lib/worktree-provision.sh).
function globProblem(glob) {
  if (typeof glob !== 'string' || glob.replace(/^(\.\/)+/, '') === '') {
    return 'it is empty';
  }

  if (glob.startsWith('/')) {
    return 'it is absolute';
  }

  if (`/${glob}/`.includes('/../')) {
    return 'it has a .. segment';
  }

  return null;
}

// relDir(value) -> the repo-relative directory a `format: "dir"` setting
// names, '' for the root, or null when it is unusable: the normalisation of
// rel_dir in lib/stop-gate/run.sh. A leading ./ and a trailing / are dropped,
// . and '' are the root, and an absolute value or a .. segment is refused,
// checked again after each strip (".//api" is "/api").
function relDir(value) {
  let v = value;

  for (;;) {
    if (v.startsWith('/') || v === '..' || v.startsWith('../') || v.endsWith('/..') || v.includes('/../')) {
      return null;
    }

    if (v.startsWith('./')) {
      v = v.slice(2);
    } else if (v.endsWith('/')) {
      v = v.slice(0, -1);
    } else {
      break;
    }
  }

  return v === '.' ? '' : v;
}

function validateSettings(schema) {
  const keys = schema.keys;
  const files = projectFiles(schema);
  const data = projectData(files);
  const pathOf = (entry) => schema.files[entry.file];
  // Every schema key and each of its ancestors; a key whose children are
  // listed is walked, any other key is opaque.
  const known = new Set();

  Object.keys(keys).forEach((key) => {
    key.split('.').forEach((_, i, segments) => known.add(segments.slice(0, i + 1).join('.')));
  });

  // The root's children are the keys with no dot at all.
  const childrenOf = (prefix) => (prefix === ''
    ? [...known].filter((key) => !key.includes('.'))
    : [...known]
      .filter((key) => key.startsWith(`${prefix}.`) && !key.slice(prefix.length + 1).includes('.'))
      .map((key) => key.slice(prefix.length + 1)));

  // Unknown keys. Keys starting with `$` ($schema, $comment) are JSON
  // conventions, not settings. A map whose values the schema types with a
  // `*` entry (frameworkFiles.*) accepts any key, and each value is walked as
  // that entry.
  function walk(node, schemaPath, label, file) {
    Object.keys(node).forEach((name) => {
      if (name.startsWith('$')) {
        return;
      }

      const key = schemaPath ? `${schemaPath}.${name}` : name;
      const at = label ? `${label}.${name}` : name;
      const value = node[name];
      // Another file's keys sit under its name only in the readers' merged
      // view; written into .myspec.json, that name is not a setting.
      const otherFile = schemaPath === '' && name !== 'project' && Object.hasOwn(schema.files, name);
      const schemaKey = known.has(key) && !otherFile ? key
        : childrenOf(schemaPath).includes('*') ? `${schemaPath}.*` : null;

      if (schemaKey) {
        if (Array.isArray(value) && childrenOf(`${schemaKey}[]`).length > 0) {
          value.forEach((item, i) => {
            if (isPlainObject(item)) {
              walk(item, `${schemaKey}[]`, `${at}[${i}]`, file);
            }
          });
        } else if (isPlainObject(value) && childrenOf(schemaKey).length > 0) {
          walk(value, schemaKey, at, file);
        }

        return;
      }

      const siblings = childrenOf(schemaPath).filter((sibling) => !sibling.endsWith('[]') && sibling !== '*'
        && !(schemaPath === '' && sibling !== 'project' && Object.hasOwn(schema.files, sibling)));
      const sibling = nearMiss(name, siblings);
      // No close sibling: the same name somewhere else in this file, which
      // is a key written at the wrong level.
      const elsewhere = sibling ? null : Object.keys(keys)
        .filter((other) => keys[other].file === file && other.split('.').pop() === name)
        .map((other) => fileLabel(file, other))[0];
      const hint = sibling
        ? ` (did you mean ${label ? `${label}.` : ''}${sibling}?)`
        : elsewhere ? ` (did you mean ${elsewhere}?)` : '';

      warn('setting-unknown-key', 'schema', schema.files[file], `${schema.files[file]}: ${at} is not a myspec setting${hint}; nothing reads it, so whatever it was meant to change keeps its default`, {
        text: sibling || elsewhere ? 'rename the key' : 'remove the key, or correct it against lib/myspec-config.schema.json',
      });
    });
  }

  Object.keys(schema.files).forEach((file) => {
    if (files[file]) {
      walk(files[file], file === 'project' ? '' : file, '', file);
    }
  });

  // Wrong types, as the reader sees them: the same check that makes it drop
  // the value, so doctor and the hooks cannot disagree on what was ignored.
  const unparseable = new Set();

  if (config.error) {
    unparseable.add(schema.files.project);
  }

  Object.keys(schema.files).filter((name) => name !== 'project').forEach((name) => {
    const parsed = readJson(join(root, schema.files[name]));

    if (parsed.present && parsed.error) {
      unparseable.add(schema.files[name]);
    }
  });

  const readerWarnings = new Set();

  Object.keys(keys).filter((key) => !key.includes('[]')).forEach((key) => {
    configLib.getSetting(key, { root, env: {}, schema }).warnings.forEach((text) => readerWarnings.add(text));
  });

  // A file that is not an object warns once per key read from it; it is
  // one problem, so it is one finding per file.
  const notObjectFiles = new Set();

  readerWarnings.forEach((text) => {
    const ignored = text.match(/^ignoring (\S+) in (.+?): (.*)$/);
    const notObject = text.match(/^(.+?) is not a JSON object/);
    const path = ignored ? ignored[2] : notObject ? notObject[1] : '.myspec.json';

    if (notObject && (unparseable.has(path) || notObjectFiles.has(path))) {
      return;
    }

    if (notObject) {
      notObjectFiles.add(path);
    }

    const detail = ignored
      ? `${path}: ${ignored[1]} is ignored — ${ignored[3]}`
      : notObject ? `${path}: ${path} is not a JSON object; every setting in it falls back to its default` : `${path}: ${text}`;

    error('setting-wrong-type', 'schema', path, detail, {
      text: 'give the setting a value of the type the schema allows (lib/myspec-config.schema.json)',
    });
  });

  // The readers never look inside a list's items or a map's values, so
  // `name[]`, `name[].field` and `name.*` entries are checked here.
  Object.entries(keys).filter(([key]) => key.includes('[]') || key.includes('.*')).forEach(([key, entry]) => {
    occurrences(data, key).forEach(({ label, value }) => {
      if (!entry.type.includes(jsonType(value))) {
        error('setting-wrong-type', 'schema', pathOf(entry), `${pathOf(entry)}: ${fileLabel(entry.file, label)} is ${jsonType(value)}, expected ${entry.type.join(' or ')} — the hook that reads it ignores or misreads it`, {
          text: `make it ${entry.type.join(' or ')}`,
        });
      }
    });
  });

  Object.entries(keys).forEach(([key, entry]) => {
    if (!entry.format && !entry.refersTo && !entry.itemOf) {
      return;
    }

    occurrences(data, key).forEach(({ label, value }) => {
      // A list setting of the wrong type is already a setting-wrong-type
      // error; reading it as one glob too would report it twice.
      if (entry.type.includes('array') && !Array.isArray(value)) {
        return;
      }

      const where = fileLabel(entry.file, label);
      const values = Array.isArray(value) ? value.map((v, i) => [`${where}[${i}]`, v]) : [[where, value]];

      values.forEach(([at, v]) => {
        if (entry.format === 'glob' && typeof v === 'string') {
          const problem = globProblem(v);

          if (problem) {
            warn('setting-glob-unusable', 'schema', pathOf(entry), `${pathOf(entry)}: ${at} is ${JSON.stringify(v)}, which is not a usable glob: ${problem} — the hook that reads it skips it, so the setting does less than it says`, {
              text: 'write a repo-relative glob from the repository root, e.g. "api/**" or "**/*.generated.*"',
            });
          }
        }

        if (entry.format === 'dir' && typeof v === 'string') {
          const dir = relDir(v);
          let isDir;

          try {
            isDir = dir !== null && statSync(join(root, dir || '.')).isDirectory();
          } catch {
            isDir = false;
          }

          if (!isDir) {
            warn('setting-dir-missing', 'schema', pathOf(entry), `${pathOf(entry)}: ${at} is ${JSON.stringify(v)}, which is not a repo-relative directory in this checkout — a run that reaches it stops there`, {
              text: 'correct the directory, or create it on the branch worktrees are made from',
            });
          }
        }

        // A subtraction by exact text that matches nothing drops nothing,
        // while the settings listing shows it as loosening a gate.
        if (entry.itemOf && typeof v === 'string') {
          const target = configLib.getSetting(entry.itemOf, { root, env: {}, schema }).value;

          if (!Array.isArray(target) || !target.includes(v)) {
            const targetKey = fileLabel(keys[entry.itemOf]?.file || 'project', entry.itemOf);

            warn('setting-unmatched-item', 'schema', pathOf(entry), `${pathOf(entry)}: ${at} is ${JSON.stringify(v)}, which is not an entry of ${targetKey} (its default and this project's entries) — it is matched by exact text, so it removes nothing`, {
              text: `copy the entry exactly as ${targetKey} lists it (lib/myspec-config.schema.json for the defaults), or remove it`,
            });
          }
        }

        if (entry.refersTo && typeof v === 'string') {
          const target = configLib.getSetting(entry.refersTo, { root, env: {}, schema }).value;

          if (!isPlainObject(target) || !Object.hasOwn(target, v)) {
            const targetFile = schema.files[keys[entry.refersTo]?.file] || pathOf(entry);
            const targetKey = fileLabel(keys[entry.refersTo]?.file || 'project', entry.refersTo);

            error('setting-unknown-ref', 'schema', pathOf(entry), `${pathOf(entry)}: ${at} names ${JSON.stringify(v)}, which ${targetKey} in ${targetFile} does not define — the hook that reads it refuses to act on it`, {
              text: `define ${JSON.stringify(v)} under ${targetKey}, or correct the name`,
            });
          }
        }
      });
    });
  });
}

if (configSchema && wants('schema')) {
  validateSettings(configSchema);
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
      commands: ['node "${CLAUDE_PLUGIN_ROOT}/lib/feature-status-audit/audit.mjs"'],
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

// A manifest `note:` is read by every skill that loads the manifest, so it is
// capped at one line of current state (issue #86). Left unbounded, agents
// append to it until it is a changelog of PR states and SHAs: one consumer
// note reached 33 KB on a single line, and most of its "not yet merged" claims
// were false by the time anyone read them. History belongs in the feature's
// CHANGELOG.md. Warnings, not errors: a long note costs tokens, it breaks
// nothing.
const NOTE_CAP = 150;
const VOLATILE_NOTE = [
  [/#\d+\b.*\b(draft|open|pending)\b/i, 'a PR/issue state'],
  [/not yet merged/i, 'a merge state'],
  // At least one digit and one a-f letter, so neither words ("defaced") nor
  // dates ("20260927") read as a SHA.
  [/\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b/i, 'a commit SHA'],
];

// [{ line, text, multiline }] for every `note:` field. Handles plain, quoted,
// and block-scalar (| / >) values, including continuation lines.
function manifestNotes(source) {
  const lines = source.split(/\r?\n/);
  const found = [];

  lines.forEach((line, index) => {
    const key = line.match(/^(\s*)(?:-\s+)?note:\s*(.*)$/);

    if (!key) {
      return;
    }

    const indent = key[1].length;
    const block = /^[|>][+-]?\d*\s*$/.test(key[2]);
    const parts = block ? [] : [key[2]];

    for (let next = index + 1; next < lines.length; next += 1) {
      const candidate = lines[next];

      if (candidate.trim() === '') {
        if (block) continue;
        break;
      }

      if (candidate.match(/^\s*/)[0].length <= indent) break;
      if (!block && /^\s*(-\s|[\w-]+:(\s|$))/.test(candidate)) break;
      parts.push(candidate.trim());
    }

    let text = parts.join(' ').trim();
    const quoted = text.match(/^(["'])([\s\S]*)\1$/);

    if (quoted) {
      text = quoted[2];
    }

    found.push({ line: index + 1, text, multiline: block || parts.length > 1 });
  });

  return found;
}

if (wants('features')) {
  const featuresDir = join(root, aiDir, 'features');
  const manifests = featuresIndex !== null ? [featuresIndexPath] : [];

  if (existsSync(featuresDir)) {
    readdirSync(featuresDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(featuresDir, entry.name, 'index.yaml'))
      .filter((path) => existsSync(path))
      .forEach((path) => manifests.push(path));
  }

  manifests.forEach((path) => {
    // A near-miss spelling of `note:` is invisible to the cap and volatility
    // checks below, and to every skill that reads the field, so a manifest
    // using `notes:` passed clean however long it grew (issue #180).
    // Only an entry's own keys count: a `Note:` line inside a block scalar
    // (`description: >`) or a nested mapping is value text, and renaming it
    // would corrupt that value.
    let entryColumn = null;
    let blockColumn = null;

    (read(path) || '').split(/\r?\n/).forEach((line, index) => {
      if (blockColumn !== null) {
        if (line.trim() === '' || line.match(/^\s*/)[0].length > blockColumn) return;
        blockColumn = null;
      }

      const item = line.match(/^(\s*-\s+)([A-Za-z_-]+):(?:\s+(.*))?$/);
      const key = item || line.match(/^(\s*)([A-Za-z_-]+):(?:\s+(.*))?$/);

      if (!key) return;

      const column = key[1].length;

      if (item) entryColumn = column;
      if (/^[|>][+-]?\d*\s*(#.*)?$/.test(key[3] || '')) blockColumn = column;

      if (column === entryColumn && /^notes?$/i.test(key[2]) && key[2] !== 'note') {
        const where = `${rel(path)}:${index + 1}`;

        warn('manifest-unknown-key', 'features', where, `${where}: ${key[2]}: is not a manifest key — the field is note:, so this one escapes the note cap and volatility checks and no skill reads it`, {
          text: `rename ${key[2]}: to note: and keep it to one line of current state`,
        });
      }
    });

    manifestNotes(read(path) || '').forEach(({ line, text, multiline }) => {
      const where = `${rel(path)}:${line}`;

      if (text.length > NOTE_CAP || multiline) {
        warn('note-over-cap', 'features', where, `${where}: note: is ${multiline ? 'multi-line, ' : ''}${text.length} chars — the cap is one line of ${NOTE_CAP}, and every skill that reads the manifest pays for the rest`, {
          text: 'replace it with the current state in one line; move history to the feature CHANGELOG.md',
        });
      }

      const hits = VOLATILE_NOTE.filter(([pattern]) => pattern.test(text)).map(([, label]) => label);

      if (hits.length > 0) {
        warn('note-volatile', 'features', where, `${where}: note: records ${hits.join(', ')} — volatile state that goes stale silently once the PR merges`, {
          text: 'drop PR, branch, and SHA state from the note; git and the forge own it',
        });
      }
    });
  });
}

// --- install -----------------------------------------------------------------

const manifest = pluginRoot ? readJson(join(pluginRoot, 'framework-files', 'manifest.json')) : { present: false, value: null, error: null };

// The framework's hooks, by script name: the commands the plugin's hooks.json
// runs (lib/settings-unwire.mjs reads it, and update removes the matching
// settings entries with the same matcher). Since 3.0 a settings entry running
// one of these, in any spelling ("$CLAUDE_PROJECT_DIR"/.claude/hooks/x.sh,
// bare, `bash "…/x.sh"`, even "${CLAUDE_PLUGIN_ROOT}"/hooks/x.sh), runs it a
// second time from a copy. Empty without a plugin root, so nothing is flagged
// on a guess.
const frameworkNames = frameworkHookNames(pluginRoot);

function frameworkHookOf(command) {
  return frameworkHookNamed(command, frameworkNames);
}

// The repo-relative paths of the hook and lib copies 3.0 retired: every
// manifest `removed` dest under .claude/hooks/ or .claude/lib/ whose `since`
// is 3.0 or later. An earlier retirement there (2.x had guard-git-branch.sh) is a plain
// deletion update already performs, and keeps its framework-removed finding.
const retiredCopies = new Set(
  Object.values((manifest.value && manifest.value.removed) || {})
    .filter((entry) => entry && typeof entry.dest === 'string' && /^(?:[3-9]|\d{2,})\./.test(String(entry.since || '')))
    .map((entry) => entry.dest)
    .filter((dest) => dest.startsWith('.claude/hooks/') || dest.startsWith('.claude/lib/')),
);

frameworkNames.forEach((name) => retiredCopies.add(`.claude/hooks/${name}`));

function isRetiredCopy(dest) {
  return retiredCopies.has(dest);
}

// The provisioning script the worktree findings tell the reader to run: the
// plugin's own, beside this file (nothing is copied into a project since 3.0).
const PROVISION = join(dirname(fileURLToPath(import.meta.url)), 'worktree-provision.sh');

// Which always-loaded files the plugin owns. A finding in one of these is a
// myspec bug, not a project finding: the file is overwrite-managed, so acting
// on it means editing something the next update reverts. They are measured and
// reported as a note, never as a warning the reader cannot act on.
const managedDests = new Set();

// dest -> { reason, source } for a managed file the project pinned. A pin is a
// deliberate local fork that update refuses to touch, which inverts the budget
// advice: the reader unpins to take the plugin copy, and reporting the size
// upstream is useless because upstream is not what they are loading.
const pinnedDests = new Map();

if (manifest.value) {
  Object.entries(manifest.value.files || {}).forEach(([key, entry]) => {
    const dest = (entry && entry.dest) || (key.startsWith('templates/')
      ? `${aiDir}/.templates/${key.slice('templates/'.length)}`
      : `${aiDir}/${key}`);

    managedDests.add(dest);

    const tracking = frameworkFiles[key];

    if (tracking && tracking.pinned) {
      pinnedDests.set(dest, {
        reason: tracking.pinned,
        source: pluginRoot ? join(pluginRoot, 'framework-files', key) : null,
      });
    }
  });

  Object.entries(manifest.value.rules || {}).forEach(([key, entry]) => {
    if (!entry || !entry.dest) {
      return;
    }

    managedDests.add(entry.dest);

    const tracking = frameworkFiles[`rules/${key}`];

    if (tracking && tracking.pinned) {
      pinnedDests.set(entry.dest, {
        reason: tracking.pinned,
        source: pluginRoot ? join(pluginRoot, 'framework-files', 'rules', key) : null,
      });
    }
  });
}

if (!pluginRoot && wants('install')) {
  note('install checks skipped: plugin root not resolved (pass --plugin-root, or run from a skill where $CLAUDE_PLUGIN_ROOT is set)');
}

// An update is pending while the plugin ships a newer version than the project
// records. Whatever update repairs is then expected to be out of date, and the
// fix is one command, so those findings are warnings until the versions match.
const pluginVersion = manifest.value ? manifest.value.frameworkVersion || null : null;
const updatePending = Boolean(pluginVersion && projectVersion && pluginVersion !== projectVersion);

if (manifest.value && wants('install')) {
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

  // The `frameworkFiles` key for a manifest entry, which is what a pin is
  // recorded against. `files` keys are bare (`anti-patterns.md`,
  // `templates/session-log.md`); every other block is prefixed with its own
  // name — `rules/workflow.md`. That is the spelling `update` looks pins up by
  // and the one the manifest's `removed` block uses (`hooks/x.sh`, `lib/x.sh`
  // for the copies 3.0 retired).
  function trackingKey(block, key) {
    return block === 'files' ? key : `${block}/${key}`;
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
      // A manifest entry can carry `renamedFrom` when the framework changed a
      // file's name. Until the project runs update, the old name is the file
      // that holds its content — reporting the new one as missing would be
      // true and useless, and would fire on every project the day the rename
      // ships. Name the migration instead, and never as an error: the project
      // is not broken, it is one update behind.
      const previous = entry && entry.renamedFrom
        ? destFor(block, entry.renamedFrom, { ...entry, dest: undefined })
        : null;

      // A marker-less old file (a redirect stub is the common case) has no
      // project section to carry; update moves it and then asks how to seed
      // the framework region, so the finding must not promise a carry-over.
      if (previous && existsSync(join(root, previous))) {
        const carries = entry.type !== 'marker-merge' || markerRegion(read(join(root, previous)) || '') !== null
          ? 'update moves it and carries the project section across'
          : 'it has no framework markers, so update moves it and then asks whether to replace it with the plugin copy, prepend the framework region above it, or pin it';

        warn('framework-renamed', 'install', previous, `${previous}: the framework renamed this to ${dest}; ${carries}. Until then every blueprint writing to ${dest} writes to a file nothing reads`, {
          commands: ['/myspec:update'],
        });

        return;
      }

      error(missingId, 'install', dest, `${dest}: listed in the plugin manifest but not installed`, { commands: ['/myspec:update'] });

      return;
    }

    // Both names present: the hand-rolled workaround for this rename, now
    // colliding with the framework's own. update refuses to guess here and so
    // does the doctor; only the project knows which one its blueprints write to.
    if (entry && entry.renamedFrom) {
      const previous = destFor(block, entry.renamedFrom, { ...entry, dest: undefined });

      if (previous && existsSync(join(root, previous))) {
        const oldMarkerless = entry.type === 'marker-merge' && markerRegion(read(join(root, previous)) || '') === null;

        warn('framework-renamed', 'install', previous, `${previous} and ${dest} both exist — the framework renamed the first to the second, so one of them is a stale duplicate that no skill updates`, {
          text: oldMarkerless
            ? `${previous} has no framework markers, so it holds no project section (usually a redirect stub) — delete it, or move anything worth keeping below the end marker of ${dest}; update offers both`
            : 'keep whichever holds the project content and delete the other — update offers to merge the two project sections',
        });
      }
    }

    if (entry && entry.type === 'marker-merge') {
      const installedRegion = markerRegion(installed);
      const shippedRegion = markerRegion(shipped);

      if (installedRegion === null) {
        // update asks: replace with the plugin copy, prepend the framework
        // region above the content, or pin. A pinned file never reaches here.
        error('marker-missing', 'install', dest, `${dest}: no ${MARKER_START} / ${MARKER_END} markers — update asks whether to replace it with the plugin copy, prepend the framework region above its content, or pin it; until then it stays stale`, {
          commands: ['/myspec:update'],
        });

        return;
      }

      // Since 2.0 the framework owns everything from line 1 through the end
      // marker — the header (frontmatter, title, standing note) as well as the
      // marked section — and update rewrites both. One finding names whichever
      // parts differ; two records with the same id for one file would read as
      // two problems.
      const parts = [];

      if (shippedRegion !== null && !matchesShipped(installedRegion, shippedRegion, block)) {
        parts.push('framework section');
      }

      const installedHeader = markerHeader(installed);
      const shippedHeader = markerHeader(shipped);

      if (installedHeader !== null && shippedHeader !== null && !matchesShipped(installedHeader, shippedHeader, block)) {
        parts.push(`header above ${MARKER_START}`);
      }

      if (parts.length > 0) {
        driftSeverity(driftId, 'install', dest, `${dest}: ${parts.join(' and ')} differ${parts.length === 1 ? 's' : ''} from the plugin copy (${driftWhy})`, driftFix);
      }

      return;
    }

    if (!matchesShipped(installed, shipped, block)) {
      driftSeverity(driftId, 'install', dest, `${dest}: differs from the plugin copy (${driftWhy})`, driftFix);
    }
  }

  ['files', 'rules'].forEach((block) => {
    Object.entries(manifest.value[block] || {}).forEach(([key, entry]) => {
      compare(block, key, entry, 'framework-missing', 'framework-drift');
    });
  });

  // Files the framework retired (manifest `removed`, 2.0). update deletes them;
  // until it runs the stale copy sits there beside nothing that reads it. A
  // pinned entry is a deliberate local keep and is not reported. The hook and
  // lib copies 3.0 retired are the wiring group's hook-copy-retired, below:
  // those are not deleted but moved, and they matter to the gates.
  Object.entries(manifest.value.removed || {}).forEach(([key, entry]) => {
    const dest = entry && typeof entry.dest === 'string' ? entry.dest.replace(/\$\{aiDir\}/g, aiDir) : null;
    const tracking = frameworkFiles[key];

    if (!dest || isRetiredCopy(dest) || (tracking && tracking.pinned) || !existsSync(join(root, dest))) {
      return;
    }

    warn('framework-removed', 'install', dest, `${dest}: retired by the framework${entry.since ? ` in v${entry.since}` : ''} — nothing reads it any more; update deletes it`, {
      commands: ['/myspec:update'],
    });
  });
}

// --- wiring ------------------------------------------------------------------

// A hook command may quote its script and name the project root as
// $CLAUDE_PROJECT_DIR — the form Claude Code recommends, because a bare
// relative command resolves against the session's cwd rather than the project
// (a nested worktree then fails every matching tool call). Both spellings name
// the same file, so every comparison below works on the resolved repo-relative
// path instead of the raw command string.
function normalizeHookScript(script) {
  return script
    .replace(/["']/g, '')
    // Replacer functions, not strings: `$&`, `$'` and `$1` inside a checkout
    // path are replacement patterns to String.replace, and would corrupt it.
    .replace(/\$\{CLAUDE_PROJECT_DIR\}/g, () => root)
    .replace(/\$CLAUDE_PROJECT_DIR/g, () => root)
    .replace(/^\.\//, '');
}

// The script a hook command runs, or null when it runs none. That is token 0,
// or token 1 behind an interpreter; a `.sh` any later is an argument to some
// other program (`npx prettier --check src/setup.sh`), and naming it the hook
// would report a file the harness never runs and mark a gate wired that is not.
// `execd` says whether the harness runs the file itself — the only case where
// its mode matters. `unresolved` says the path still holds a shell variable
// this process cannot expand, so nothing may claim the file is missing.
function hookScript(command) {
  const tokens = command.trim().split(/\s+/);
  const lead = normalizeHookScript(tokens[0] ?? '');
  const next = tokens.length > 1 ? normalizeHookScript(tokens[1]) : '';

  if (lead.endsWith('.sh')) {
    return hookScriptAt(lead, tokens.slice(1), true);
  }

  if (HOOK_INTERPRETERS.has(basename(lead)) && next.endsWith('.sh')) {
    return hookScriptAt(next, tokens.slice(2), false);
  }

  return null;
}

function hookScriptAt(normalized, args, execd) {
  return {
    path: isAbsolute(normalized) ? normalized : join(root, normalized),
    args,
    execd,
    unresolved: normalized.includes('$'),
  };
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

// A framework hook still registered in a settings file runs a second time,
// from a copy the plugin no longer updates, beside the plugin's own (Claude
// Code keeps a plugin's handler separate from a settings copy of the same
// command). settings.json is update's to repair; settings.local.json is the
// developer's own, so a warning there names the hand fix. An error at a
// matching version, a warning while an update is pending: the migration that
// unwires it lands with the version stamp.
[[projectSettings, '.claude/settings.json'], [localSettings, '.claude/settings.local.json']]
  .filter(([file]) => file.value)
  .forEach(([file, path]) => {
    hookCommands(file.value).forEach((command) => {
      const name = frameworkHookOf(command);

      if (!name) {
        return;
      }

      const repairable = path === '.claude/settings.json';
      const report = repairable && !updatePending ? error : warn;

      report('hook-wired-locally', 'wiring', path, `${path}: hook command "${command}" runs the framework hook ${name} — since 3.0 the plugin's hooks.json runs it, so this entry runs a stale copy a second time`, repairable
        ? { commands: ['/myspec:update'] }
        : { text: `delete that entry from ${path} by hand; the plugin runs ${name} itself` });
    });
  });

// A copy of a framework hook or lib helper still under .claude/ runs nothing
// (the plugin's own copy does the work) unless a settings entry still names it,
// which hook-wired-locally reports. update moves it to .claude/state/retired-3.0/
// rather than deleting it, so a hand-patched copy is never lost.
[...retiredCopies]
  .filter((dest) => existsSync(join(root, dest)))
  .sort()
  .forEach((dest) => {
    warn('hook-copy-retired', 'wiring', dest, `${dest}: a copy of the plugin's ${dest.startsWith('.claude/hooks/') ? 'hook' : 'lib helper'} — since 3.0 the plugin runs its own, and nothing reads this one; update moves it to .claude/state/retired-3.0/`, {
      commands: ['/myspec:update'],
    });
  });

registered.forEach((command) => {
  const script = hookScript(command);

  // A path this process cannot expand (a project's own variable) may be
  // perfectly valid at hook time, so it gets no verdict rather than a false
  // one — asserting it is missing blocks the stop gate on a file the doctor
  // never looked at. A framework hook is hook-wired-locally's, above.
  if (!script || script.unresolved || frameworkHookOf(command)) {
    return;
  }

  const scriptPath = script.path;
  // Report the resolved repo-relative path, not the raw token: a command may
  // register its script as "$CLAUDE_PROJECT_DIR"/... and that variable is not
  // set in the terminal the `run:` line gets pasted into.
  const label = rel(scriptPath);

  if (!existsSync(scriptPath)) {
    error('hook-missing', 'wiring', label, `${label} is registered in settings but does not exist — the harness fails the hook on every matching tool call`, {
      text: `restore ${label}, or delete its entry from the settings file`,
    });

    return;
  }

  // Only when the harness execs the file: `bash x.sh` runs a mode 644 script
  // by design, and calling that an error blocks every session over nothing.
  if (script.execd && (statSync(scriptPath).mode & 0o111) === 0) {
    error('hook-not-executable', 'wiring', label, `${label} is registered but not executable — it never runs, and nothing reports that it did not`, {
      commands: [`chmod +x ${label}`],
    });
  }
});

// A relative script path resolves against the session's cwd, not the project:
// once a session cd's into a subdirectory the shell reports `No such file or
// directory`, and on Stop that is a non-blocking error, so the hook is skipped
// with no warning (issue #217). A project's own hook is a warning: the doctor
// does not own what that hook guards, and the fix is the "$CLAUDE_PROJECT_DIR"/
// prefix by hand. A framework hook here is hook-wired-locally's.
[[projectSettings, '.claude/settings.json'], [localSettings, '.claude/settings.local.json']]
  .filter(([file]) => file.value)
  .forEach(([file, path]) => {
    hookCommands(file.value).forEach((command) => {
      const script = hookScript(command);

      if (!script || script.unresolved || frameworkHookOf(command)) {
        return;
      }

      const tokens = command.trim().split(/\s+/);
      const raw = (script.execd ? tokens[0] : tokens[1]).replace(/["']/g, '');

      if (isAbsolute(raw) || raw.startsWith('$')) {
        return;
      }

      const label = rel(script.path);

      warn('hook-command-relative', 'wiring', path, `${path}: hook command "${command}" runs ${label} by a relative path — it resolves against the session's cwd, so the hook fails once the session leaves the repo root`, {
        text: `add the "$CLAUDE_PROJECT_DIR"/ prefix by hand, e.g. "$CLAUDE_PROJECT_DIR"/${label}`,
      });
    });
  });

// A project's own hook script that no settings file wires. A retired
// framework copy is hook-copy-retired's, above.
if (existsSync(hooksDir)) {
  const registeredScripts = new Set(
    registered
      .map((command) => hookScript(command))
      .filter(Boolean)
      .map((script) => rel(script.path)),
  );

  readdirSync(hooksDir)
    .filter((name) => name.endsWith('.sh'))
    .forEach((name) => {
      const script = `.claude/hooks/${name}`;

      if (!registeredScripts.has(script) && !isRetiredCopy(script)) {
        warn('hook-unregistered', 'wiring', script, `${script} exists but is registered in no settings file — copying a hook does nothing until it is wired`, {
          text: 'a project hook goes under the right event in .claude/settings.json; the framework hooks run from the plugin and need no entry',
        });
      }
    });
}

// bash -n on every project-owned script that gets sourced or executed: a
// syntax error in a hook is silent at write time and only shows up as a
// mangled harness error. A retired framework copy runs nothing, so it is
// not parsed.
[hooksDir, join(root, '.claude', 'lib')]
  .filter((dir) => wants('wiring') && existsSync(dir))
  .forEach((dir) => {
    readdirSync(dir)
      .filter((name) => name.endsWith('.sh'))
      .map((name) => join(dir, name))
      .filter((path) => !isRetiredCopy(rel(path)))
      .forEach((path) => {
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

// The plugin's hooks degrade to approve when these are absent, which reads as
// a green gate rather than as a skipped one.
['jq', 'node'].forEach((binary) => {
  try {
    execFileSync('/bin/bash', ['-c', `command -v ${binary}`], { stdio: 'pipe' });
  } catch {
    warn('tooling-absent', 'wiring', 'hooks', `${binary} is not on PATH — the plugin hooks that need it exit approve, so the gate passes without running`, {
      text: `install ${binary}`,
    });
  }
});

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
    alwaysLoaded.push({ path, source, budget: CLAUDE_MD_BUDGET, managed: managedDests.has(rel(path)), pin: pinnedDests.get(rel(path)) || null });
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

  alwaysLoaded.push({ path, source, budget: RULE_BUDGET, managed: managedDests.has(rel(path)), pin: pinnedDests.get(rel(path)) || null });
});

const overBudget = alwaysLoaded.filter(({ source, budget }) => tokens(source) > budget);

overBudget
  .filter(({ managed }) => !managed)
  .forEach(({ path, source, budget }) => {
    warn('over-budget', 'budget', rel(path), `${rel(path)}: ~${tokens(source)} tokens against a ~${budget} budget — this is paid on every session`, {
      text: 'compress, or move activity-specific content behind paths: frontmatter',
    });
  });

// A pinned framework file is the project's fork, so this IS actionable by the
// reader — unpin — and is reported as a warning rather than a note. When the
// plugin copy is now the smaller of the two, say so: the pin is costing tokens
// it was taken to save, which is exactly the 2.0 rules diet's case.
overBudget
  .filter(({ managed, pin }) => managed && pin)
  .forEach(({ path, source, budget, pin }) => {
    const shipped = pin.source ? read(pin.source) : null;
    const comparison = shipped === null
      ? ''
      : tokens(shipped) < tokens(source)
        ? ` The plugin copy is now smaller (~${tokens(shipped)} tokens), so the pin costs more than it saves.`
        : ` The plugin copy is ~${tokens(shipped)} tokens.`;

    warn('over-budget-pinned', 'budget', rel(path), `${rel(path)}: ~${tokens(source)} tokens against a ~${budget} budget, and pinned in .myspec.json ("${pin.reason}") — update skips it, so it stays over budget until the pin is cleared.${comparison}`, {
      text: 'compare against the plugin copy and clear the pin to take it, or compress the local fork',
    });
  });

const managedOverBudget = overBudget.filter(({ managed, pin }) => managed && !pin);

if (managedOverBudget.length > 0 && wants('budget')) {
  note(`framework files over their always-loaded budget (plugin-owned — update overwrites local edits, report upstream): ${managedOverBudget.map(({ path, source }) => `${rel(path)} ~${tokens(source)}`).join(', ')}`);
}

// --- refs --------------------------------------------------------------------

const CODE_SPAN = /`([^`\n]+)`/g;
const PATH_SHAPE = /^[\w.@/-]+$/;

// root's git dir and common dir, resolved, or null outside a git checkout:
// one probe for mainCheckout and linkedWorktree.
let gitDirsCache;

function gitDirs() {
  if (gitDirsCache === undefined) {
    try {
      const [gitDir, commonDir] = execFileSync('git', ['rev-parse', '--git-dir', '--git-common-dir'], { cwd: root, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] })
        .trim().split('\n').map((dir) => resolve(root, dir));

      gitDirsCache = { gitDir, commonDir };
    } catch {
      gitDirsCache = null;
    }
  }

  return gitDirsCache;
}

// The main checkout when root is a linked worktree whose common dir is a
// main checkout's .git, else null.
function mainCheckout() {
  const dirs = gitDirs();

  return dirs && dirs.gitDir !== dirs.commonDir && basename(dirs.commonDir) === '.git' ? dirname(dirs.commonDir) : null;
}

// Run from a linked worktree, a reference to per-checkout state the main
// checkout holds (`.claude/worktrees`, where the worktrees themselves live)
// does not resolve, because that state never travels with a branch (issue
// #228). Such a path exists in the main checkout and git does not track it
// there. A tracked path missing here is still dead: this branch removed it.
function perCheckoutInMain(raw) {
  const main = mainCheckout();

  if (!main || !existsSync(join(main, raw))) {
    return false;
  }

  try {
    execFileSync('git', ['ls-files', '--error-unmatch', '--', raw], { cwd: main, stdio: 'pipe' });

    return false;
  } catch {
    return true;
  }
}

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
    // A lone `/word` is a slash command (`/bootstrap`, `/deps-check`) — a
    // project skill, command, or plugin skill — not a path. Joined to the
    // root it always has an existing parent, so every one used to be flagged.
    const looksLikePath = raw.includes('/')
      && PATH_SHAPE.test(raw)
      && !/^https?:/.test(raw)
      && !/^\/[^/]+$/.test(raw)
      && !raw.endsWith('/')
      && !raw.includes('..');

    if (looksLikePath) {
      const target = join(root, raw);

      if (!existsSync(target) && existsSync(dirname(target)) && !perCheckoutInMain(raw)) {
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

// A project file the 2.x `setup` blueprints generated for a skill 3.0 retired.
// It opens with "rules for `/myspec:code-review`", and the 3.0.0-code-review
// migration leaves it in place: it holds prose the project wrote, and no
// manifest entry ever tracked it. The retired name there is the file's own
// provenance, not a route the project can correct, so it is not reported;
// the same name anywhere else still is.
const RETIRED_SKILL_FILES = new Map([['code-review', '.claude/rules/code-review.md']]);

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
    .filter((name) => !skillNames.has(name) && RETIRED_SKILL_FILES.get(name) !== rel(path))
    .forEach((name) => {
      warn('dead-skill-ref', 'refs', rel(path), `${rel(path)}: routes to /myspec:${name}, which the installed plugin does not ship`, {
        text: 'correct the skill name, or update the plugin',
      });
    });
});

// A topologyFile the project names but does not have is the same class of defect
// as a dead path reference, and lands in the same non-blocking group: bootstrap
// reads this file at session start and feature-tech-spec enumerates `packages:`
// from it, so both quietly fall back to guessing. Not `schema`, which the stop
// hook blocks on — a missing topology file should not hold up a commit.
if (typeof settings.topologyFile === 'string' && settings.topologyFile !== '') {
  if (!existsSync(join(root, settings.topologyFile))) {
    warn('topology-missing', 'refs', '.myspec.json', `.myspec.json names topologyFile ${JSON.stringify(settings.topologyFile)}, which does not exist — bootstrap and the reuse audit fall back to guessing`, {
      text: 'create it with /myspec:setup backbone, or correct the topologyFile key',
    });
  }
}

// --- worktree (#239) ----------------------------------------------------------
//
// worktree-provision.sh records each link it makes in
// .claude/state/provision.json, and the Stop hook compares only that record
// (docs/stop-gate.md R8). Run in a linked worktree, two things it cannot see
// are reported here:
//   link-unrecorded  a directory symlink at the top level, or inside a
//                    tracked directory one or two levels down
//                    (apps/web/node_modules, the workspace case), whose
//                    physical target is outside the worktree and which the
//                    record does not list. Checks through it may describe
//                    the main checkout. A link git tracks is the project's
//                    own content and is left alone.
//   provision-link-dangling / provision-link-moved  a recorded link whose
//                    target is gone, or that resolves somewhere other than
//                    its recorded target.
//   provision-record-unreadable  a record that is not JSON or has no source.
//   provision-stale  a recorded lockfile whose hash no longer matches, or a
//                    lockfile pattern recorded absent (null hash) that now
//                    matches a file the record does not hash, in the
//                    recorded source or in the worktree: the Stop hook blocks
//                    on it, and this says so before a stop does.
// The main checkout is never checked: a link there is the project's choice.
function linkedWorktree() {
  const dirs = gitDirs();

  return dirs !== null && dirs.gitDir !== dirs.commonDir;
}

function sha256Of(path) {
  try {
    return createHash('sha256').update(readFileSync(path)).digest('hex');
  } catch {
    return null;
  }
}

// shellSegmentRe(seg) -> a RegExp for one path segment of a shell glob, as
// lock_paths (lib/worktree-provision.sh) and the Stop hook's pattern_matches
// expand it: * and ? stay within the
// segment, [...] is a class ([!...] or [^...] negated, a ] first in it
// literal), an unclosed [ is literal, and everything else is literal.
function shellSegmentRe(seg) {
  const lit = (text) => text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
  let out = '';

  for (let i = 0; i < seg.length; i += 1) {
    const c = seg[i];

    if (c === '*') {
      out += '[^/]*';
    } else if (c === '?') {
      out += '[^/]';
    } else if (c === '[') {
      let j = i + 1;
      const negate = seg[j] === '!' || seg[j] === '^';

      if (negate) {
        j += 1;
      }

      const end = seg.indexOf(']', seg[j] === ']' ? j + 1 : j);

      if (end === -1) {
        out += lit(c);
      } else {
        out += `[${negate ? '^' : ''}${seg.slice(j, end).replace(/[\\\]^]/g, '\\$&')}]`;
        i = end;
      }
    } else {
      out += lit(c);
    }
  }

  return new RegExp(`^${out}$`);
}

// lockPatternMatches(dir, pattern) -> the dir-relative regular files a
// recorded lockfile pattern matches, read as provision's own shell glob
// (shellSegmentRe). A null-hash record entry is such a pattern.
function lockPatternMatches(dir, pattern) {
  let found = [''];

  for (const seg of pattern.split('/').filter((part) => part !== '' && part !== '.')) {
    if (seg === '..') {
      return [];
    }

    found = found.flatMap((rel) => {
      if (!/[*?[]/.test(seg)) {
        return [rel ? `${rel}/${seg}` : seg];
      }

      const re = shellSegmentRe(seg);

      try {
        return readdirSync(join(dir, rel)).filter((name) => re.test(name)).map((name) => (rel ? `${rel}/${name}` : name));
      } catch {
        return [];
      }
    });
  }

  return found.filter((rel) => {
    try {
      return statSync(join(dir, rel)).isFile();
    } catch {
      return false;
    }
  });
}

// treeLoadsCheckout(tree, checkout) -> why the dependency tree at <tree>
// (physical) loads the project's own source from <checkout> (physical), or
// null. A port of tree_loads_checkout in lib/worktree-provision.sh, which
// decides this when it links: Composer's root autoload rules against
// $baseDir, an editable Python install whose direct_url.json points into
// the checkout, and a directory symlink in the tree's top two levels, or in
// a nested link directory's, that resolves out of the tree into the
// checkout (a workspace package, a Composer path repository). A tree whose
// root cannot be listed counts as loading, as there.
const NESTED_LINK_DIRS = ['.pnpm/node_modules'];

function treeLoadsCheckout(tree, checkout) {
  const list = (dir) => {
    try {
      return readdirSync(dir, { withFileTypes: true });
    } catch {
      return null;
    }
  };
  const under = (path, dir) => path === dir || path.startsWith(`${dir}/`);

  for (const entry of list(join(tree, 'composer')) || []) {
    if (/^autoload_.*\.php$/.test(entry.name) && (read(join(tree, 'composer', entry.name)) || '').includes('$baseDir . ')) {
      return `composer/${entry.name} loads the root package from $baseDir`;
    }
  }

  for (const python of (list(join(tree, 'lib')) || []).filter((entry) => entry.name.startsWith('python'))) {
    const sitePackages = join(tree, 'lib', python.name, 'site-packages');

    for (const info of (list(sitePackages) || []).filter((entry) => entry.name.endsWith('.dist-info'))) {
      const direct = readJson(join(sitePackages, info.name, 'direct_url.json')).value;
      const url = isPlainObject(direct) && isPlainObject(direct.dir_info) && direct.dir_info.editable === true ? direct.url : null;

      if (typeof url === 'string' && url.startsWith('file://')) {
        let dir = null;

        try {
          dir = realpathSync(decodeURIComponent(url.slice('file://'.length)));
        } catch {
          // gone: loads nothing
        }

        if (dir && under(dir, checkout)) {
          return `${info.name} is an editable install of ${dir}`;
        }
      }
    }
  }

  if (list(tree) === null) {
    return 'its root cannot be listed, so it cannot be scanned for links into the checkout';
  }

  // The symlinks in <dir>'s top two levels, as find -maxdepth 2 -type l
  // lists them: a linked directory is not descended into.
  const linksIn = (dir) => (list(dir) || []).flatMap((entry) => {
    if (entry.isSymbolicLink()) {
      return [join(dir, entry.name)];
    }

    return entry.isDirectory()
      ? (list(join(dir, entry.name)) || []).filter((inner) => inner.isSymbolicLink()).map((inner) => join(dir, entry.name, inner.name))
      : [];
  });
  const links = [tree, ...NESTED_LINK_DIRS.map((nested) => join(tree, nested))].flatMap(linksIn);

  for (const link of links) {
    let target;

    try {
      target = realpathSync(link);

      if (!statSync(target).isDirectory()) {
        continue;
      }
    } catch {
      continue;
    }

    if (!under(target, tree) && under(target, checkout)) {
      return `${link.slice(tree.length + 1)} links to ${target}`;
    }
  }

  return null;
}

function checkWorktreeLinks() {
  if (!wants('worktree') || !linkedWorktree()) {
    return;
  }

  let realRoot;

  try {
    realRoot = realpathSync(root);
  } catch {
    return;
  }

  const recordPath = join(root, '.claude', 'state', 'provision.json');
  const record = readJson(recordPath);
  // The Stop hook blocks on a record it cannot read (no JSON, or no source),
  // so that is the finding, not one link-unrecorded line per recorded link.
  const unreadable = record.present
    && (record.error !== null || !isPlainObject(record.value) || typeof record.value.source !== 'string');

  if (unreadable) {
    warn('provision-record-unreadable', 'worktree', '.claude/state/provision.json', `.claude/state/provision.json cannot be read (${record.error || 'it has no source'}); the Stop hook blocks until provision runs again`, {
      text: `run "${PROVISION}" on this worktree: it rewrites the record`,
    });

    return;
  }

  const links = record.value && Array.isArray(record.value.links)
    ? record.value.links.filter((link) => link && typeof link.path === 'string')
    : [];
  const recorded = new Set(links.map((link) => link.path));
  const entries = (dir) => {
    try {
      return readdirSync(join(root, dir), { withFileTypes: true });
    } catch {
      return [];
    }
  };
  const candidates = [];
  const consider = (relPath) => {
    let target;

    try {
      if (!lstatSync(join(root, relPath)).isSymbolicLink() || !statSync(join(root, relPath)).isDirectory()) {
        return;
      }

      target = realpathSync(join(root, relPath));
    } catch {
      return;
    }

    if (target !== realRoot && !target.startsWith(`${realRoot}/`) && !recorded.has(relPath)) {
      candidates.push({ relPath, target });
    }
  };

  // Directories to look in: the root, and the directories one and two levels
  // down that hold tracked files (apps/web, packages/ui). An installed tree
  // holds no tracked files, so its contents are never walked.
  let trackedFiles = [];

  try {
    trackedFiles = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 256 * 1024 * 1024 })
      .split('\0').filter(Boolean);
  } catch {
    // nothing listed: the root alone is looked in
  }

  const dirs = new Set(['.']);

  trackedFiles.forEach((file) => {
    const parts = file.split('/');

    if (parts.length > 1) {
      dirs.add(parts[0]);
    }

    if (parts.length > 2) {
      dirs.add(`${parts[0]}/${parts[1]}`);
    }
  });

  dirs.forEach((dir) => {
    entries(dir).filter((entry) => entry.isSymbolicLink() && entry.name !== '.git')
      .forEach((entry) => consider(dir === '.' ? entry.name : `${dir}/${entry.name}`));
  });

  // The listing above holds tracked symlinks too; when it failed, every
  // candidate is reported.
  const tracked = new Set(trackedFiles);

  candidates.filter(({ relPath }) => !tracked.has(relPath)).forEach(({ relPath, target }) => {
    warn('link-unrecorded', 'worktree', relPath, `${relPath} links out of this worktree (to ${target}) and was not recorded by provision; checks here may describe the main checkout`, {
      text: `replace the link with a real install in this worktree, or remove it and run "${PROVISION}" on this worktree so the Stop hook can compare it`,
    });
  });

  const source = record.value && typeof record.value.source === 'string' ? record.value.source : null;

  if (!source) {
    return;
  }

  links.forEach((link) => {
    try {
      if (!lstatSync(join(root, link.path)).isSymbolicLink()) {
        return;
      }
    } catch {
      return;
    }

    // A recorded link that no longer resolves to its recorded target: the
    // Stop hook compares the physical target and blocks on either case.
    let resolved = null;

    try {
      resolved = realpathSync(join(root, link.path));
    } catch {
      // dangling
    }

    if (resolved === null) {
      warn('provision-link-dangling', 'worktree', link.path, `${link.path} was linked by provision but its target no longer exists; the Stop hook blocks until provision runs again`, {
        text: `run "${PROVISION}" on this worktree: it links again where the lockfiles match and says what to install where they do not`,
      });

      return;
    }

    if (typeof link.target === 'string' && resolved !== link.target) {
      warn('provision-link-moved', 'worktree', link.path, `${link.path} was linked by provision to ${link.target} and now resolves to ${resolved}; the Stop hook blocks until provision runs again`, {
        text: `run "${PROVISION}" on this worktree: it links again where the lockfiles match and says what to install where they do not`,
      });

      return;
    }

    // Provision refuses to link a tree that loads the source checkout's own
    // code; one that starts to after linking (a composer dump-autoload, an
    // editable install, a new workspace package in the source checkout) is
    // caught by nothing else until provision runs again.
    let sourceReal = source;

    try {
      sourceReal = realpathSync(source);
    } catch {
      // compared as recorded
    }

    const loads = statSync(resolved).isDirectory() ? treeLoadsCheckout(resolved, sourceReal) : null;

    if (loads) {
      warn('provision-link-loads-main', 'worktree', link.path, `${link.path} links to ${resolved}, which now loads the source checkout's own code (${loads}): checks here run ${sourceReal}'s source, not this worktree's, and the Stop hook does not compare this`, {
        text: `re-run "${PROVISION}" on this worktree, which replaces the link with the advice to install, or move ${link.path} to isolation.provision.copy (mode clone) so the worktree has its own tree`,
      });
    }

    const lockfiles = link.lockfiles && typeof link.lockfiles === 'object' ? link.lockfiles : {};

    const hashed = new Set(Object.keys(lockfiles).filter((lock) => lockfiles[lock] !== null));

    Object.entries(lockfiles).forEach(([lock, hash]) => {
      if (hash === null) {
        const sides = [[source, `in ${source}`], [root, 'in this worktree']];
        const seen = sides.map(([dir, where]) => [lockPatternMatches(dir, lock).find((rel) => !hashed.has(rel)), where])
          .find(([rel]) => rel);

        if (seen) {
          warn('provision-stale', 'worktree', link.path, `${link.path} was provisioned while ${seen[0]} did not exist, and it has appeared since (${seen[1]}); the Stop hook blocks until provision runs again`, {
            text: `run "${PROVISION}" on this worktree: it links again where the lockfiles match and says what to install where they do not`,
          });
        }

        return;
      }

      const changed = [join(source, lock), join(root, lock)].find((path) => sha256Of(path) !== hash);

      if (changed) {
        warn('provision-stale', 'worktree', link.path, `${link.path} was provisioned from ${lock}, which has changed since (${changed === join(root, lock) ? 'in this worktree' : `in ${source}`}); the Stop hook blocks until provision runs again`, {
          text: `run "${PROVISION}" on this worktree: it links again where the lockfiles match and says what to install where they do not`,
        });
      }
    });
  });
}

checkWorktreeLinks();

// --- settings (#233) -----------------------------------------------------------
//
// The effective policy: every setting whose value, after the reader merges its
// layers, differs from the schema default, with the layer that set it. A
// setting the schema marks `loosens` weakens a gate, and is marked here so it
// cannot become invisible policy (docs/project-settings-design.md, principle
// 5). Values come from lib/myspec-config.mjs, the reader the lib scripts use
// and lib/myspec-config.sh mirrors, so this listing and the hooks agree.
// Bookkeeping keys are left out. A list whose items the schema describes
// (`name[]`) is listed item by item.

const settingsInForce = [];
let settingsListed = false;

function listSettings(schema) {
  const keys = schema.keys;
  const layers = configLib.LAYERS;
  const sessionEnv = process.env;
  const effective = (key, n) => configLib.getSetting(key, { root, schema, env: sessionEnv, layers: layers.slice(0, n) }).value;
  const defaultOf = (entry) => (entry && Object.hasOwn(entry, 'default') ? entry.default : null);
  // An empty string where the schema has no default is the template's blank,
  // which every reader treats as unset.
  const differs = (value, entry) => value !== null
    && !(value === '' && defaultOf(entry) === null)
    && stableJson(value) !== stableJson(defaultOf(entry));

  // The layer that last changed the value, named for the reader of the
  // report: the project file, or the session variables that set it.
  function sourceOf(key, entry) {
    let previous = stableJson(effective(key, 1));
    let name = 'default';

    for (let n = 2; n <= layers.length; n += 1) {
      const now = stableJson(effective(key, n));

      if (now !== previous) {
        name = layers[n - 1]({ schema, root, env: sessionEnv, req: key }).name;
      }

      previous = now;
    }

    if (name === 'project') {
      return schema.files[entry.file];
    }

    if (name === 'session') {
      const vars = Object.entries(schema.env)
        .filter(([variable, env]) => env.kind === 'override' && env.key === key
          && new RegExp(env.match).test(sessionEnv[variable] ?? ''))
        .map(([variable]) => `${variable}=${sessionEnv[variable]}`);

      return vars.length > 0 ? `session: ${vars.join(', ')}` : 'session';
    }

    return name;
  }

  Object.entries(keys)
    .filter(([key, entry]) => !key.includes('[]') && !key.includes('.*') && !entry.bookkeeping)
    .forEach(([key, entry]) => {
      const value = effective(key, layers.length);

      if (!differs(value, entry)) {
        return;
      }

      const source = sourceOf(key, entry);
      const label = fileLabel(entry.file, key);
      const base = defaultOf(entry);

      // An extend list over a non-empty default (isolation.blockInMain) is
      // shown as the default plus what the layers added, so the project's
      // entries are not cut off behind the default's.
      if (entry.merge === 'extend' && Array.isArray(base) && base.length > 0 && Array.isArray(value)
          && base.every((item, i) => stableJson(item) === stableJson(value[i]))) {
        settingsInForce.push({ key: label, value, added: value.slice(base.length), source, loosens: entry.loosens === true });

        return;
      }
      const fields = Object.entries(keys).filter(([other]) => other.startsWith(`${key}[].`));

      // An emptied list has no items to list, so it is listed whole.
      if (!Array.isArray(value) || value.length === 0 || !Object.hasOwn(keys, `${key}[]`)) {
        settingsInForce.push({ key: label, value, source, loosens: entry.loosens === true });

        return;
      }

      value.forEach((item, i) => {
        if (!isPlainObject(item)) {
          settingsInForce.push({ key: `${label}[${i}]`, value: item, source, loosens: entry.loosens === true });

          return;
        }

        fields
          .filter(([, field]) => !field.bookkeeping)
          .forEach(([other, field]) => {
            const name = other.slice(key.length + 3);

            if (Object.hasOwn(item, name) && differs(item[name], field)) {
              settingsInForce.push({ key: `${label}[${i}].${name}`, value: item[name], source, loosens: entry.loosens === true || field.loosens === true });
            }
          });
      });
    });

  // Session variables that set no key but change a hook's behaviour.
  Object.entries(schema.env)
    .filter(([variable, env]) => env.kind === 'standalone' && (sessionEnv[variable] ?? '') !== '')
    .forEach(([variable, env]) => {
      settingsInForce.push({ key: variable, value: sessionEnv[variable], source: 'session', loosens: env.loosens === true });
    });
}

if (configSchema && wants('settings') && (selectedIds.size === 0 || selectedIds.has('setting-in-force'))) {
  listSettings(configSchema);
  settingsListed = true;
}

// --- report -------------------------------------------------------------------

const fixable = [...errors, ...warnings].filter((finding) => finding.remediation.commands.length > 0).length;
const summary = errors.length === 0 && warnings.length === 0
  ? 'setup doctor: clean'
  : `setup doctor: ${errors.length} error(s), ${warnings.length} warning(s)${fixable > 0 ? `, ${fixable} with a fix command` : ''}`;

if (json) {
  process.stdout.write(`${JSON.stringify({ errors, warnings, notes, settings: settingsInForce }, null, 2)}\n`);
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

    if (settingsListed && settingsInForce.length === 0) {
      lines.push('SET   every setting is at its default');
    }

    settingsInForce.forEach(({ key, value, added, source, loosens }) => {
      const shown = added ? `default + ${JSON.stringify(added)}` : JSON.stringify(value);

      lines.push(`SET   ${key} = ${shown.length > 160 ? `${shown.slice(0, 157)}...` : shown} (${source})${loosens ? ' — loosens a gate' : ''}`);
    });
  }

  lines.push(summary);
  process.stdout.write(`${lines.join('\n')}\n`);
}

process.exit(errors.length > 0 ? 1 : 0);
