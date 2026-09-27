#!/usr/bin/env node
// dead-paths: find repo paths cited in live feature docs that no longer resolve.
// Read-only. Zero npm dependencies.
//
// WHY: feature-spec-sync used to validate only the tech-spec File Inventory.
// Paths cited anywhere else in spec.md, tech-spec.md, index.yaml, scenarios.md
// and seed.json rotted silently after refactors, and the docs kept sending
// agents to files that did not exist.
//
// WHAT counts as a path: a markdown backtick span (or a YAML/JSON scalar) with
// no whitespace that contains `/` and either ends in a known file extension or
// starts with a top-level directory that exists in the repo (or is named via
// --prefix). The top-level-dir rule is what keeps this project-agnostic: no
// `src/` list to maintain. --prefix exists for the one case that rule misses,
// an extension-less path under a top-level dir that was deleted outright.
//
// WHAT is skipped: plans/ (live and archived — plans are history), CHANGELOG.md,
// URLs, globs, placeholders ({x}, <x>, ${x}), absolute and alias paths
// (/x, ~/x, @/x), fenced code blocks, rename/history tables and sections, and
// the left side of an inline `old` -> `new` arrow.
//
// Resolution is from the repo root (cwd), then the citing doc's directory and
// the features dir (doc cross-links like `acl/spec.md`). An extension-less path
// is a module reference in any language: it matches a directory, or a file
// <path>.<ext> for any source extension (`app/models/user` -> user.py,
// `internal/queue/worker` -> worker.go). A path that is the tail of a real one
// (`router/index.ts`) is package-relative shorthand and passes. An unresolved
// path is MOVED when the git tree holds exactly one file with the same basename
// or the same stem (any source extension for an extension-less path, the JS
// family for a JS-family one, since foo.js -> foo.ts is one module); otherwise
// MISSING.
//
// Usage:
//   node dead-paths.mjs [--ai-dir=<path>] [--only=<feature>] [--prefix=a,b] [--json]
//
// Exit codes: 0 clean, 1 MISSING or MOVED paths found, 3 cannot run.

import { readFileSync, existsSync, statSync, readdirSync } from 'node:fs'
import { join, resolve, relative, dirname, posix } from 'node:path'
import { execFileSync } from 'node:child_process'
import { argv, cwd, exit, stdout, stderr } from 'node:process'

const args = {}
for (const raw of argv.slice(2)) {
  if (!raw.startsWith('--')) { continue }
  const body = raw.slice(2)
  const eq = body.indexOf('=')
  if (eq === -1) { args[body] = true } else { args[body.slice(0, eq)] = body.slice(eq + 1) }
}

const root = resolve(cwd())
const jsonMode = args.json === true
for (const k of ['ai-dir', 'only', 'prefix']) {
  if (args[k] === true) { fail(`--${k} needs a value: --${k}=<value>`) }
}
const aiDir = resolve(root, args['ai-dir'] ?? detectAiDir())
const featuresDir = join(aiDir, 'features')
const aiRel = relative(root, aiDir)
const scanDir = args.only ? join(featuresDir, args.only) : featuresDir
const extraPrefixes = new Set((args.prefix ?? '').split(',').map(s => s.trim().replace(/\/+$/, '')).filter(Boolean))

if (!isDir(featuresDir)) { fail(`features directory not found: ${relative(root, featuresDir) || featuresDir}`) }
if (!isDir(scanDir)) { fail(`feature not found: ${relative(root, scanDir)}`) }

const LIVE_DOCS = new Set(['spec.md', 'tech-spec.md', 'index.yaml', 'scenarios.md', 'seed.json'])
const SKIP_DOC_DIRS = new Set(['plans', 'archive'])
// Extensions one module can swap between without becoming a different file.
const JS_FAMILY_EXTS = ['js', 'ts', 'tsx', 'jsx', 'vue', 'mjs', 'cjs']
// What an extension-less module reference can name. Docs, data, and lockfiles
// are not modules: `app/services/user` must not resolve to, or move to, user.md.
const MODULE_EXTS = [
  ...JS_FAMILY_EXTS, 'svelte', 'astro', 'py', 'rb', 'go', 'rs', 'java', 'kt', 'swift',
  'php', 'cs', 'c', 'h', 'cpp',
]
const KNOWN_EXTS = new Set([
  ...JS_FAMILY_EXTS, 'svelte', 'astro', 'py', 'rb', 'go', 'rs', 'java', 'kt', 'swift',
  'php', 'cs', 'c', 'h', 'cpp', 'json', 'jsonc', 'yaml', 'yml', 'toml', 'md', 'mdx',
  'sql', 'prisma', 'graphql', 'gql', 'proto', 'css', 'scss', 'sass', 'less', 'html',
  'sh', 'xml', 'ini', 'lock', 'txt', 'tf', 'snap', 'feature',
])
const HISTORY_HEADING = /\b(renam\w*|history|changelog|moved|migrat\w*)\b/i
const HISTORY_COLUMN = /^\s*(old|previous|former|before|from|was|renamed from)\b/i
const ARROW_AFTER = /^\s*(→|->|=>|⇒)/

