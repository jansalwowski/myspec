// markdown.mjs
// Shared readers for the two markdown shapes several lib scripts parse:
// table rows and a leading YAML frontmatter block (#429). Before this module
// each script had its own copy, and the copies disagreed: one closed a block
// on any `\n---` prefix (so `----` ended it) and rejected a CRLF or BOM
// opening line, another unescaped `\|` and the others did not.
//
// lib/doc-status-normalize.mjs findStatus keeps its own scan on purpose: the
// 3.1.0-doc-status migration reads a status line in a block that never
// closes, and changing that would change which docs it rewrites.

const BOM = '﻿';

// The cells of one markdown table row. A leading and a trailing pipe are
// optional; `\|` is a literal pipe, kept as `\|` unless `unescape` is set.
export function tableCells(line, { unescape = false } = {}) {
  let body = line.trim();

  if (body.startsWith('|')) {
    body = body.slice(1);
  }

  if (body.endsWith('|') && !body.endsWith('\\|')) {
    body = body.slice(0, -1);
  }

  return body.split(/(?<!\\)\|/).map((c) => (unescape ? c.trim().replace(/\\\|/g, '|') : c.trim()));
}

// A line a YAML frontmatter block can hold. With `yamlOnly`, a block holding
// any other line is a pair of horizontal rules, not frontmatter.
const YAML_LINE = /^(?:\s*$|\s*#|[A-Za-z_][\w-]*\s*:|\s+\S|- )/;

// The leading frontmatter block of a document: line 1 (after an optional BOM)
// is `---`, and the block closes at the next line that is `---` once trimmed
// (CRLF-aware). Returns { bom, lines, close }: `lines` is the text after the
// BOM split on `\n` (line endings kept), `close` the index of the closing
// line, or -1 when there is no closed block.
export function frontmatterBlock(text, { yamlOnly = false } = {}) {
  const bom = text.startsWith(BOM) ? BOM : '';
  const lines = text.slice(bom.length).split('\n');
  let close = lines[0].trim() === '---' ? lines.findIndex((l, i) => i > 0 && l.trim() === '---') : -1;

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
