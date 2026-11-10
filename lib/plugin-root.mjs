// plugin-root.mjs
// The plugin directory a lib script belongs to (#429): an explicit path when
// the caller has one, else the nearest directory at or above the calling
// script holding framework-files/manifest.json, else CLAUDE_PLUGIN_ROOT when
// it names a plugin. The script's own plugin wins over the variable, so a
// script always reads the blueprints and manifest that ship with it, even
// when the variable names another installed copy. Returns null when none is
// found.

import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const isPlugin = (dir) => existsSync(join(dir, 'framework-files', 'manifest.json'));

export function pluginRoot(metaUrl, { explicit = null, env = process.env } = {}) {
  if (explicit) {
    return resolve(explicit);
  }

  let dir = dirname(fileURLToPath(metaUrl));

  for (let i = 0; i < 6; i += 1) {
    if (isPlugin(dir)) {
      return dir;
    }

    const parent = dirname(dir);

    if (parent === dir) {
      break;
    }

    dir = parent;
  }

  return env.CLAUDE_PLUGIN_ROOT && isPlugin(env.CLAUDE_PLUGIN_ROOT) ? resolve(env.CLAUDE_PLUGIN_ROOT) : null;
}
