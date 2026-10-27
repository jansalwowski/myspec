#!/usr/bin/env node
// Flag details of a reporter's own project in an issue or comment. Runs in
// .github/workflows/issue-triage.yml on every opened or edited issue and every
// new or edited comment, so it stays deterministic and free: no model call.
//
// The repo is public, and most issues are written from a session inside a
// consumer project. Those sessions named private repos and PRs, ticket IDs,
// project codenames and feature names (see AGENTS.md "Issues"). Built-in
// patterns catch the shapes; the denylist catches the names, which no pattern
// can know. The denylist comes from the REDACTION_DENYLIST secret so the names
// are never committed. A denylist or credential hit is reported without the
// matched text, because the workflow posts the findings as a comment.
//
// Usage: node scripts/triage/redaction-check.mjs [--repo owner/name] < text
//   REDACTION_DENYLIST  comma- or newline-separated names, matched
//                       case-insensitively as whole words
// Output: one finding per line, "line <n>: <kind>[: <match>]".
// Exit:   0 clean, 1 findings, 2 usage error.

import fs from 'node:fs';

function usage(msg) {
  process.stderr.write(`redaction-check: ${msg}\nusage: redaction-check.mjs [--repo owner/name] < text\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
let repo = 'jansalwowski/myspec';
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--repo') repo = args[++i] ?? usage('--repo needs a value');
  else usage(`unknown argument: ${args[i]}`);
}

// Prefixes that name a myspec spec ID or a public standard, not a team's tracker.
const TICKET_ALLOW = new Set(['AC', 'CVE', 'FR', 'GHSA', 'ISO', 'NFR', 'PSR', 'REQ', 'RFC', 'SC', 'SHA', 'TC', 'TICKET', 'US', 'UTF']);
// Home directories used as placeholders in examples and hook fixtures.
const HOME_ALLOW = new Set(['alice', 'bob', 'me', 'runner', 'user', 'you']);

const sameRepo = (r) => r.toLowerCase() === repo.toLowerCase();
const PATTERNS = [
  ['repo reference', /\b([A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+)#\d+/g, (m) => !sameRepo(m[1])],
  ['repo reference', /github\.com\/([A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+)\/(?:pull|issues)\/\d+/g, (m) => !sameRepo(m[1])],
  ['ticket ID', /\b([A-Z]{2,10})-\d{1,6}\b/g, (m) => !TICKET_ALLOW.has(m[1])],
  ['session link', /claude\.ai\/code\/session_[A-Za-z0-9]+/g, () => true],
  ['home path', /\/Users\/([A-Za-z0-9._-]+)/g, (m) => !HOME_ALLOW.has(m[1].toLowerCase())],
  ['email', /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, (m) => !/@(users\.)?noreply\.|@example\.(com|org)$|@anthropic\.com$/i.test(m[0])],
  ['credential', /\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})\b/g, () => true],
];

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const denylist = (process.env.REDACTION_DENYLIST ?? '').split(/[,\n]/).map((s) => s.trim()).filter(Boolean);
const deny = denylist.length ? new RegExp(`(?<![A-Za-z0-9_-])(?:${denylist.map(escape).join('|')})(?![A-Za-z0-9_-])`, 'i') : null;

const findings = [];
fs.readFileSync(0, 'utf8').split('\n').forEach((line, i) => {
  for (const [kind, re, keep] of PATTERNS) {
    // A credential is never echoed: the workflow posts findings as a comment.
    for (const m of line.matchAll(re)) if (keep(m)) findings.push(`line ${i + 1}: ${kind}${kind === 'credential' ? '' : `: ${m[0]}`}`);
  }
  if (deny?.test(line)) findings.push(`line ${i + 1}: a name on the maintainer's denylist`);
});
process.stdout.write(findings.map((f) => `${f}\n`).join(''));
process.exit(findings.length ? 1 : 0);
