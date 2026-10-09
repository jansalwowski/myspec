#!/usr/bin/env node
// memory-anchor.mjs
// The one definition of when a memory anchor {file, pattern} is live. The
// memory doctor imports it; memory-optimize and memory-preflight run it as a
// command, so a pattern every tool reads the same way stays live in all of
// them or in none (#341: the doctor read `^composer:` against the whole file
// while the skill grepped line by line, and the two disagreed).
//
// An anchor is live when its file is a regular file and one line of it
// matches the pattern:
//   - Lines split on LF; a trailing CR is dropped, so CRLF files read like LF.
//   - The pattern is a POSIX extended regex (`grep -E`), case-sensitive and
//     unanchored: `^` and `$` are the start and end of a line, and no match
//     crosses a line break (`foo.*bar` needs both on one line).
//   - Characters are Unicode code points: `.` matches one emoji, and
//     `[[:alpha:]]`, `[[:lower:]]`, `[[:punct:]]` … match beyond ASCII, as
//     grep does in a UTF-8 locale.
//   - Inside brackets a backslash is literal (`C:[\]`, `path[\/]x`), and a
//     `]` right after `[` or `[^` is a member. `\<`, `\>`, `\b`, `\w`, `\s`
//     work as in GNU and BSD grep. A `*`, `+`, `?` or `{` with nothing to
//     repeat (`^*bullet`) is literal.
//   - BRE escapes are literal, as under `grep -E`: `\|`, `\+`, `\?`, `\(`,
//     `\{` match the character itself. Write alternation as `|`.
//   - A pattern that appears literally on a line is live too (`grep -F`), so
//     `$this->load(` or `a[0]` is found whether or not it parses as a regex.
//   - An empty pattern is no anchor at all; the doctor reports it.
// A false "gone" sends someone to retire a live memory, so where the dialects
// disagree this reads the pattern the generous way: a line also matches when
// the pattern's JavaScript reading matches it (`\d` as a digit, `[\w-]`).
// The same rules, for whoever writes a pattern, are in
// skills/memory-create/SKILL.md Step 4.
//
// Usage:
//   memory-anchor.mjs <file> <pattern>
//     Prints one line. Exit 0 when the anchor is live, 1 when it is not
//     (missing, not-a-file, gone, invalid), 2 on bad usage.
//   memory-anchor.mjs --find <pattern> [-- <pathspec>...]
//     Lists every file git tracks or would track (`git ls-files --cached
//     --others --exclude-standard`) holding a live line, by the same rules.
//     Binary files are skipped. Exit 0 with a hit, 1 with none, 2 on bad
//     usage or outside a git work tree.

import {
  existsSync,
  readFileSync,
  realpathSync,
  statSync,
} from 'node:fs';
import {
  execFileSync,
} from 'node:child_process';
import {
  fileURLToPath,
} from 'node:url';

// grep's classes in a UTF-8 locale, as `u`-mode class members.
const POSIX_CLASSES = {
  alnum: '\\p{L}\\p{M}\\p{Nd}',
  alpha: '\\p{L}\\p{M}',
  blank: ' \\t\\p{Zs}',
  cntrl: '\\p{Cc}',
  digit: '0-9',
  graph: '\\p{L}\\p{M}\\p{N}\\p{P}\\p{S}',
  lower: '\\p{Ll}',
  print: '\\p{L}\\p{M}\\p{N}\\p{P}\\p{S}\\p{Zs}',
  punct: '\\p{P}\\p{S}',
  space: '\\s',
  upper: '\\p{Lu}',
  xdigit: '0-9A-Fa-f',
};

// The same classes in ASCII, for the non-`u` JavaScript reading.
const ASCII_CLASSES = {
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

const SYNTAX = new Set('^$\\.*+?()[]{}|/'.split(''));
const GREP_ESCAPES = new Set('bBwWsS'.split(''));

function literal(ch) {
  return SYNTAX.has(ch) ? `\\${ch}` : ch;
}

// Reads a bracket expression starting at pattern[start] === '['. `posix`
// makes a backslash literal and maps classes to Unicode; otherwise a
// backslash is a JS escape and classes are ASCII. Returns [source, next].
function bracket(pattern, start, posix) {
  const classes = posix ? POSIX_CLASSES : ASCII_CLASSES;
  let out = '[';
  let i = start + 1;

  if (pattern[i] === '^') {
    out += '^';
    i += 1;
  }

  if (pattern[i] === ']') {
    out += '\\]';
    i += 1;
  }

  while (i < pattern.length && pattern[i] !== ']') {
    const named = pattern.slice(i).match(/^\[([:=.])([^\]]+?)\1\]/);

    if (named && named[1] === ':' && classes[named[2]]) {
      out += classes[named[2]];
      i += named[0].length;
    } else if (named && named[1] !== ':' && [...named[2]].length === 1) {
      // [=a=] and [.a.]: one character, as itself.
      out += named[2] === '\\' || named[2] === ']' ? `\\${named[2]}` : named[2];
      i += named[0].length;
    } else if (pattern[i] === '\\') {
      out += posix ? '\\\\' : pattern.slice(i, i + 2);
      i += posix ? 1 : 2;
    } else if (pattern[i] === '[') {
      out += '\\[';
      i += 1;
    } else {
      out += pattern[i];
      i += 1;
    }
  }

  if (i >= pattern.length) {
    throw new SyntaxError('unterminated bracket expression');
  }

  return [`${out}]`, i + 1];
}

