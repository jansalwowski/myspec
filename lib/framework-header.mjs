// framework-header.mjs
// The one rule for the `updated:` date in a marker-merge file's framework-owned
// header (#545). That header (line 1 through the end marker, frontmatter
// included) belongs to the framework, but its one `updated:` date also
// describes the project section below the end marker. So the date holds the
// later of the framework's date and the project's last edit: an installed
// header whose `updated:` is the same as or later than the shipped one is not
// drift, and an earlier one is.
//
// Read side: setup-doctor (the header comparison) and pin-reconcile (drop)
// compare through withShippedDate. Write side: update's marker-merge step
// renders the source through the CLI below, which applies withProjectDate.
//
//   import { withShippedDate, withProjectDate } from './framework-header.mjs'
//
// Usage:
//   node "${CLAUDE_PLUGIN_ROOT}/lib/framework-header.mjs" keep-date <dest>
//     reads the rendered source on stdin and prints it with <dest>'s
//     `updated:` line put in when that date is later. A missing <dest> leaves
//     the source as it is. Exit 2 on a usage error.

import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { frontmatterBlock } from './markdown.mjs';

// One frontmatter line, CR stripped: the date, optionally quoted, optionally
// followed by a YAML comment (whitespace then `#`, as lib/memory-files.mjs
// reads one, #393).
const UPDATED = /^updated:[ \t]*(["']?)(\d{4})-(\d{2})-(\d{2})\1(?:[ \t]+#.*)?[ \t]*$/;

// A date that exists on the calendar: 2026-02-30 and 2026-99-99 do not.
function realDate(y, m, d) {
  const t = new Date(Date.UTC(Number(y), Number(m) - 1, Number(d)));
  return t.getUTCFullYear() === Number(y) && t.getUTCMonth() === Number(m) - 1 && t.getUTCDate() === Number(d);
}

// The frontmatter `updated:` line of text (lib/markdown.mjs frontmatterBlock:
// a BOM or CRLF block is read), as {date, start, end, line} offsets into
// text, the line ending excluded; null when there is none or it is not a
// real date.
function updatedLine(text) {
  const { bom, lines, close } = frontmatterBlock(text);
  if (close < 0) { return null; }
  let offset = bom.length;
  for (let i = 0; i < close; i += 1) {
    const raw = lines[i];
    const line = raw.replace(/\r$/, '');
    const m = i > 0 ? UPDATED.exec(line) : null;
    if (m !== null) {
      return realDate(m[2], m[3], m[4]) ? { date: `${m[2]}-${m[3]}-${m[4]}`, start: offset, end: offset + line.length, line } : null;
    }
    offset += raw.length + 1;
  }
  return null;
}

// later(a, b) -> a's updated line when both dates are readable and a's is the
// same as or later than b's, else null.
function laterLine(a, b) {
  const ours = updatedLine(a);
  const theirs = updatedLine(b);
  return ours === null || theirs === null || ours.date < theirs.date ? null : { ours, theirs };
}

// withShippedDate(installed, shipped) -> installed, with its frontmatter
// `updated:` line replaced by shipped's when the installed date is the same
// as or later than the shipped one. Any other case returns installed
// unchanged, so the caller's own comparison still reports it: an earlier
// date, a missing or unparseable one on either side.
export function withShippedDate(installed, shipped) {
  const hit = laterLine(installed, shipped);
  if (hit === null) { return installed; }
  return installed.slice(0, hit.ours.start) + hit.theirs.line + installed.slice(hit.ours.end);
}

// withProjectDate(shipped, installed) -> shipped, with installed's
// `updated:` line put in when the installed date is later: what update
// writes, so the doctor's withShippedDate comparison then finds no drift.
export function withProjectDate(shipped, installed) {
  const hit = laterLine(installed, shipped);
  if (hit === null || hit.ours.date === hit.theirs.date) { return shipped; }
  return shipped.slice(0, hit.theirs.start) + hit.ours.line + shipped.slice(hit.theirs.end);
}

function cli(argv) {
  if (argv.length !== 2 || argv[0] !== 'keep-date') {
    process.stderr.write('usage: framework-header.mjs keep-date <dest>  (rendered source on stdin)\n');
    return 2;
  }
  const source = readFileSync(0, 'utf8');
  const dest = existsSync(argv[1]) ? readFileSync(argv[1], 'utf8') : null;
  process.stdout.write(dest === null ? source : withProjectDate(source, dest));
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
