// aidir-render.mjs
// The one rule for rendering a framework document into a project. `init` and
// `update` copy a document through the CLI below; setup-doctor and
// pin-reconcile import renderAiDir to compare an installed copy with the
// plugin's. Rendering by hand drifts from this rule (issue #464).
//
//   `${aiDir}`   -> the project's aiDir value
//   `$${aiDir}`  -> a literal `${aiDir}`, for a document that has to show the
//                   placeholder itself (rules/paths.md)
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}"/lib/aidir-render.mjs <source> [--root <project>]
//     prints <source> rendered with the project's aiDir (cwd by default)
//   import { renderAiDir } from './aidir-render.mjs'
//
// Exit 2 on a usage error or an unreadable source.

import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const PLACEHOLDER = /\$?\$\{aiDir\}/g;

export function renderAiDir(text, aiDir) {
  return text.replace(PLACEHOLDER, (match) => (match.length === '${aiDir}'.length ? aiDir : '${aiDir}'));
}

// The CLI alone reads settings, so an importer of renderAiDir loads nothing
// else.
async function main(argv) {
  let source = null;
  let root = process.cwd();
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--root' && i + 1 < argv.length) {
      root = argv[i + 1];
      i += 1;
    } else if (source === null && !argv[i].startsWith('--')) {
      source = argv[i];
    } else {
      process.stderr.write(`aidir-render: unexpected argument ${argv[i]}\n`);
      return 2;
    }
  }
  if (source === null) {
    process.stderr.write('usage: aidir-render.mjs <source> [--root <project>]\n');
    return 2;
  }
  let text;
  try { text = readFileSync(source, 'utf8'); } catch (e) { process.stderr.write(`aidir-render: ${e.message}\n`); return 2; }
  const { aiDirFor } = await import('./memory-files.mjs');
  process.stdout.write(renderAiDir(text, aiDirFor(root)));
  return 0;
}

// import.meta.url is the realpath; argv[1] keeps any symlink on the way.
function invokedDirectly() {
  if (!process.argv[1]) { return false; }
  try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; }
}

if (invokedDirectly()) {
  process.exitCode = await main(process.argv.slice(2));
}
