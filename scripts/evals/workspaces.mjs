#!/usr/bin/env node
// Hash the workspace each eval case starts from: run the case's
// scaffold_script against <plugin-dir> in an empty directory, as
// `claude plugin eval --scaffold` does, and hash what it leaves behind.
// Maintainer tooling: release-check.sh uses it to tell whether a change under
// evals/_fixtures/ changed what a case actually sees (RELEASING.md).
//
// Usage: node scripts/evals/workspaces.mjs <plugin-dir> --out <file> [--case <glob>]
//
// Writes {"<case>": "<hash>" | "!<why it could not be built>"} for every case
// under <plugin-dir>/evals/. A case without a scaffold_script hashes as
// "none". The hash (sha256, first 16 hex) covers every file outside .git/
// (relative path, executable bit, content; a symlink's target) and, when the
// fixture made a git repository, the current branch, every ref with the tree
// and subject of each commit on it, and `git status`. Commit ids and dates are
// left out, and a file that quotes one of the workspace's own commit ids (a
// fixture that saves `git log` output) has it replaced by <commit>, so
// building the same workspace twice gives the same hash.
//
// Exit status: 0 written (a case that failed to build is recorded with "!"),
// 2 bad arguments or an unreadable evals/ directory.

import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { globToRegExp } from './results.mjs';

// The workspace's commit ids, full length; empty when it has no repository.
function commitIds(dir) {
  if (!fs.existsSync(path.join(dir, '.git'))) return [];
  try {
    return execFileSync('git', ['-C', dir, 'rev-list', '--all'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
      .split('\n').filter(Boolean);
  } catch {
    return [];
  }
}

// Replace every 7-40 hex digit word that starts one of ids with <commit>.
function maskCommits(buf, ids) {
  if (!ids.length) return buf;
  const s = buf.toString('latin1');
  const masked = s.replace(/\b[0-9a-f]{7,40}\b/g, (w) => (ids.some((id) => id.startsWith(w)) ? '<commit>' : w));
  return masked === s ? buf : Buffer.from(masked, 'latin1');
}

function filesHash(h, dir) {
  const ids = commitIds(dir);
  const walk = (d, rel) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (!rel && e.name === '.git') continue;
      const p = path.join(d, e.name);
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isSymbolicLink()) h.update(`L ${r}\0${fs.readlinkSync(p)}\0`);
      else if (e.isDirectory()) {
        h.update(`D ${r}\0`);
        walk(p, r);
      } else if (e.isFile()) {
        const x = fs.statSync(p).mode & 0o111 ? 'x' : '-';
        h.update(`F ${r} ${x}\0`).update(maskCommits(fs.readFileSync(p), ids)).update('\0');
      }
    }
  };
  walk(dir, '');
}

function gitState(h, dir) {
  if (!fs.existsSync(path.join(dir, '.git'))) return;
  const git = (...args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  let head;
  try {
    head = git('symbolic-ref', '-q', 'HEAD').trim();
  } catch {
    head = 'detached';
  }
  h.update(`HEAD ${head}\0`);
  const refs = git('for-each-ref', '--format=%(refname)').split('\n').filter(Boolean).sort();
  for (const ref of refs) h.update(`R ${ref}\0${git('log', '--format=%T %s', ref)}\0`);
  h.update(`S ${git('status', '--porcelain=v1', '--untracked-files=all')}\0`);
}

export function scaffoldScript(caseDir) {
  const yaml = path.join(caseDir, 'case.yaml');
  if (!fs.existsSync(yaml)) return null;
  const m = fs.readFileSync(yaml, 'utf8').match(/^\s*scaffold_script:\s*["']?([^"'\s#]+)/m);
  return m ? m[1] : null;
}

// Build one case's workspace and hash it: "<hash>", "none" or "!<why>".
export function workspaceHash(pluginDir, name) {
  const caseDir = path.join(pluginDir, 'evals', name);
  const script = scaffoldScript(caseDir);
  if (!script) return 'none';
  const ws = fs.mkdtempSync(path.join(os.tmpdir(), 'myspec-ws-'));
  try {
    // An isolated git config, so the maintainer's global settings (signing,
    // hooks, default branch) neither break the build nor change the hash.
    const env = { ...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: os.devNull };
    try {
      execFileSync('bash', [path.join(caseDir, script)], { cwd: ws, env, stdio: ['ignore', 'ignore', 'pipe'], timeout: 120000 });
    } catch (err) {
      const why = String(err.stderr ?? err.message).trim().split('\n').pop() || `exit ${err.status}`;
      return `!${script} failed: ${why.slice(0, 120)}`;
    }
    const h = crypto.createHash('sha256');
    filesHash(h, ws);
    gitState(h, ws);
    return h.digest('hex').slice(0, 16);
  } finally {
    fs.rmSync(ws, { recursive: true, force: true });
  }
}

export function workspaceHashes(pluginDir, glob) {
  const evals = path.join(pluginDir, 'evals');
  const re = glob ? globToRegExp(glob) : null;
  const out = {};
  for (const e of fs.readdirSync(evals, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (!e.isDirectory() || e.name.startsWith('_') || e.name === 'results') continue;
    const d = path.join(evals, e.name);
    if (!fs.existsSync(path.join(d, 'prompt.md')) && !fs.existsSync(path.join(d, 'case.yaml'))) continue;
    if (re && !re.test(e.name)) continue;
    out[e.name] = workspaceHash(pluginDir, e.name);
  }
  return out;
}

function main() {
  const argv = process.argv.slice(2);
  const opt = (n) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : undefined);
  const pluginDir = argv[0];
  const out = opt('--out');
  if (!pluginDir || pluginDir.startsWith('--') || !out) throw new Error('usage: workspaces.mjs <plugin-dir> --out <file> [--case <glob>]');
  const hashes = workspaceHashes(path.resolve(pluginDir), opt('--case'));
  fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(hashes, null, 2) + '\n');
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (err) {
    console.error(`workspaces: ${err.message}`);
    process.exit(2);
  }
}
