// framework-header.mjs
// The one rule for the `updated:` date in a marker-merge file's framework-owned
// header (#545). That header (line 1 through the end marker, frontmatter
// included) belongs to the framework, but its one `updated:` date also
// describes the project section below the end marker. So the date holds the
// later of the framework's date and the project's last edit: an installed
// header whose `updated:` is the same as or later than the shipped one is not
// drift, and an earlier one is.
//
// setup-doctor (the header comparison) and pin-reconcile (drop) compare
// through withShippedDate; the update skill's marker-merge step keeps the
// destination's date by the same rule.
//
//   import { withShippedDate } from './framework-header.mjs'

const UPDATED = /^updated:[ \t]*["']?(\d{4}-\d{2}-\d{2})["']?[ \t]*$/m;

// The frontmatter block: from a first line of `---` to the next `---` line.
function frontmatter(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(\r?\n|$)/.exec(text);
  return m === null ? null : { start: m[0].indexOf('\n') + 1, body: m[1] };
}

function updatedLine(text) {
  const fm = frontmatter(text);
  if (fm === null) { return null; }
  const m = UPDATED.exec(fm.body);
  return m === null ? null : { date: m[1], start: fm.start + m.index, end: fm.start + m.index + m[0].length, line: m[0] };
}

// withShippedDate(installed, shipped) -> installed, with its frontmatter
// `updated:` line replaced by shipped's when the installed date is the same
// as or later than the shipped one. Any other case returns installed
// unchanged, so the caller's own comparison still reports it: an earlier
// date, a missing or unparseable one on either side.
export function withShippedDate(installed, shipped) {
  const ours = updatedLine(installed);
  const theirs = updatedLine(shipped);
  if (ours === null || theirs === null || ours.date < theirs.date) { return installed; }
  return installed.slice(0, ours.start) + theirs.line + installed.slice(ours.end);
}
