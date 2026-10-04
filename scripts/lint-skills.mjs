#!/usr/bin/env node
// Deterministic static lint for skills/*/SKILL.md. Maintainer tooling: runs in
// CI and in .githooks/pre-commit, never shipped with the plugin.
//
// Each rule encodes a repo convention (skill-optimization.md, skill-verify,
// AGENTS.md); where a past commit fixed that class of defect by hand, it is
// cited, and a citation means the rule reports it on that commit's parent. A rule that cannot be checked without
// false positives is left out rather than softened: this runs on every commit,
// and a hook that cries wolf teaches `--no-verify`.
//
// Usage:
//   node scripts/lint-skills.mjs                      lint <root>/skills/*/SKILL.md
//   node scripts/lint-skills.mjs --files a.md b.md    lint only these files
//   options: --root <dir>  repo root (default: this script's repo)
//            --json        machine-readable output on stdout
// Output: `path:line: RULE-ID message`, one finding per line, paths relative to cwd.
// Exit:   0 clean or warnings only, 1 any error finding, 2 usage or internal error.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ── rule data ────────────────────────────────────────────────────────────────

// Frontmatter keys, from the tier table in framework-files/rules/skill-optimization.md
// (spec, Claude Code + Copilot, Claude Code only, convention). Anything else is a
// typo or an invented mechanism. `load_when` is named explicitly because the
// framework rules shipped it once (ced9dba, in framework-files/rules/, which this
// linter does not read): it gated nothing and loaded 3.2k tokens every session.
const ALLOWED_KEYS = new Set([
  'name', 'description', 'license', 'compatibility', 'metadata', 'allowed-tools',
  'disable-model-invocation', 'user-invocable',
  'model', 'effort', 'context', 'agent', 'hooks', 'paths', 'shell', 'argument-hint',
  'arguments', 'when_to_use', 'disallowed-tools', 'background',
  'tags', 'triggers', 'dependencies',
]);
const KNOWN_BAD_KEYS = {
  load_when: 'not a harness mechanism; it gates nothing. Use `paths:`',
};

// Confusable siblings each description's "Do NOT" clause must keep naming.
// d60997b restored these after a description diet cut them: the sibling name is
// what steers the model away from the wrong skill. Update this map when a
// description deliberately changes its exclusions.
const SIBLINGS = {
  'backbone-sync': ['feature-spec-sync', 'setup'],
  brainstorm: ['feature-plan'],
  'code-review': ['feature-spec-review', 'feature-tech-spec-review', 'skill-verify'],
  'cross-spec-validation': ['feature-spec-review'],
  doctor: ['code-review', 'feature-verify', 'skill-verify'],
  'feature-implement': ['feature-plan'],
  'feature-implement-review': ['code-review', 'feature-verify'],
  'feature-mockup': ['feature-mockup-review'],
  'feature-mockup-review': ['feature-mockup'],
  'feature-spec': ['feature-tech-spec'],
  'feature-spec-review': ['feature-tech-spec-review'],
  'feature-spec-sync': ['backbone-sync', 'feature-status-audit'],
  'feature-status-audit': ['feature-verify'],
  'feature-tech-spec': ['feature-tech-spec-review', 'feature-update'],
  'feature-tech-spec-review': ['code-review', 'feature-spec-review'],
  'feature-update': ['feature-spec'],
  'feature-verify': ['feature-status-audit'],
  'idea-intake': ['idea-process'],
  'idea-process': ['idea-intake'],
  init: ['update'],
  memorify: ['memorize', 'session-complete'],
  memorize: ['memorify'],
  'memory-create': ['memorify', 'memorize'],
  'memory-optimize': ['memory-sanitize'],
  'memory-sanitize': ['memory-optimize'],
  'root-cause-debugging': ['code-review'],
  'session-clean': ['session-complete'],
  'session-complete': ['session-clean'],
  setup: ['init'],
  update: ['init'],
};

// Top-level directories of this repo that exist in no consumer project. A
// `dependencies: paths:` entry resolving into one of them false-fails
// skill-self-test as Critical in every repo the plugin is installed in
// (AGENTS.md, "Never declare plugin-internal paths"; v1.20.0 mockup audits).
const PLUGIN_INTERNAL_DIRS = [
  'skills', 'plugins', 'blueprints', 'framework-files', 'scaffolding', 'templates',
  'lib', 'hooks', 'examples', '.codex-plugin', '.claude-plugin',
];

