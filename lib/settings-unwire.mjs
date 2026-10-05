#!/usr/bin/env node
// settings-unwire.mjs
// Removes the framework's hook entries from a project's .claude/settings.json.
//
// WHY: since 3.0 the plugin's hooks.json runs the framework hooks, and Claude
// Code keeps a plugin's handler separate from a settings copy of the same
// command, so an entry a 2.x init or update wrote runs the retired copy a
// second time. The `3.0.0-plugin-hooks` migration in `update` calls this
// instead of describing the rewrite in prose: the entries are matched by the
// script's name whatever precedes it ("$CLAUDE_PROJECT_DIR"/.claude/hooks/x.sh,
// bare, ./, `bash "…/x.sh"`, "${CLAUDE_PLUGIN_ROOT}"/hooks/x.sh), every other
// entry stays where it is, a matcher group goes only when its hooks array
// empties, an event array only when it empties, the `hooks` key only when
// every event is gone, and nothing else in the file changes.
//
// The framework's script names come from the plugin's own hooks.json (one
// source, the manifest `removed` block as the fallback), and setup-doctor.mjs
// imports the same functions for its hook-wired-locally check.
//
// Usage:
//   settings-unwire.mjs [--root <checkout>] [--plugin-root <dir>] [--dry-run] [--json]
//
//   --root         the checkout whose .claude/settings.json is rewritten;
//                  defaults to this git checkout
//   --plugin-root  the myspec plugin; defaults to $CLAUDE_PLUGIN_ROOT, else the
//                  directory above this file
//   --dry-run      print what would be removed and write nothing
//   --json         print the result as { removed: [...], kept: [...], written }
//
// Prints one line per removed entry (`removed: <event> [<matcher>] <command>`)
// and a summary. Exit 0 when the file was rewritten or had nothing to remove,
// 2 on a usage error, an unreadable file or a plugin root with no hooks.json.