// ───────────────────── repo tree ─────────────────────

const topDirs = new Set(readdirSync(root, { withFileTypes: true }).filter(d => d.isDirectory() && d.name !== '.git').map(d => d.name))
const treeFiles = listTree()
const byBase = new Map()
for (const f of treeFiles) {
  const b = posix.basename(f)
  if (!byBase.has(b)) { byBase.set(b, []) }
  byBase.get(b).push(f)
}
const treeDirs = new Set()
for (const f of treeFiles) {
  for (let d = posix.dirname(f); d !== '.'; d = posix.dirname(d)) { treeDirs.add(d) }
}

function listTree() {
  try {
    const out = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 256 * 1024 * 1024 })
    return out.split('\0').filter(f => f && isFile(join(root, f)))
  } catch {
    const files = []
    const walk = (dir) => {
      for (const e of readdirSync(join(root, dir), { withFileTypes: true })) {
        if (e.isDirectory()) {
          if (e.name !== 'node_modules' && !e.name.startsWith('.')) { walk(dir ? `${dir}/${e.name}` : e.name) }
        } else if (e.isFile()) { files.push(dir ? `${dir}/${e.name}` : e.name) }
      }
    }
    walk('')
    return files
  }
}

// ───────────────────── extraction ─────────────────────

function docFiles(dir) {
  const found = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) { if (!SKIP_DOC_DIRS.has(e.name)) { found.push(...docFiles(p)) } } else if (e.isFile() && LIVE_DOCS.has(e.name)) { found.push(p) }
  }
  return found.sort()
}

// Returns [{ line, token }] for one doc.
function extract(file) {
  const lines = readFileSync(file, 'utf8').split('\n')
  return file.endsWith('.md') ? extractMarkdown(lines) : extractData(lines)
}

