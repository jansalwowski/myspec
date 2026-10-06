#!/usr/bin/env node
// upgrade-route.mjs
// Decides whether `update` may upgrade a project from its recorded
// frameworkVersion, and when it may not, prints the whole route to this one.
//
// WHY: a major upgrades only from the last minor of the previous major
// (RELEASING.md, "Upgrade base"), and each major's `update` knew only its own
// floor. A project on 1.17.0 was told by 3.0 to run v2.12.0's update, which
// then told it to run v1.28.0's: the route came one hop at a time (3.0
// dogfood). The route is data in framework-files/manifest.json: `upgradeFrom`
// is this release's floor and `upgradeChain` lists the floors of the earlier
// majors, oldest first. The route from a version is every floor above it, in
// order, then this release.
//
// Usage:
//   upgrade-route.mjs [--version <X.Y.Z>] [--plugin-root <dir>]
//
//   --version      the project's `.myspec.json` frameworkVersion; omitted or
//                  empty means none was recorded (the whole route applies)
//   --plugin-root  the myspec plugin; defaults to $CLAUDE_PLUGIN_ROOT, else the
//                  directory above this file
//
// Exit codes (the update skill branches on them):
//   0  at or above `upgradeFrom`; no output
//   3  below it; the refusal on stdout. Not 1: Node exits 1 on an uncaught
//      error or a missing script, and that stack trace must never be read as
//      the route.
//   2  usage error, unusable manifest, or a frameworkVersion that is not a
//      version; the reason on stderr
// Any other status means the check did not run.

import { readFileSync, realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SEMVER = /^\d+\.\d+\.\d+$/;
export const EXIT_REFUSED = 3;
export const EXIT_UNUSABLE = 2;
const REPO = 'https://github.com/jansalwowski/myspec';

export function compareVersions(a, b) {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0);
  }
  return 0;
}

// A recorded frameworkVersion as X.Y.Z, '' when none is recorded, or null when
// it is not a version. `.myspec.json` is hand-editable (PR #281 review), so:
// surrounding whitespace is trimmed, a leading `v` is dropped, X.Y reads as
// X.Y.0, and a pre-release or build suffix (`3.0.0-rc.1`, `2.12.0+x`) is
// compared by its X.Y.Z core: no myspec tag carries one, and a pre-release
// of a floor holds that floor's migrations.
const LOOSE = /^v?(\d+)\.(\d+)(?:\.(\d+))?(?:[-+][0-9A-Za-z.+-]*)?$/i;
export function normalizeVersion(raw) {
  const value = String(raw ?? '').trim();
  if (value === '') return '';
  const m = LOOSE.exec(value);
  if (!m) return null;
  return `${Number(m[1])}.${Number(m[2])}.${Number(m[3] ?? 0)}`;
}

// The floors a project at `version` (X.Y.Z, or '' for none recorded) must
// update through, oldest first; empty when it is at or above `upgradeFrom`.
// No recorded version gets every floor.
export function upgradeRoute(manifest, version) {
  const floors = [...(manifest.upgradeChain || []), manifest.upgradeFrom];
  if (!SEMVER.test(version || '')) return floors;
  return floors.filter((floor) => compareVersions(version, floor) < 0);
}

export function refusal(manifest, version) {
  const route = upgradeRoute(manifest, version);
  if (route.length === 0) return '';
  const floor = manifest.upgradeFrom;
  const guide = `docs/upgrading-to-${Number(floor.split('.')[0]) + 1}.0.md`;
  const recorded = SEMVER.test(version || '')
    ? `This project is on v${version}`
    : 'This project records no frameworkVersion';
  const steps = route.map((v) => `v${v}`).join(', then ');
  return [
    `${recorded}; myspec v${manifest.frameworkVersion} upgrades from ${floor} or later.`,
    `Update through ${steps}, then this version.`,
    `For each release in turn: check out the plugin at its tag (\`git clone --branch v<release> ${REPO}\`), start Claude with \`--plugin-dir <that checkout>\`, run \`/myspec:update\`, then move to the next.`,
    `${guide} in the plugin has the full route.`,
  ].join(' ');
}

function main(argv) {
  let version = '';
  let pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
    || join(dirname(fileURLToPath(import.meta.url)), '..');
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--version') version = argv[++i] ?? '';
    else if (arg === '--plugin-root') pluginRoot = argv[++i];
    else if (arg === '--help' || arg === '-h') {
      process.stdout.write('usage: upgrade-route.mjs [--version <X.Y.Z>] [--plugin-root <dir>]\n');
      return 0;
    } else {
      process.stderr.write(`upgrade-route: unknown argument ${arg}\n`);
      return EXIT_UNUSABLE;
    }
  }
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(join(pluginRoot, 'framework-files', 'manifest.json'), 'utf8'));
  } catch (err) {
    process.stderr.write(`upgrade-route: cannot read the plugin manifest: ${err.message}\n`);
    return EXIT_UNUSABLE;
  }
  if (!SEMVER.test(manifest.upgradeFrom || '')) {
    process.stderr.write('upgrade-route: the manifest has no upgradeFrom X.Y.Z\n');
    return EXIT_UNUSABLE;
  }
  const parsed = normalizeVersion(version);
  if (parsed === null) {
    process.stderr.write(`upgrade-route: .myspec.json frameworkVersion '${version}' is not a version; set it to the X.Y.Z this project was last updated with\n`);
    return EXIT_UNUSABLE;
  }
  const message = refusal(manifest, parsed);
  if (!message) return 0;
  process.stdout.write(`${message}\n`);
  return EXIT_REFUSED;
}

// import.meta.url is the realpath; argv[1] keeps any symlink on the way.
function isMain() {
  try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; }
}

if (isMain()) process.exit(main(process.argv.slice(2)));