import {
  existsSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import {
  basename,
  dirname,
  join,
  resolve,
} from 'node:path';
import {
  execFileSync,
} from 'node:child_process';
import {
  fileURLToPath,
  pathToFileURL,
} from 'node:url';

// A command led by one of these runs its script as an argument instead of
// exec'ing it; the script is then token 1.
export const HOOK_INTERPRETERS = new Set(['bash', 'sh', 'zsh', 'dash', 'node']);

// Every `command` string under a settings value, in document order.
export function hookCommands(value) {
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

// The framework hooks by script name: the basename of every command the
// plugin's hooks.json runs. Falls back to the manifest `removed` keys retired
// since 3.0 (`hooks/<name>`) when hooks.json cannot be read, and to an empty
// set when neither can.
export function frameworkHookNames(pluginRoot) {
  const names = new Set();

  if (!pluginRoot) {
    return names;
  }

  try {
    const hooks = JSON.parse(readFileSync(join(pluginRoot, 'hooks.json'), 'utf8'));

    hookCommands(hooks).forEach((command) => {
      const script = scriptOf(command);

      if (script) {
        names.add(basename(script));
      }
    });
  } catch {
    try {
      const manifest = JSON.parse(readFileSync(join(pluginRoot, 'framework-files', 'manifest.json'), 'utf8'));

      Object.entries(manifest.removed || {}).forEach(([key, entry]) => {
        if (key.startsWith('hooks/') && entry && /^(?:[3-9]|\d{2,})\./.test(String(entry.since || ''))) {
          names.add(basename(key));
        }
      });
    } catch {
      // No plugin at that root: nothing is a framework hook.
    }
  }

  return names;
}

// The script token a command runs, quotes stripped, or null: token 0 when it
// ends in .sh, token 1 behind an interpreter. A `.sh` any later is an argument
// to some other program, and a mention inside a string is not a run.
function scriptOf(command) {
  const tokens = command.trim().split(/\s+/).map((token) => token.replace(/["']/g, ''));
  const lead = tokens[0] ?? '';

  if (lead.endsWith('.sh')) {
    return lead;
  }

  if (HOOK_INTERPRETERS.has(basename(lead)) && (tokens[1] ?? '').endsWith('.sh')) {
    return tokens[1];
  }

  return null;
}

// The framework hook a command runs, by script name, whatever the path in
// front of it; null for a command that runs none or runs a project's own.
export function frameworkHookOf(command, names) {
  const script = scriptOf(command);

  return script && names.has(basename(script)) ? basename(script) : null;
}

// unwire(settings, names) -> { settings, removed, kept }: a copy of the
// settings object with the framework entries removed and the empty containers
// they leave behind dropped. `removed` and `kept` list { event, matcher, command }.
export function unwire(settings, names) {
  const removed = [];
  const kept = [];
  const out = { ...settings };
  const hooks = settings && settings.hooks && typeof settings.hooks === 'object' && !Array.isArray(settings.hooks)
    ? settings.hooks
    : null;

  if (!hooks) {
    return { settings: out, removed, kept };
  }

  const events = {};

  Object.entries(hooks).forEach(([event, groups]) => {
    if (!Array.isArray(groups)) {
      events[event] = groups;

      return;
    }

    const keptGroups = [];

    groups.forEach((group) => {
      if (!group || typeof group !== 'object' || !Array.isArray(group.hooks)) {
        keptGroups.push(group);

        return;
      }

      const matcher = typeof group.matcher === 'string' ? group.matcher : null;
      const keptHooks = group.hooks.filter((hook) => {
        const command = hook && typeof hook === 'object' && typeof hook.command === 'string' ? hook.command : null;
        const name = command === null ? null : frameworkHookOf(command, names);

        (name ? removed : kept).push({ event, matcher, command });

        return !name;
      });

      if (keptHooks.length > 0) {
        keptGroups.push({ ...group, hooks: keptHooks });
      }
    });

    if (keptGroups.length > 0) {
      events[event] = keptGroups;
    }
  });

  if (Object.keys(events).length > 0) {
    out.hooks = events;
  } else {
    delete out.hooks;
  }

  return { settings: out, removed, kept };
}

function label({ event, matcher, command }) {
  return `${event}${matcher === null ? '' : ` [${matcher}]`} ${command}`;
}

function gitRoot(cwd) {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch {
    return null;
  }
}

function main(argv) {
  let rootArg = null;
  let pluginArg = null;
  let dryRun = false;
  let json = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === '--root' && argv[i + 1]) {
      rootArg = argv[i + 1];
      i += 1;
    } else if (arg.startsWith('--root=')) {
      rootArg = arg.slice('--root='.length);
    } else if (arg === '--plugin-root' && argv[i + 1]) {
      pluginArg = argv[i + 1];
      i += 1;
    } else if (arg.startsWith('--plugin-root=')) {
      pluginArg = arg.slice('--plugin-root='.length);
    } else if (arg === '--dry-run') {
      dryRun = true;
    } else if (arg === '--json') {
      json = true;
    } else {
      process.stderr.write(`settings-unwire: unknown argument ${arg}\n`);

      return 2;
    }
  }

  const root = resolve(rootArg || gitRoot(process.cwd()) || process.cwd());
  const pluginRoot = resolve(pluginArg || process.env.CLAUDE_PLUGIN_ROOT || dirname(dirname(fileURLToPath(import.meta.url))));
  const names = frameworkHookNames(pluginRoot);

  if (names.size === 0) {
    process.stderr.write(`settings-unwire: no hooks.json under ${pluginRoot} — pass --plugin-root\n`);

    return 2;
  }

  const path = join(root, '.claude', 'settings.json');

  if (!existsSync(path)) {
    const text = 'settings-unwire: no .claude/settings.json — nothing to unwire';

    process.stdout.write(json ? `${JSON.stringify({ removed: [], kept: [], written: false, note: text })}\n` : `${text}\n`);

    return 0;
  }

  let settings;

  try {
    settings = JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    process.stderr.write(`settings-unwire: .claude/settings.json is not valid JSON: ${err.message}\n`);

    return 2;
  }

  const result = unwire(settings, names);
  const written = result.removed.length > 0 && !dryRun;

  if (written) {
    writeFileSync(path, `${JSON.stringify(result.settings, null, 2)}\n`);
  }

  if (json) {
    process.stdout.write(`${JSON.stringify({ removed: result.removed, kept: result.kept, written }, null, 2)}\n`);

    return 0;
  }

  const lines = result.removed.map((entry) => `removed: ${label(entry)}`);

  lines.push(`settings-unwire: ${result.removed.length} framework entr${result.removed.length === 1 ? 'y' : 'ies'} ${dryRun ? 'would be ' : ''}removed, ${result.kept.length} project entr${result.kept.length === 1 ? 'y' : 'ies'} kept${dryRun ? ' (dry run, nothing written)' : written ? '' : ' (nothing to write)'}`);
  process.stdout.write(`${lines.join('\n')}\n`);

  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)));
}