// POSIX ERE → a `u`-mode JS source with the same meaning.
export function ereToJs(pattern) {
  let out = '';
  let i = 0;
  // `atom`: where the last repeatable atom starts in `out`, -1 when there
  // is nothing to repeat. `quantified`: that atom already carries one.
  let atom = -1;
  let quantified = false;
  const groups = [];

  const emitAtom = (source) => {
    atom = out.length;
    out += source;
    quantified = false;
  };
  const emitOther = (source) => {
    out += source;
    atom = -1;
    quantified = false;
  };
  const quantify = (q) => {
    if (atom === -1) {
      emitAtom(q.replace(/[{}*+?]/g, '\\$&'));
    } else if (quantified) {
      // `a**`, `a+?`: grep repeats the repetition; JS needs a group for it.
      out = `${out.slice(0, atom)}(?:${out.slice(atom)})${q}`;
    } else {
      out += q;
      quantified = true;
    }
  };

  while (i < pattern.length) {
    const ch = pattern[i];

    if (ch === '\\') {
      const next = pattern[i + 1];

      if (next === undefined) {
        emitAtom('\\\\');
      } else if (/[<>bB]/.test(next)) {
        emitOther(next === 'B' ? '\\B' : '\\b');
      } else if (GREP_ESCAPES.has(next) || /[1-9]/.test(next)) {
        emitAtom(`\\${next}`);
      } else {
        emitAtom(literal(next));
      }

      i += 2;
      continue;
    }

    if (ch === '[') {
      const [source, next] = bracket(pattern, i, true);

      emitAtom(source);
      i = next;
      continue;
    }

    const bound = ch === '{' && pattern.slice(i).match(/^\{\d+(,\d*)?\}/);

    if (bound && atom !== -1) {
      quantify(bound[0]);
      i += bound[0].length;
      continue;
    }

    if (ch === '*' || ch === '+' || ch === '?') {
      quantify(ch);
    } else if (ch === '(') {
      groups.push(out.length);
      emitOther('(');
    } else if (ch === ')' && groups.length > 0) {
      const start = groups.pop();

      out += ')';
      atom = start;
      quantified = false;
    } else if (ch === '|' || ch === '^' || ch === '$') {
      emitOther(ch);
    } else if (ch === '.') {
      emitAtom('.');
    } else {
      emitAtom(literal(ch));
    }

    i += 1;
  }

  return out;
}

// The pattern as JavaScript reads it, with only the ERE constructs JS gets
// wrong rewritten — the generous second reading.
function jsReading(pattern) {
  let out = '';
  let i = 0;

  while (i < pattern.length) {
    if (pattern[i] === '\\' && i + 1 < pattern.length) {
      out += /[<>]/.test(pattern[i + 1]) ? '\\b' : pattern.slice(i, i + 2);
      i += 2;
    } else if (pattern[i] === '[') {
      const [source, next] = bracket(pattern, i, false);

      out += source;
      i = next;
    } else {
      out += pattern[i];
      i += 1;
    }
  }

  return out;
}

function compile(build, source, flags) {
  try {
    return new RegExp(build(source), flags);
  } catch {
    return null;
  }
}

// Returns text → 'live' | 'gone' | 'invalid' (no reading compiles and the
// pattern is not present literally). Compiles once, for --find.
export function anchorMatcher(pattern) {
  // `s`: `.` also matches a stray CR or U+2028 inside a line, as grep's does.
  const readings = [
    compile(ereToJs, pattern, 'su'),
    compile(jsReading, pattern, 's'),
  ].filter(Boolean);

  return (text) => {
    // A pattern holds no LF, so a literal hit is a hit on one line.
    if (text.includes(pattern)) {
      return 'live';
    }

    if (readings.length === 0) {
      return 'invalid';
    }

    const lines = text.split('\n').map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line));

    return lines.some((line) => readings.some((regex) => regex.test(line))) ? 'live' : 'gone';
  };
}

// 'live' | 'gone' | 'invalid' | 'empty'. `text` is the whole file.
export function anchorStatus(text, pattern) {
  return pattern ? anchorMatcher(pattern)(text) : 'empty';
}

// The whole anchor: 'missing' | 'not-a-file' | 'empty' | the pattern's
// status. The doctor and the command both decide through this.
export function checkAnchor(path, pattern) {
  if (!existsSync(path)) {
    return 'missing';
  }

  if (!statSync(path).isFile()) {
    return 'not-a-file';
  }

  return anchorStatus(readFileSync(path, 'utf8'), pattern);
}

function find(pattern, pathspecs) {
  let listing;

  try {
    listing = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', ...pathspecs], {
      encoding: 'utf8',
      maxBuffer: 256 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (err) {
    process.stderr.write(`memory-anchor.mjs: git ls-files failed: ${String(err.stderr || err.message).trim()}\n`);

    return 2;
  }

  const matches = anchorMatcher(pattern);
  const hits = [...new Set(listing.split('\0').filter(Boolean))].filter((file) => {
    if (!existsSync(file) || !statSync(file).isFile()) {
      return false;
    }

    const bytes = readFileSync(file);

    return !bytes.includes(0) && matches(bytes.toString('utf8')) === 'live';
  });

  hits.forEach((file) => process.stdout.write(`${file}\n`));

  return hits.length > 0 ? 0 : 1;
}

function cli(args) {
  if (args[0] === '--find' && args[1] && (args.length === 2 || args[2] === '--')) {
    return find(args[1], args.slice(3));
  }

  if (args.length !== 2 || !args[1] || args[0].startsWith('--')) {
    process.stderr.write('usage: memory-anchor.mjs <file> <pattern>\n       memory-anchor.mjs --find <pattern> [-- <pathspec>...]\n');

    return 2;
  }

  const [file, pattern] = args;
  const status = checkAnchor(file, pattern);
  const messages = {
    missing: `missing: ${file} does not exist`,
    'not-a-file': `not-a-file: ${file} is not a regular file — anchor a file inside it`,
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
