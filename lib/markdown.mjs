// markdown.mjs
// Shared readers for the two markdown shapes several lib scripts parse:
// table rows and a leading YAML frontmatter block (#429). Before this module
// each script had its own copy, and the copies disagreed: one closed a block
// on any `\n---` prefix (so `----` ended it) and rejected a CRLF or BOM
// opening line, another unescaped `\|` and the others did not.
//
// Readers that keep their own frontmatter scan on purpose, because moving
// them would change what they return: doc-status-normalize.mjs findStatus,
// delivery-metrics frontmatterField and verdictHistory, and
// feature-status-audit frontmatterField all read a block that never closes,
// for which this module reports no block. New code uses frontmatterBlock.

const BOM = '﻿';
// A frontmatter fence: `---` in column 0, trailing spaces and a CR allowed,
// so an indented `---` inside a block scalar does not close the block.
const FENCE_LINE = /^---[ \t]*\r?$/;

// The cells of one markdown table row. A leading and a trailing pipe are
// optional; `\|` is a literal pipe, kept as `\|` unless `unescape` is set. A
// pipe after an even run of backslashes (`\\|`) is a delimiter.
export function tableCells(line, { unescape = false } = {}) {
  const cells = [];
  let cell = '';
  let slashes = 0;

  for (const ch of line.trim()) {
    if (ch === '|' && slashes % 2 === 0) {
      cells.push(cell);
      cell = '';
    } else {
      cell += ch;
    }

    slashes = ch === '\\' ? slashes + 1 : 0;
  }

  cells.push(cell);

  if (cells.length > 1 && cells[0].trim() === '') {
    cells.shift();
  }

  if (cells.length > 1 && cells.at(-1).trim() === '') {
    cells.pop();
  }

  return cells.map((c) => (unescape ? c.trim().replace(/\\\|/g, '|') : c.trim()));
}

// A line a YAML frontmatter block can hold. With `yamlOnly`, a block holding
// any other line is a pair of horizontal rules, not frontmatter.
const YAML_LINE = /^(?:\s*$|\s*#|[A-Za-z_][\w-]*\s*:|\s+\S|- )/;

// The leading frontmatter block of a document: line 1 (after an optional BOM)
// is a fence line and the block closes at the next one (FENCE_LINE).
// Returns { bom, lines, close }: `lines` is the text after the BOM split on
// `\n` (line endings kept), `close` the index of the closing
// line, or -1 when there is no closed block.
export function frontmatterBlock(text, { yamlOnly = false } = {}) {
  const bom = text.startsWith(BOM) ? BOM : '';
  const lines = text.slice(bom.length).split('\n');
  let close = FENCE_LINE.test(lines[0]) ? lines.findIndex((l, i) => i > 0 && FENCE_LINE.test(l)) : -1;

  if (yamlOnly && close > 0 && !lines.slice(1, close).every((l) => YAML_LINE.test(l.replace(/\r$/, '')))) {
    close = -1;
  }

  return { bom, lines, close };
}

// The frontmatter's text between its fences, without CRs; '' when the
// document has no closed block.
export function frontmatterText(text, opts) {
  const { lines, close } = frontmatterBlock(text, opts);

  return close < 0 ? '' : lines.slice(1, close).map((l) => l.replace(/\r$/, '')).join('\n');
}