// Caps. The spec allows 1,024 description chars; this repo caps each at 350
// so no single skill crowds a consumer's own skills out of the listing
// (docs/myspec-2.0-breaking-changes.md, the 2.0 description diet: every
// description was rewritten to fit, and code-review, memorize and doctor had
// drifted back over it by 2.11, issue #264). LISTING_MAX is Claude Code's own
// truncation point (skills/skill-verify/references/detection-patterns.md).
const DESCRIPTION_MAX = 350;
const LISTING_MAX = 1536; // description + when_to_use, Claude Code listing truncation
const BODY_TOKEN_BUDGET = 5000; // truncated past this on re-injection after /compact
const BODY_LINE_BUDGET = 500;
const NAME_RE = /^[a-z0-9]$|^[a-z0-9](?:[a-z0-9]|-(?!-)){0,62}[a-z0-9]$/;
const WORKFLOW_RE = /\b(analyzes?|generates?|creates?|validates?|checks?)\b.*\b(then|next|after|finally)\b/i;

// Narrow per-skill exemptions: { skill: { RULE: 'reason' } }. Keep each one
// tied to an owner and remove it when the finding is fixed.
const EXEMPT = {
  // code-review is removed by #258; drop this entry with the skill.
  'code-review': { 'DESC-LENGTH': 'removed by #258' },
};

// ── helpers ──────────────────────────────────────────────────────────────────

const HERE = path.dirname(fileURLToPath(import.meta.url));

function usage(msg) {
  process.stderr.write(`lint-skills: ${msg}\n` +
    'usage: node scripts/lint-skills.mjs [--root <dir>] [--json] [--files <path>...]\n');
  process.exit(2);
}

function parseArgs(argv) {
  const opts = { root: path.resolve(HERE, '..'), json: false, files: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') opts.json = true;
    else if (a === '--root') {
      if (i + 1 >= argv.length) usage('--root needs a directory');
      opts.root = path.resolve(argv[++i]);
    } else if (a === '--files') {
      opts.files = argv.slice(i + 1);
      break;
    } else if (a === '-h' || a === '--help') {
      process.stdout.write('usage: node scripts/lint-skills.mjs [--root <dir>] [--json] [--files <path>...]\n');
      process.exit(0);
    } else usage(`unknown argument: ${a}`);
  }
  return opts;
}

