// plugin-root.mjs
// The plugin directory a lib script belongs to (#429): an explicit path when
// the caller has one, else CLAUDE_PLUGIN_ROOT when it names a plugin, else
// the nearest directory at or above the calling script holding
// framework-files/manifest.json. Returns null when none is found.

import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const isPlugin = (dir) => existsSync(join(dir, 'framework-files', 'manifest.json'));

export function pluginRoot(metaUrl, { explicit = null, env = process.env } = {}) {
  if (explicit) {
    return resolve(explicit);
  }

  if (env.CLAUDE_PLUGIN_ROOT && isPlugin(env.CLAUDE_PLUGIN_ROOT)) {
    return resolve(env.CLAUDE_PLUGIN_ROOT);
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

  return null;
}