function extractMarkdown(lines) {
  const refs = []
  let fence = null
  let historyLevel = 0          // heading level of an enclosing history section, 0 = none
  let historyTable = false      // inside a table whose header names an old/previous column
  let inFrontmatter = lines[0] === '---'
  lines.forEach((text, i) => {
    if (inFrontmatter) { if (i > 0 && text === '---') { inFrontmatter = false } return }
    const f = text.match(/^\s*(```|~~~)/)
    if (f) { fence = fence === null ? f[1] : (f[1] === fence ? null : fence); return }
    if (fence) { return }
    const h = text.match(/^(#{1,6})\s+(.*)$/)
    if (h) {
      const level = h[1].length
      if (historyLevel && level <= historyLevel) { historyLevel = 0 }
      if (!historyLevel && HISTORY_HEADING.test(h[2])) { historyLevel = level }
      historyTable = false
      return
    }
    if (historyLevel) { return }
    if (/^\s*\|/.test(text)) {
      const next = lines[i + 1] ?? ''
      if (/^\s*\|[\s:|-]+\|?\s*$/.test(next) && !/^\s*\|[\s:|-]+\|?\s*$/.test(text)) {
        historyTable = text.split('|').some(cell => HISTORY_COLUMN.test(cell))
      }
      if (historyTable) { return }
    } else {
      historyTable = false
    }
    const re = /(~~)?`([^`\n]+)`/g
    let m
    while ((m = re.exec(text)) !== null) {
      if (m[1]) { continue }                                    // struck through
      if (ARROW_AFTER.test(text.slice(m.index + m[0].length))) { continue }  // `old` -> `new`
      refs.push({ line: i + 1, token: m[2] })
    }
  })
  return refs
}

function extractData(lines) {
  const refs = []
  lines.forEach((text, i) => {
    if (/^\s*#/.test(text)) { return }
    const quoted = [...text.matchAll(/"((?:[^"\\]|\\.)*)"|'([^']*)'/g)].map(m => m[1] ?? m[2])
    const bare = text.replace(/"(?:[^"\\]|\\.)*"|'[^']*'/g, ' ').replace(/\s#.*$/, '').split(/[\s,[\]{}]+/)
    for (const token of [...quoted, ...bare]) {
      if (token) { refs.push({ line: i + 1, token: token.replace(/^-\s*/, '').replace(/:$/, '') }) }
    }
  })
  return refs
}

// Normalizes a raw token to a repo-relative path, or null when it is not one.
function toPath(raw) {
  let t = raw.trim()
  if (!t || /\s/.test(t)) { return null }
  if (/:\/\/|^www\.|^mailto:/i.test(t)) { return null }            // URL
  if (/[*?[\]{}<>$]|\.\.\.|…/.test(t)) { return null }              // glob or placeholder
  if (/^[/~@#]/.test(t)) { return null }                           // absolute, home, alias, anchor
  t = t.replace(/^\.\//, '').replace(/(:\d+(-\d+)?|#L\d+(-L?\d+)?)$/, '').replace(/[.,;:)]+$/, '')
  if (!t.includes('/') || t.includes('//') || t.startsWith('../')) { return null }
  if (!/^[\w.@+-]+(\/[\w.@+-]+)*\/?$/.test(t)) { return null }
  const first = t.split('/')[0]
  if (hasKnownExt(t) || topDirs.has(first) || extraPrefixes.has(first)) { return t }
  return null
}

function extOf(p) {
  const b = posix.basename(p)
  const dot = b.lastIndexOf('.')
  return dot > 0 ? b.slice(dot + 1).toLowerCase() : ''
}
function hasKnownExt(p) { return !p.endsWith('/') && KNOWN_EXTS.has(extOf(p)) }

// ───────────────────── resolution ─────────────────────

function resolves(p, base = root) {
  const abs = join(base, p)
  if (p.endsWith('/')) { return isDir(abs) }
  if (existsSync(abs)) { return true }
  if (extOf(p) && KNOWN_EXTS.has(extOf(p))) { return false }
  return MODULE_EXTS.some(e => isFile(`${abs}.${e}`))
}

// Unique relocation candidate, or the candidate count when there is not exactly one.
function locate(p) {
  const clean = p.replace(/\/$/, '')
  const base = posix.basename(clean)
  const ext = extOf(clean)
  const stem = ext ? base.slice(0, -(ext.length + 1)) : base
  const hits = new Set()
  if (p.endsWith('/')) {
    for (const d of treeDirs) { if (posix.basename(d) === base) { hits.add(`${d}/`) } }
  } else {
    for (const f of byBase.get(base) ?? []) { hits.add(f) }
    const family = !ext ? MODULE_EXTS : (JS_FAMILY_EXTS.includes(ext) ? JS_FAMILY_EXTS : [])
    for (const e of family) {
      for (const f of byBase.get(`${stem}.${e}`) ?? []) { hits.add(f) }
    }
    if (!ext) {
      for (const d of treeDirs) { if (posix.basename(d) === stem) { hits.add(d) } }
    }
  }
  // A tail of a real path (`router/index.ts` for apps/web/src/router/index.ts)
  // is package-relative shorthand, not a dead reference.
  const tail = `/${clean}`
  if ([...hits].some(h => h.replace(/\/$/, '').endsWith(tail) || (!ext && h.replace(/\.[^./]+$/, '').endsWith(tail)))) {
    return { fragment: true }
  }
  // Doc files never count as a code file's new home unless the cited path was a doc path.
  if (!p.startsWith(`${aiRel}/`)) {
    for (const h of hits) { if (h.startsWith(`${aiRel}/`)) { hits.delete(h) } }
  }
  // Prefer a same-directory swap (foo.js -> foo.ts) over a tree-wide match.
  const sameDir = [...hits].filter(h => posix.dirname(h) === posix.dirname(clean))
  const pool = sameDir.length === 1 ? sameDir : [...hits]
  return pool.length === 1 ? { to: pool[0] } : { candidates: pool.length }
}

// ───────────────────── run ─────────────────────

const docs = docFiles(scanDir)
const findings = []
const checked = new Set()
for (const doc of docs) {
  const docRel = relative(root, doc)
  for (const { line, token } of extract(doc)) {
    const p = toPath(token)
    if (!p) { continue }
    checked.add(p)
    if (resolves(p) || resolves(p, dirname(doc)) || resolves(p, featuresDir)) { continue }
    const loc = locate(p)
    if (loc.fragment) { continue }
    findings.push(loc.to
      ? { status: 'MOVED', doc: docRel, line, path: p, to: loc.to }
      : { status: 'MISSING', doc: docRel, line, path: p, candidates: loc.candidates })
  }
}

const unique = new Set(findings.map(f => f.path))
if (jsonMode) {
  stdout.write(JSON.stringify({ docs: docs.length, pathsChecked: checked.size, deadPaths: unique.size, findings }, null, 2) + '\n')
} else {
  stdout.write(`dead-paths: ${docs.length} docs, ${checked.size} unique paths checked, ${unique.size} dead (${findings.length} references)\n`)
  for (const f of findings) {
    const tail = f.status === 'MOVED' ? `${f.path} -> ${f.to}` : `${f.path}${f.candidates > 1 ? `  (${f.candidates} basename matches, ambiguous)` : ''}`
    stdout.write(`${f.status.padEnd(8)} ${f.doc}:${f.line}  ${tail}\n`)
  }
  if (!findings.length) { stdout.write('No dead paths.\n') }
}
exit(findings.length ? 1 : 0)

// ───────────────────── helpers ─────────────────────

function detectAiDir() {
  try {
    const parsed = JSON.parse(readFileSync(join(root, '.myspec.json'), 'utf8'))
    if (typeof parsed.aiDir === 'string') { return parsed.aiDir }
  } catch { /* no config */ }
  return 'ai'
}
function isFile(p) { try { return statSync(p).isFile() } catch { return false } }
function isDir(p) { try { return statSync(p).isDirectory() } catch { return false } }
function fail(msg) {
  if (jsonMode) { stdout.write(JSON.stringify({ error: msg }) + '\n') } else { stderr.write(`dead-paths: ${msg}\n`) }
  exit(3)
}