function unquote(v) {
  v = v.trim();
  if (v.length >= 2 && v[0] === '"' && v.endsWith('"')) {
    return v.slice(1, -1).replace(/\\(["\\])/g, '$1').replace(/\\n/g, '\n');
  }
  if (v.length >= 2 && v[0] === "'" && v.endsWith("'")) return v.slice(1, -1).replace(/''/g, "'");
  return v;
}

function parseInlineList(v) {
  const inner = v.trim().slice(1, -1).trim();
  return inner ? inner.split(',').map((s) => unquote(s)) : [];
}

// Minimal YAML reader for SKILL.md frontmatter: top-level scalars (plain,
// quoted, multi-line quoted, block `|`/`>`), inline and block lists, and one
// level of nested maps (the `dependencies:` shape). Returns key → {value, line}.
function parseFrontmatter(lines, startLine) {
  const out = {};
  const errors = [];
  let i = 0;
  const indentOf = (s) => s.length - s.trimStart().length;
  while (i < lines.length) {
    const raw = lines[i];
    const lineNo = startLine + i;
    if (!raw.trim() || raw.trimStart().startsWith('#')) { i++; continue; }
    if (indentOf(raw) > 0) { errors.push({ line: lineNo, msg: `unexpected indented line: ${raw.trim()}` }); i++; continue; }
    const m = raw.match(/^([^:\s][^:]*?):(?:\s+(.*))?$/);
    if (!m) { errors.push({ line: lineNo, msg: `not a \`key: value\` line: ${raw.trim()}` }); i++; continue; }
    const key = m[1].trim();
    let rest = (m[2] ?? '').trim();
    i++;
    let value;
    if (rest === '' ) {
      // Block: a list, a nested map, or empty.
      const block = [];
      while (i < lines.length && (lines[i].trim() === '' || indentOf(lines[i]) > 0 || /^-\s/.test(lines[i]))) {
        block.push({ text: lines[i], line: startLine + i });
        i++;
      }
      value = parseBlock(block);
    } else if (/^[|>][-+]?$/.test(rest)) {
      const parts = [];
      while (i < lines.length && (lines[i].trim() === '' || indentOf(lines[i]) > 0)) { parts.push(lines[i].trim()); i++; }
      value = rest[0] === '|' ? parts.join('\n').trim() : parts.filter(Boolean).join(' ');
    } else if ((rest[0] === '"' || rest[0] === "'") && !(rest.length > 1 && rest.endsWith(rest[0]) && !rest.endsWith('\\' + rest[0]))) {
      // Quoted scalar continuing on the next lines.
      const q = rest[0];
      let acc = rest;
      while (i < lines.length) {
        acc += ' ' + lines[i].trim();
        i++;
        if (acc.endsWith(q) && !acc.endsWith('\\' + q)) break;
      }
      value = unquote(acc);
    } else if (rest.startsWith('[') && rest.endsWith(']')) {
      value = parseInlineList(rest);
    } else {
      // Plain scalar, possibly folded over indented continuation lines.
      while (i < lines.length && lines[i].trim() !== '' && indentOf(lines[i]) > 0) { rest += ' ' + lines[i].trim(); i++; }
      value = unquote(rest);
    }
    if (key in out) errors.push({ line: lineNo, msg: `duplicate key \`${key}\`` });
    out[key] = { value, line: lineNo };
  }
  return { fields: out, errors };
}

function parseBlock(block) {
  const items = block.filter((b) => b.text.trim() !== '');
  if (items.length === 0) return null;
  if (/^\s*-\s/.test(items[0].text) || items[0].text.trim() === '-') {
    return items.filter((b) => /^\s*-/.test(b.text)).map((b) => unquote(b.text.trim().replace(/^-\s*/, '').replace(/\s+#.*$/, '')));
  }
  // Nested map, one level deep: sub-keys at the first item's indent.
  const baseIndent = items[0].text.length - items[0].text.trimStart().length;
  const map = {};
  let cur = null;
  for (const b of items) {
    const ind = b.text.length - b.text.trimStart().length;
    const t = b.text.trim();
    if (ind === baseIndent && /^[^-\s][^:]*:/.test(t)) {
      const [, k, v] = t.match(/^([^:]+):\s*(.*)$/);
      cur = k.trim();
      const vv = v.replace(/\s+#.*$/, '').trim();
      map[cur] = vv === '' ? [] : vv.startsWith('[') ? parseInlineList(vv) : unquote(vv);
    } else if (cur && /^-/.test(t) && Array.isArray(map[cur])) {
      map[cur].push({ value: unquote(t.replace(/^-\s*/, '').replace(/\s+#.*$/, '')), line: b.line });
    }
  }
  return map;
}

// GitHub heading anchors (github-slugger over the heading text): lowercase,
// drop punctuation except `-` and `_`, spaces to hyphens, duplicates suffixed
// -1, -2, … Built from the raw heading, so inline code keeps its text. Whether
// `_x_` keeps its underscores depends on how the renderer reads it, so both
// spellings count: a missed dead anchor is cheaper than a false alarm.
function slugify(s) {
  return s.toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc}\s-]/gu, '').replace(/ /g, '-');
}
function headingSlugs(lines) {
  const variants = [
    (h) => h.replace(/[`*~]/g, ''),
    (h) => h.replace(/[`*~_]/g, ''),
  ];
  const slugs = new Set();
  for (const v of variants) {
    const seen = new Map();
    for (const { text } of lines) {
      const m = text.match(/^ {0,3}#{1,6}\s+(.*?)(?:\s+#+)?\s*$/);
      if (!m) continue;
      let slug = slugify(v(m[1].replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')));
      const n = seen.get(slug) ?? 0;
      seen.set(slug, n + 1);
      if (n > 0) slug = `${slug}-${n}`;
      slugs.add(slug);
    }
  }
  return slugs;
}
function hasAnchor(slugs, anchor) {
  let a = anchor;
  try { a = decodeURIComponent(anchor); } catch { /* keep raw */ }
  return slugs.has(a) || slugs.has(a.toLowerCase());
}

// Body lines outside fenced code blocks, raw.
function unfencedLines(bodyLines) {
  const out = [];
  let fence = null;
  for (const l of bodyLines) {
    const f = l.text.match(/^\s*(`{3,}|~{3,})/);
    if (fence) {
      if (f && f[1][0] === fence[0] && f[1].length >= fence.length) fence = null;
      continue;
    }
    if (f) { fence = f[1]; continue; }
    out.push(l);
  }
  return out;
}

// The same, with inline code spans blanked: prose a reader acts on.
function proseLines(bodyLines) {
  return unfencedLines(bodyLines).map((l) => ({ text: l.text.replace(/(`+)[^`]*?\1/g, (s) => ' '.repeat(s.length)), line: l.line }));
}

// ── rules ────────────────────────────────────────────────────────────────────

function lintFile(absPath, ctx) {
  const findings = [];
  const add = (line, rule, message, severity = 'error') => findings.push({ line, rule, message, severity });
  const text = fs.readFileSync(absPath, 'utf8').replace(/^\uFEFF/, '');
  const all = text.split(/\r?\n/);
  const isFence = (l) => l.trimEnd() === '---';
  const dirName = path.basename(path.dirname(absPath));

  // FM-MISSING — frontmatter present and closed.
  if (!isFence(all[0])) {
    add(1, 'FM-MISSING', 'SKILL.md must start with a `---` YAML frontmatter block');
    return findings;
  }
  const close = all.findIndex((l, k) => k > 0 && isFence(l));
  if (close < 0) {
    add(1, 'FM-MISSING', 'frontmatter block is never closed with `---`');
    return findings;
  }
  const { fields, errors } = parseFrontmatter(all.slice(1, close), 2);
  for (const e of errors) add(e.line, 'FM-PARSE', e.msg);

  // FM-UNKNOWN-KEY — allowlist from skill-optimization.md's tier table.
  for (const [key, { line }] of Object.entries(fields)) {
    if (KNOWN_BAD_KEYS[key]) add(line, 'FM-UNKNOWN-KEY', `\`${key}\` is not a skill frontmatter key: ${KNOWN_BAD_KEYS[key]}`);
    else if (!ALLOWED_KEYS.has(key)) add(line, 'FM-UNKNOWN-KEY', `\`${key}\` is not in the frontmatter allowlist (framework-files/rules/skill-optimization.md tier table)`);
  }

  // NAME-* — present, spec format, equals the directory Claude Code loads it under.
  const name = fields.name;
  if (!name || typeof name.value !== 'string' || name.value === '') {
    add(name?.line ?? 1, 'NAME-MISSING', '`name` is required');
  } else {
    if (!NAME_RE.test(name.value)) add(name.line, 'NAME-FORMAT', `\`${name.value}\`: 1-64 chars of [a-z0-9-], no leading, trailing or doubled hyphen`);
    if (/\b(anthropic|claude)\b/i.test(name.value)) add(name.line, 'NAME-FORMAT', `\`${name.value}\` contains a reserved word`);
    if (name.value !== dirName) add(name.line, 'NAME-MISMATCH', `\`name: ${name.value}\` does not match its directory \`${dirName}\``);
  }

  // Invocation mode decides which description rules apply.
  const truthy = (f) => f && String(f.value).trim() === 'true';
  const falsy = (f) => f && String(f.value).trim() === 'false';
  const manualOnly = truthy(fields['disable-model-invocation']);
  if (manualOnly && falsy(fields['user-invocable'])) {
    add(fields['user-invocable'].line, 'INVOCATION-NONE', '`disable-model-invocation: true` with `user-invocable: false` leaves the skill invocable by nobody');
  }

  // DESC-* — the description is the trigger (886a3ab, d60997b).
  const desc = fields.description;
  const d = desc && typeof desc.value === 'string' ? desc.value : '';
  if (!d.trim()) {
    add(desc?.line ?? 1, 'DESC-MISSING', '`description` is required and non-empty');
  } else {
    if (d.length > DESCRIPTION_MAX) add(desc.line, 'DESC-LENGTH', `description is ${d.length} chars; the cap is ${DESCRIPTION_MAX} (the 2.0 description diet; rewrite, do not truncate)`);
    const wtu = fields.when_to_use && typeof fields.when_to_use.value === 'string' ? fields.when_to_use.value : '';
    if (d.length + wtu.length > LISTING_MAX) add(desc.line, 'DESC-LENGTH', `description + when_to_use is ${d.length + wtu.length} chars; Claude Code truncates the listing at ${LISTING_MAX}`);
    if (!manualOnly) {
      if (!/^Use when\b/.test(d)) add(desc.line, 'DESC-USE-WHEN', 'a model-invocable description must start with "Use when" (skill-optimization.md; d60997b)');
      if (WORKFLOW_RE.test(d)) add(desc.line, 'DESC-WORKFLOW', 'description reads as a workflow summary (verb … then/next/after); the model follows it instead of the body (886a3ab)', 'warning');
      const siblings = SIBLINGS[dirName] ?? [];
      const idx = d.search(/\bdo not\b/i);
      if (idx < 0) {
        add(desc.line, 'DESC-DO-NOT', siblings.length
          ? `description has no "Do NOT use …" clause; it must name ${siblings.join(', ')} (d60997b)`
          : 'description has no "Do NOT use …" clause (skill-optimization.md: end with the exclusions)');
      } else {
        const tail = d.slice(idx);
        const missing = siblings.filter((s) => !new RegExp(`(^|[^a-z0-9-])${s.replace(/[-]/g, '\\-')}([^a-z0-9-]|$)`, 'i').test(tail));
        if (missing.length) add(desc.line, 'DESC-DO-NOT', `the "Do NOT" clause no longer names its confusable sibling(s): ${missing.join(', ')} (d60997b; SIBLINGS in scripts/lint-skills.mjs)`);
      }
    }
  }

  // DEP-PLUGIN-PATH — dependencies.paths must be consumer-repo paths.
  const deps = fields.dependencies?.value;
  if (deps && typeof deps === 'object' && !Array.isArray(deps) && Array.isArray(deps.paths)) {
    for (const p of deps.paths) {
      const v = typeof p === 'string' ? p : p.value;
      const line = typeof p === 'string' ? fields.dependencies.line : p.line;
      const rel = v.replace(/^\.\//, '');
      const top = rel.split('/')[0];
      if (PLUGIN_INTERNAL_DIRS.includes(top) && fs.existsSync(path.join(ctx.root, rel))) {
        add(line, 'DEP-PLUGIN-PATH', `\`${v}\` is a path inside the myspec plugin; skill-self-test checks it against the consumer repo, where it never exists (AGENTS.md)`);
      }
    }
  }

  const body = all.slice(close + 1).map((t, k) => ({ text: t, line: close + 2 + k }));
  const prose = proseLines(body);

  // STEP-REF — a navigation pointer ("skip to step 8", "go to Step 5",
  // "proceed to Workflow Step 0", "see Step 4") must name a step this file
  // defines — the class of bug a3562ed fixed. Pointers qualified with another
  // document ("Step 4 of memory-create", "Step 3 in feature-implement") and
  // bare mentions ("the Step 2 answers") are not checked.
  const defined = new Set();
  for (const { text: t } of unfencedLines(body)) {
    const h = t.match(/^#{1,6}\s+(.*)$/);
    if (h) {
      for (const s of h[1].matchAll(/\bStep\s+(\d+(?:\.\d+)?[a-z]?)\b/gi)) defined.add(s[1].toLowerCase());
      const num = h[1].match(/^(?:\*\*)?(\d+(?:\.\d+)?[a-z]?)[.:)]?\s/);
      if (num) defined.add(num[1].toLowerCase());
    }
    const item = t.match(/^(\d+)\.\s/);
    if (item) defined.add(item[1]);
    const bold = t.match(/^\s*(?:[-*]\s+)?\*\*Step\s+(\d+(?:\.\d+)?[a-z]?)\b/i);
    if (bold) defined.add(bold[1].toLowerCase());
  }
  const POINTER_RE = /\b(?:(?:skip|go|jump|return|proceed|continue|move|loop|resume|restart)(?:s|ing|ed)?\s+(?:back\s+)?(?:to|at)|see)\s+(?:the\s+)?(?:Workflow\s+)?Step\s+(\d+(?:\.\d+)?[a-z]?)(?!\w|\.\d)(?!\s+(?:of|in|from)\b)/gi;
  for (const { text: t, line } of prose) {
    for (const m of t.matchAll(POINTER_RE)) {
      const n = m[1].toLowerCase();
      if (!defined.has(n)) add(line, 'STEP-REF', `"${m[0]}" points at a step this file does not define`);
    }
  }

  // LINK-DEAD / LINK-ANCHOR — relative links resolve on disk; #anchors resolve
  // to a heading. Placeholder targets ({feature}, <x>, $VAR, …) are template
  // content, not references, and are skipped.
  const ownSlugs = headingSlugs(unfencedLines(body));
  for (const { text: t, line } of prose) {
    for (const m of t.matchAll(/!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
      const target = m[1];
      if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('/') || /[{}<>$…*]/.test(target)) continue;
      const [file, anchor] = target.split('#');
      if (!file) {
        if (anchor && !hasAnchor(ownSlugs, anchor)) add(line, 'LINK-ANCHOR', `\`#${anchor}\` matches no heading in this file`);
        continue;
      }
      let decoded;
      try { decoded = decodeURIComponent(file); } catch { decoded = file; }
      const abs = path.resolve(path.dirname(absPath), decoded);
      if (!fs.existsSync(abs)) {
        add(line, 'LINK-DEAD', `link target \`${target}\` does not exist`);
        continue;
      }
      if (anchor && /\.md$/i.test(abs) && fs.statSync(abs).isFile()) {
        const tl = fs.readFileSync(abs, 'utf8').split(/\r?\n/).map((x, k) => ({ text: x, line: k + 1 }));
        if (!hasAnchor(headingSlugs(unfencedLines(tl)), anchor)) add(line, 'LINK-ANCHOR', `\`${target}\`: no heading with that anchor in the target`);
      }
    }
  }

  // SIZE-BUDGET (warning) — body tokens ≈ chars / 4; past 5,000 the body is
  // truncated when re-attached after /compact (skill-optimization.md).
  const bodyText = body.map((b) => b.text).join('\n');
  const tokens = Math.ceil(bodyText.length / 4);
  if (tokens > BODY_TOKEN_BUDGET || body.length > BODY_LINE_BUDGET) {
    add(close + 2, 'SIZE-BUDGET', `body is ~${tokens} tokens / ${body.length} lines; budget is ${BODY_TOKEN_BUDGET} tokens / ${BODY_LINE_BUDGET} lines — move step-specific material to references/`, 'warning');
  }

  const exempt = EXEMPT[dirName] ?? {};
  return findings.filter((f) => !exempt[f.rule]);
}

// ── main ─────────────────────────────────────────────────────────────────────

function main() {
  const opts = parseArgs(process.argv.slice(2));
  let files;
  if (opts.files) {
    if (opts.files.length === 0) usage('--files needs at least one path');
    files = opts.files.map((f) => path.resolve(f));
    const missing = files.filter((f) => !fs.existsSync(f));
    if (missing.length) usage(`no such file: ${missing.map((f) => path.relative(process.cwd(), f)).join(', ')}`);
  } else {
    const dir = path.join(opts.root, 'skills');
    if (!fs.existsSync(dir)) usage(`no skills/ directory under ${opts.root}`);
    files = fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith('_'))
      .map((e) => path.join(dir, e.name, 'SKILL.md'))
      .filter((f) => fs.existsSync(f))
      .sort();
  }

  const results = [];
  for (const f of files) {
    const rel = path.relative(process.cwd(), f) || f;
    for (const x of lintFile(f, opts)) results.push({ path: rel, ...x });
  }
  const errors = results.filter((r) => r.severity === 'error').length;
  const warnings = results.length - errors;

  if (opts.json) {
    process.stdout.write(JSON.stringify({ files: files.length, errors, warnings, findings: results }, null, 2) + '\n');
  } else {
    for (const r of results) {
      process.stdout.write(`${r.path}:${r.line}: ${r.rule} ${r.severity === 'warning' ? 'warning: ' : ''}${r.message}\n`);
    }
    process.stderr.write(`lint-skills: ${files.length} file(s), ${errors} error(s), ${warnings} warning(s)\n`);
  }
  process.exit(errors ? 1 : 0);
}

try {
  main();
} catch (e) {
  process.stderr.write(`lint-skills: internal error: ${e.stack || e}\n`);
  process.exit(2);
}
