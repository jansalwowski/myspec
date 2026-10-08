#!/usr/bin/env node
// memory-anchor.mjs
// The one definition of when a memory anchor {file, pattern} is live. The
// memory doctor imports it; memory-optimize and memory-preflight run it as a
// command, so a pattern every tool reads the same way stays live in all of
// them or in none (#341: the doctor read `^composer:` against the whole file
// while the skill grepped line by line, and the two disagreed).
//
// A pattern is live when one line of the file matches it:
//   - Lines split on LF; a trailing CR is dropped, so CRLF files read like LF.
//   - The pattern is a POSIX extended regex (`grep -E`), case-sensitive and
//     unanchored: `^` and `$` are the start and end of a line, and no match
//     crosses a line break (`foo.*bar` needs both on one line).
//   - Bracket classes such as `[[:alpha:]]` and the word boundaries `\<`,
//     `\>` and `\b` work as in GNU and BSD grep. `\w`, `\s` and `\d` match
//     word, space and digit characters; portable patterns avoid them.
//   - BRE escapes are literal, as under `grep -E`: `\|`, `\+`, `\?`, `\(`,
//     `\{` match the character itself. Write alternation as `|`.
//   - A pattern that appears literally on a line is live too (`grep -F`), so
//     `$this->load(` or `a[0]` is found whether or not it parses as a regex.
//   - An empty pattern is no anchor at all; the doctor reports it.
// A false "gone" sends someone to retire a live memory, so where the dialects
// disagree this reads the pattern the generous way. The same rules, for
// whoever writes a pattern, are in skills/memory-create/SKILL.md Step 4.
//
// Usage: memory-anchor.mjs <file> <pattern>
//   Prints one line. Exit 0 when the anchor is live, 1 when the file is
//   missing or the pattern no longer matches, 2 on bad usage.

import {
  existsSync,
  readFileSync,
  realpathSync,
  statSync,
} from 'node:fs';
import {
  fileURLToPath,
} from 'node:url';

const POSIX_CLASSES = {
  alnum: 'a-zA-Z0-9',
  alpha: 'a-zA-Z',
  blank: ' \\t',
  cntrl: '\\x00-\\x1f\\x7f',
  digit: '0-9',
  graph: '\\x21-\\x7e',
  lower: 'a-z',
  print: '\\x20-\\x7e',
  punct: '!-\\/:-@\\[-`{-~',
  space: ' \\t\\n\\r\\f\\v',
  upper: 'A-Z',
  xdigit: '0-9A-Fa-f',
};

// Rewrites the ERE constructs JavaScript reads differently: POSIX classes
// inside brackets, a `]` that opens a bracket (a literal in ERE, an empty
// class in JS), and the `\<` / `\>` word boundaries. Everything else in ERE
// means the same in a JS RegExp without the `u` flag.
export function ereToJs(pattern) {
  let out = '';
  let i = 0;

  while (i < pattern.length) {
    const ch = pattern[i];

    if (ch === '\\' && i + 1 < pattern.length) {
      const next = pattern[i + 1];

      out += (next === '<' || next === '>') ? '\\b' : `\\${next}`;
      i += 2;
      continue;
    }

    if (ch !== '[') {
      out += ch;
      i += 1;
      continue;
    }

    out += '[';
    i += 1;

    if (pattern[i] === '^') {
      out += '^';
      i += 1;
    }

    if (pattern[i] === ']') {
      out += '\\]';
      i += 1;
    }

    while (i < pattern.length && pattern[i] !== ']') {
      const cls = pattern.slice(i).match(/^\[:([a-z]+):\]/);

      if (cls && POSIX_CLASSES[cls[1]]) {
        out += POSIX_CLASSES[cls[1]];
        i += cls[0].length;
      } else if (pattern[i] === '\\' && i + 1 < pattern.length) {
        out += pattern.slice(i, i + 2);
        i += 2;
      } else if (pattern[i] === '[') {
        out += '\\[';
        i += 1;
      } else {
        out += pattern[i];
        i += 1;
      }
    }

    if (i < pattern.length) {
      out += ']';
      i += 1;
    }
  }

  return out;
}

// 'live' | 'gone' | 'invalid' (not a regex, and not present literally) |
// 'empty'. `text` is the whole file.
export function anchorStatus(text, pattern) {
  if (!pattern) {
    return 'empty';
  }

  const lines = text.split('\n').map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line));

  if (lines.some((line) => line.includes(pattern))) {
    return 'live';
  }

  let regex;

  try {
    // `s`: `.` also matches a stray CR or U+2028 inside a line, as grep's does.
    regex = new RegExp(ereToJs(pattern), 's');
  } catch {
    return 'invalid';
  }

  return lines.some((line) => regex.test(line)) ? 'live' : 'gone';
}

export function anchorMatches(text, pattern) {
  return anchorStatus(text, pattern) === 'live';
}

function cli(args) {
  if (args.length !== 2 || !args[1]) {
    process.stderr.write('usage: memory-anchor.mjs <file> <pattern>\n');

    return 2;
  }

  const [file, pattern] = args;

  if (!existsSync(file) || !statSync(file).isFile()) {
    process.stdout.write(`missing: ${file} is not a file\n`);

    return 1;
  }

  const status = anchorStatus(readFileSync(file, 'utf8'), pattern);
  const messages = {
    live: `live: ${JSON.stringify(pattern)} matches a line of ${file}`,
    gone: `gone: ${JSON.stringify(pattern)} matches no line of ${file}`,
    invalid: `invalid: ${JSON.stringify(pattern)} is not a valid regex and does not appear literally in ${file}`,
  };

  process.stdout.write(`${messages[status]}\n`);

  return status === 'live' ? 0 : 1;
}

// import.meta.url is the realpath; argv[1] keeps any symlink on the way.
function invokedDirectly() {
  if (!process.argv[1]) { return false; }
  try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; }
}

if (invokedDirectly()) {
  process.exitCode = cli(process.argv.slice(2));
}
