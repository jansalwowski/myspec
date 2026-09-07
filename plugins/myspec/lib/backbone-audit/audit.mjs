#!/usr/bin/env node
// backbone-audit: cross-check the project topology file (backbone.yml and its
// aliases) against the repository it describes. Read-only. Zero npm dependencies.
//
// WHY three sweeps: a topology file rots in three different directions, and an
// audit that runs only the first one goes quiet exactly where the file is worst.
//
//   stale     backbone -> disk. Declared paths, entries, commands and package
//             names that no longer resolve.
//   missing   disk -> backbone. Workspace members, scripts, source dirs and root
//             config files that exist while nothing documents them. This is the
//             half a one-directional audit cannot see, and the one that matters
//             most: feature-tech-spec enumerates `packages:` from this file for
//             its reuse audit, so a package missing here is invisible to every
//             later feature, and the cost is duplicate implementations.
//   liveness  declared, present, and possibly dead. Emitted as SIGNALS carrying
//             their own evidence, never as verdicts. Paths the topology marks
//             never-modify or generated are exempt: those are supposed to look
//             inert.
//
// WHY it refuses rather than guesses: the failure this tool must never have is
// reporting "no issues" when it could not actually look. Two rules follow.
//
//   1. The parser accepts the shape `blueprints/backbone.md` emits, plus the
//      common hand-written variants of it. Every other YAML construct — block
//      scalars, anchors, aliases, merge keys, flow collections, tab indentation,
//      duplicate keys, multi-document files — ABORTS the run with the file and
//      line. A parser that half-reads a construct silently drops the keys around
//      it, and dropping `boundaries:` or `audit.ignore` turns exemptions off
//      without telling anyone.
//   2. Any check that cannot run says so in a NOT CHECKED block and is named in
//      the summary. "No issues" is only ever printed for the checks that ran.
//
// Nothing here edits the topology file. Rewriting this YAML mechanically would
// destroy the section banners and TODO markers that make it readable; the
// backbone-sync skill applies fixes with a text editor, using the line numbers
// this script reports.
//
// Usage:
//   node audit.mjs [--file=<path>] [--json] [--severity=<min>] [--only=<name>]
//                  [--stale-days=<n>] [--no-liveness]
//
// Exit codes: 0 clean, 1 high-severity issues, 2 critical issues, 3 cannot audit
// (no topology file, unreadable, or a construct the parser refuses to guess at).
// `--severity` filters the DISPLAY only — it never changes the exit code.

import { readFileSync, existsSync, statSync, readdirSync, writeSync } from 'node:fs'
import { join, resolve, relative, isAbsolute } from 'node:path'
import { execFileSync } from 'node:child_process'
import { argv, cwd, exit } from 'node:process'

// ───────────────────────── args ─────────────────────────

const args = {}
for (const raw of argv.slice(2)) {
  if (!raw.startsWith('--')) { continue }
  const body = raw.slice(2)
  const eq = body.indexOf('=')
  if (eq === -1) { args[body] = true } else { args[body.slice(0, eq)] = body.slice(eq + 1) }
}

const root = resolve(cwd())
const jsonMode = args.json === true
const onlyFilter = typeof args.only === 'string' ? args.only : null
const minSeverity = typeof args.severity === 'string' ? args.severity : 'low'
const SEVERITY_ORDER = { low: 0, medium: 1, high: 2, critical: 3 }

// Declared before the first fail() so the --json error path can name it.
let topologyRel = null

if (!(minSeverity in SEVERITY_ORDER)) {
  fail(`--severity=${minSeverity} is not one of: ${Object.keys(SEVERITY_ORDER).join(', ')}`)
}
if (args.only === true) { fail('--only needs a value: --only=<app-or-package-name>') }
if (args.file === true) { fail('--file needs a value: --file=<path>') }

// Directories never worth walking for source, whatever the project.
const SKIP_DIRS = new Set([
  'node_modules', '.git', 'dist', 'build', 'out', 'coverage', '.next',
  '.nuxt', '.turbo', '.venv', 'venv', '__pycache__', 'target', 'vendor',
])

// Expanding a workspace glob is a different job: `packages/dist` and
// `packages/build` are real workspace members whose names collide with build
// output. Filtering them here made undocumented members invisible.
const GLOB_SKIP_DIRS = new Set(['node_modules', '.git'])

const SOURCE_EXT = /\.(c|m)?[jt]sx?$|\.(vue|svelte|astro|py|go|rb|rs|java|kt|php|cs|swift|scala|ex|exs|c|cc|cpp|h|hpp|sql|graphql|gql|proto|scss|sass|less|templ|erl|clj|hs|ml|dart|lua|sh)$/
// A new directory is only worth reporting once it holds real code.
const MIN_SOURCE_FILES = 3

// Where a unit's source lives, when the topology file does not say.
const SOURCE_ROOTS = ['src', 'app', 'lib', 'cmd', 'internal', 'pkg']

const KNOWN_ROOT_CONFIG = [
  'eslint.config.js', 'eslint.config.mjs', 'eslint.config.ts', '.eslintrc.js', '.eslintrc.json', '.eslintrc.cjs',
  'biome.json', 'biome.jsonc',
  '.prettierrc', '.prettierrc.json', 'prettier.config.js',
  'tsconfig.json', 'tsconfig.base.json', 'jsconfig.json',
  'vite.config.ts', 'vite.config.js', 'webpack.config.js', 'rollup.config.js',
  'next.config.js', 'next.config.mjs', 'nuxt.config.ts', 'astro.config.mjs', 'svelte.config.js',
  'vitest.config.ts', 'jest.config.js', 'jest.config.ts', 'playwright.config.ts',
  'tailwind.config.js', 'tailwind.config.ts', 'postcss.config.js', 'babel.config.js',
  'docker-compose.yml', 'docker-compose.yaml', 'Dockerfile', 'Makefile', 'Taskfile.yml', 'justfile', 'Procfile',
  'turbo.json', 'nx.json', 'lerna.json', 'rush.json',
  'pyproject.toml', 'go.mod', 'Cargo.toml',
  '.nvmrc', '.tool-versions', '.editorconfig', 'renovate.json', '.env.example',
]

const SWEEP_TITLE = {
  stale: 'STALE — declared in the topology file, gone or changed on disk',
  missing: 'MISSING — present in the repo, absent from the topology file',
  liveness: 'LIVENESS SIGNALS — present and declared, but possibly dead (verify before acting)',
}

// Repeated `git grep` for the same package name is the slowest thing here.
const grepCache = new Map()

const issues = []
const units = []

// Every check that could not run, so the report can never imply it did.
const notChecked = []

function skip(check, reason, remedy) {
  notChecked.push({ check, reason, remedy: remedy ?? null })
}

function add(severity, kind, message, opts = {}) {
  issues.push({
    severity,
    kind,
    sweep: opts.sweep ?? 'stale',
    message,
    line: opts.line ?? null,
    evidence: opts.evidence ?? null,
    fix: opts.fix ?? null,
  })
}

// ───────────────────── YAML mini-parser ─────────────────
// Purpose-built for the backbone.yml shape the `backbone` blueprint emits:
// nested maps, scalar leaves, inline `[a, b]` lists, `- item` sequences (at the
// parent's indent or deeper, both of which are legal and common), and banner
// comments. Everything outside that vocabulary aborts rather than being
// half-read. It records the source line of every leaf so findings can point at
// `backbone.yml:42`, and remembers which leaves carried a trailing `# TODO`
// comment, since a TODO marker is how the blueprint says "not filled in yet".

const lineIndex = new Map()  // container -> { key: lineNumber }
const todoIndex = new Map()  // container -> { key: true }

function noteLine(container, key, line, hadTodo) {
  let rec = lineIndex.get(container)
  if (!rec) { rec = {}; lineIndex.set(container, rec) }
  rec[key] = line
  if (hadTodo) {
    let t = todoIndex.get(container)
    if (!t) { t = {}; todoIndex.set(container, t) }
    t[key] = true
  }
}

function lineFor(container, key) { return lineIndex.get(container)?.[key] ?? null }
function todoAt(container, key) { return todoIndex.get(container)?.[key] === true }

class YamlRefusal extends Error {
  constructor(line, what, why) {
    super(`${line}: ${what}${why ? ` — ${why}` : ''}`)
    this.line = line
  }
}

function parseYaml(text) {
  const lines = text.replace(/^﻿/, '').split(/\r?\n/)
  const doc = {}
  const stack = [{ indent: 0, node: doc, parentNode: null, key: null }]
  const topLevelKeys = new Set()

  for (let i = 0; i < lines.length; i++) {
    const rawLine = lines[i]
    const lineNo = i + 1

    if (/^(---|\.\.\.)\s*$/.test(rawLine)) {
      throw new YamlRefusal(lineNo, 'a document marker (--- or ...)', 'multi-document topology files are not supported')
    }

    const { text: line, hadTodo } = stripComment(rawLine)
    if (line.trim() === '') { continue }

    const lead = /^[ \t]*/.exec(line)[0]
    if (lead.includes('\t')) {
      throw new YamlRefusal(lineNo, 'tab indentation', 'YAML forbids tabs for indentation; use spaces')
    }
    const indent = lead.length
    const body = line.trim()

    refuseUnsupported(body, lineNo)

    // Settle on the container this line belongs to. A frame whose indent is
    // still null was opened by a `key:` on the previous content line and learns
    // its indent from its first child; if no child arrives it was an empty block
    // (banner comments only) and gets dropped.
    while (stack.length > 1) {
      const top = stack[stack.length - 1]
      if (top.indent === null) {
        if (indent > stack[stack.length - 2].indent) { top.indent = indent; break }
        // A sequence written at its key's own indent is legal YAML and common:
        //   used_by:
        //   - apps/web
        // Keep the frame open so the items land in the child, not the grandparent.
        if (body.startsWith('- ') || body === '-') {
          if (indent === stack[stack.length - 2].indent) { top.indent = indent; break }
        }
        stack.pop()
        continue
      }
      if (indent < top.indent) { stack.pop(); continue }
      break
    }
    const frame = stack[stack.length - 1]
    if (frame.indent === null) { frame.indent = indent }

    // sequence item
    if (body.startsWith('- ') || body === '-') {
      if (body === '-') {
        throw new YamlRefusal(lineNo, 'a sequence item with no inline value', 'nested sequences and block items are not supported')
      }
      if (!Array.isArray(frame.node)) {
        if (frame.parentNode === null) {
          throw new YamlRefusal(lineNo, 'a top-level sequence item', 'the topology file must be a map at the top level')
        }
        if (Object.keys(frame.node).length > 0) {
          throw new YamlRefusal(lineNo, 'a sequence item inside a map', 'a key cannot hold both fields and list items')
        }
        const arr = []
        frame.parentNode[frame.key] = arr
        frame.node = arr
      }
      frame.node.push(parseScalar(body.slice(1).trim(), lineNo))
      continue
    }

    if (Array.isArray(frame.node)) {
      throw new YamlRefusal(lineNo, 'a key inside a sequence', 'lists of maps are not supported in a topology file')
    }

    const field = /^([^:]+):(?:\s+(.*))?$/.exec(body)
    if (!field) {
      throw new YamlRefusal(lineNo, `an unrecognised line (${truncate(body, 40)})`, 'expected `key: value`, `key:` or `- item`')
    }
    const key = unquote(field[1].trim())
    const rest = (field[2] ?? '').trim()

    if (frame.parentNode === null) {
      if (topLevelKeys.has(key)) {
        throw new YamlRefusal(lineNo, `a duplicate top-level key (${key}:)`, 'the later block would silently replace the earlier one')
      }
      topLevelKeys.add(key)
    }

    if (rest === '') {
      const child = {}
      frame.node[key] = child
      noteLine(frame.node, key, lineNo, hadTodo)
      stack.push({ indent: null, node: child, parentNode: frame.node, key })
      continue
    }

    frame.node[key] = parseScalar(rest, lineNo)
    noteLine(frame.node, key, lineNo, hadTodo)
  }

  return doc
}

// Constructs the parser will not guess at. Each one, half-read, drops or
// rewrites the keys around it — which is how an exemption list disappears
// without anyone noticing.
function refuseUnsupported(body, lineNo) {
  const value = body.includes(':') ? body.slice(body.indexOf(':') + 1).trim() : body
  if (/^[|>][-+]?\d*\s*$/.test(value)) {
    throw new YamlRefusal(lineNo, `a block scalar (${value[0]})`, 'its body would be read as sibling keys')
  }
  if (/^&\S+/.test(value) || /^\*\S+/.test(value)) {
    throw new YamlRefusal(lineNo, 'a YAML anchor or alias', 'the marker would be read as part of the value')
  }
  if (/^<<\s*:/.test(body)) {
    throw new YamlRefusal(lineNo, 'a merge key (<<:)', 'merged keys would be missing from the audit')
  }
  if (/^\{.*\}$/.test(value) || /^\{/.test(value)) {
    throw new YamlRefusal(lineNo, 'a flow mapping ({...})', 'its fields would not be read')
  }
}

// Returns the line with any trailing comment removed, and whether that comment
// was a TODO marker. The blueprint writes `entry: src/index.ts  # TODO: verify`,
// and a value the author has not verified must not be audited as fact.
function stripComment(line) {
  let quote = null
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (quote) {
      if (c === quote) { quote = null }
      continue
    }
    if (c === '"' || c === "'") {
      // An apostrophe inside an unquoted scalar is not an opening quote.
      const before = line[i - 1]
      if (c === "'" && before !== undefined && !/[\s:[,]/.test(before)) { continue }
      quote = c
      continue
    }
    if (c === '#' && (i === 0 || /\s/.test(line[i - 1]))) {
      return { text: line.slice(0, i), hadTodo: /#\s*TODO/i.test(line.slice(i)) }
    }
  }
  return { text: line, hadTodo: false }
}

function parseScalar(raw, lineNo) {
  const v = raw.trim()
  if (v === '') { return '' }
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.slice(1, -1).trim()
    if (inner === '') { return [] }
    return splitInline(inner, lineNo).map(s => parseScalar(s, lineNo))
  }
  if (v === 'true') { return true }
  if (v === 'false') { return false }
  if (v === 'null' || v === '~') { return null }
  return unquote(v)
}

// Split an inline list on commas that are not inside quotes.
function splitInline(inner, lineNo) {
  const out = []
  let buf = ''
  let quote = null
  for (const c of inner) {
    if (quote) {
      if (c === quote) { quote = null }
      buf += c
      continue
    }
    if (c === '"' || c === "'") { quote = c; buf += c; continue }
    if (c === ',') { out.push(buf); buf = ''; continue }
    buf += c
  }
  out.push(buf)
  return out.map(s => s.trim()).filter(s => s !== '')
}

function unquote(v) {
  if ((v.startsWith('"') && v.endsWith('"') && v.length > 1) || (v.startsWith("'") && v.endsWith("'") && v.length > 1)) {
    return v.slice(1, -1)
  }
  return v
}

// ───────────────────── locate the topology file ─────────────────

const CANDIDATES = ['backbone.yml', 'backbone.yaml', 'topology.yml', 'topology.yaml', 'project.yml']
const myspec = readJson(join(root, '.myspec.json'))
const declaredInConfig = typeof myspec?.topologyFile === 'string' ? myspec.topologyFile : null

const fileArg = typeof args.file === 'string' ? args.file : null
topologyRel = fileArg ?? declaredInConfig
let unrecorded = false

if (!topologyRel) {
  topologyRel = CANDIDATES.find(c => existsSync(join(root, c))) ?? null
  unrecorded = topologyRel !== null
}

if (!topologyRel) {
  fail(`no topology file found (looked for .myspec.json topologyFile, then ${CANDIDATES.join(', ')}) — run /myspec:setup backbone to create one`)
}

const topologyPath = isAbsolute(topologyRel) ? topologyRel : resolve(root, topologyRel)
const topologyLabel = isAbsolute(topologyRel) ? (relative(root, topologyPath) || topologyRel) : topologyRel

if (!existsSync(topologyPath)) {
  // A pointer at nothing is not drift this tool can report on — there is nothing
  // to audit. setup-doctor owns that defect (check id `topology-missing`); here
  // it is simply a reason the audit cannot run.
  fail(fileArg
    ? `--file=${fileArg} does not exist`
    : `.myspec.json names topologyFile "${topologyRel}", which does not exist — create it with /myspec:setup backbone, or correct the topologyFile key`)
}

let rawText
try {
  rawText = readFileSync(topologyPath, 'utf8')
} catch (err) {
  fail(`could not read ${topologyLabel}: ${err.message}`)
}

if (rawText.trim() === '') {
  fail(`${topologyLabel} is empty — nothing to audit; run /myspec:setup backbone to regenerate it`)
}

let doc
try {
  doc = parseYaml(rawText)
} catch (err) {
  if (err instanceof YamlRefusal) {
    fail(`${topologyLabel}:${err.message}\nbackbone-audit: audit ABORTED — no findings would be reliable while this line is unread`)
  }
  fail(`could not parse ${topologyLabel}: ${err.message}`)
}

if (Object.keys(doc).length === 0) {
  fail(`${topologyLabel} has no top-level keys — nothing to audit`)
}

if (unrecorded) {
  add('low', 'topology-unrecorded', `${topologyLabel} exists but .myspec.json has no "topologyFile" key — bootstrap and feature-tech-spec find it only by guessing`, {
    fix: `add "topologyFile": "${topologyLabel}" to .myspec.json`,
  })
}

const auditCfg = isMap(doc.audit) ? doc.audit : {}
const ignorePatterns = Array.isArray(auditCfg.ignore) ? auditCfg.ignore.map(String) : []

let staleDays = 365
if (args['stale-days'] !== undefined) {
  const n = Number(args['stale-days'])
  if (!Number.isFinite(n) || n <= 0) { fail(`--stale-days=${args['stale-days']} is not a positive number`) }
  staleDays = n
} else if (auditCfg.stale_days !== undefined) {
  const n = Number(auditCfg.stale_days)
  if (Number.isFinite(n) && n > 0) { staleDays = n }
}

// ───────────────────── git availability ─────────────────

const livenessRequested = args['no-liveness'] !== true
let liveness = false

if (!livenessRequested) {
  skip('liveness sweep', 'disabled with --no-liveness')
} else if (!isGitRepo()) {
  skip('liveness sweep', 'not a git repository — staleness and inbound-reference signals need history')
} else if (git(['rev-parse', '--is-shallow-repository'])?.trim() === 'true') {
  skip('liveness sweep', 'shallow clone (git clone --depth) — history is truncated, so staleness cannot be measured',
    'run with a full clone, or `git fetch --unshallow`')
} else if (commitCount() === 0) {
  skip('liveness sweep', 'the repository has no commits yet — git grep and git log see nothing')
} else {
  liveness = true
  // git grep reads the index, not the working tree. Right after a change is
  // made, the file that proves a package is alive is invisible to it, and the
  // signal says "dead". Say so up front rather than letting the caller act on it.
  const untracked = git(['ls-files', '--others', '--exclude-standard'])
  if (untracked && untracked.trim() !== '') {
    const n = untracked.trim().split('\n').length
    skip('inbound-reference signals (partial)', `${n} untracked file(s) — git grep only reads tracked files, so a package imported only by uncommitted or gitignored code will look unreferenced`,
      'commit or stage the new files, then re-run')
  }
}

// ───────────────────── the units under audit ─────────────────

for (const [name, node] of entriesOf(doc.apps)) { units.push({ kind: 'app', name, node, container: doc.apps }) }
for (const [name, node] of entriesOf(doc.packages)) { units.push({ kind: 'package', name, node, container: doc.packages }) }
// Single-app template uses a top-level `app:` key instead of an `apps:` map.
if (isMap(doc.app) && !isMap(doc.apps)) { units.push({ kind: 'app', name: doc.app.name ?? 'app', node: doc.app, container: doc }) }

if (units.length === 0) {
  add('high', 'no-units', 'the topology file declares no apps: or packages: — nothing describes the codebase', {
    fix: 'add the project\'s apps and packages, or regenerate with /myspec:setup backbone',
  })
}

const selected = onlyFilter ? units.filter(u => u.name === onlyFilter) : units
if (onlyFilter && selected.length === 0) { fail(`--only=${onlyFilter} matched no app or package in ${topologyLabel}`) }

const declaredPaths = new Set(units.map(u => u.node?.path).filter(p => typeof p === 'string').map(normalizeRel))

// Paths the topology itself declares inert. Liveness signals are meaningless
// for these: generated code and never-touch files are supposed to look dead.
const inertPrefixes = [
  ...arrayOf(doc.boundaries?.never_modify),
  ...arrayOf(doc.boundaries?.generated_do_not_edit),
  ...Object.values(isMap(doc.boundaries?.generated_do_not_edit) ? doc.boundaries.generated_do_not_edit : {}),
].filter(v => typeof v === 'string').map(normalizeRel)

// ═════════════════ sweep 1 — stale (backbone -> disk) ═════════════════

for (const unit of selected) {
  const { kind, name, node, container } = unit
  const label = `${kind} "${name}"`
  const at = lineFor(container, name)

  if (!isMap(node)) {
    add('high', 'unit-malformed', `${label} has no fields`, { line: at, fix: 'give it at least a path:, or remove the entry' })
    continue
  }

  const declPath = typeof node.path === 'string' ? normalizeRel(node.path) : null
  if (!declPath) {
    add('high', 'path-undeclared', `${label} declares no path`, {
      line: at, fix: 'add a path: key, or remove the entry',
    })
    continue
  }

  if (!existsSync(join(root, declPath))) {
    add('critical', 'path-missing', `${label} path "${declPath}" does not exist`, {
      line: lineFor(node, 'path') ?? at,
      evidence: `ls ${shq(declPath)}`,
      fix: 'repoint the path, or drop the entry if the unit is gone',
    })
    continue
  }

  if (typeof node.entry === 'string' && !isPending(node, 'entry')) {
    if (!resolveUnder(declPath, node.entry)) {
      add('high', 'entry-missing', `${label} entry "${node.entry}" does not exist under ${declPath}`, {
        line: lineFor(node, 'entry'),
        evidence: `ls ${shq(join(declPath, node.entry))}`,
        fix: 'correct the entry path',
      })
    }
  }

  for (const [srcKey] of entriesOf(node.src)) {
    if (isPending(node.src, srcKey)) { continue }
    if (!resolveUnder(declPath, srcKey)) {
      add('medium', 'src-missing', `${label} lists source dir "${srcKey}", which does not exist`, {
        line: lineFor(node.src, srcKey),
        evidence: `ls ${shq(join(declPath, srcKey))}`,
        fix: 'remove the entry, or repoint it if the directory moved',
      })
    }
  }

  for (const [cfgKey, cfgVal] of entriesOf(node.config)) {
    if (typeof cfgVal !== 'string' || isPending(node.config, cfgKey)) { continue }
    if (!resolveUnder(declPath, cfgVal)) {
      add('medium', 'config-missing', `${label} config.${cfgKey} points at "${cfgVal}", which does not exist`, {
        line: lineFor(node.config, cfgKey),
        evidence: `ls ${shq(cfgVal)}`,
        fix: 'correct or remove the config path',
      })
    }
  }

  const manifest = readJson(join(root, declPath, 'package.json'))
  if (manifest && typeof manifest.name === 'string') {
    if (typeof node.package === 'string' && !isPending(node, 'package')) {
      if (manifest.name !== node.package) {
        add('medium', 'package-name-mismatch', `${label} claims package "${node.package}" but ${declPath}/package.json says "${manifest.name}"`, {
          line: lineFor(node, 'package'),
          fix: `set package: "${manifest.name}"`,
        })
      }
    } else if (node.package === undefined) {
      add('low', 'package-name-undeclared', `${label} has a package.json (${manifest.name}) but no package: key — a rename here would go unnoticed`, {
        line: at,
        fix: `add package: "${manifest.name}"`,
      })
    }
  }

  if (isMap(node.tests) && typeof node.tests.pattern === 'string' && !isPending(node.tests, 'pattern')) {
    if (globFiles(join(root, declPath), node.tests.pattern, 1) === 0) {
      add('low', 'tests-pattern-empty', `${label} tests.pattern "${node.tests.pattern}" matches no file under ${declPath}`, {
        line: lineFor(node.tests, 'pattern'),
        fix: 'correct the pattern, or drop it if the unit has no tests',
      })
    }
  }

  for (const consumer of arrayOf(node.used_by)) {
    if (typeof consumer !== 'string') { continue }
    const consumerPath = normalizeRel(consumer)
    if (!existsSync(join(root, consumerPath))) {
      add('medium', 'used-by-missing', `${label} lists consumer "${consumer}", which does not exist`, {
        line: lineFor(node, 'used_by'),
        evidence: `ls ${shq(consumerPath)}`,
        fix: 'remove the consumer from used_by',
      })
    }
  }
}

// commands
const rootManifest = readJson(join(root, 'package.json'))
const rootScripts = isMap(rootManifest?.scripts) ? rootManifest.scripts : {}
const packageManager = typeof doc.package_manager === 'string' ? doc.package_manager : null
const commandScripts = new Set()
const hasScripts = Object.keys(rootScripts).length > 0
const hasNodeModules = existsSync(join(root, 'node_modules'))

if (isMap(doc.commands) && !hasScripts) {
  skip('commands', 'the root package.json has no scripts block (or no package.json) — commands cannot be resolved to anything')
}

for (const [cmdName, cmdVal] of entriesOf(doc.commands)) {
  if (typeof cmdVal !== 'string' || isPending(doc.commands, cmdName)) { continue }
  const script = scriptNameOf(cmdVal)
  if (!script) {
    skip(`commands.${cmdName}`, `"${cmdVal}" is not of the form <package-manager> <script>, so nothing behind it is verified`)
    continue
  }
  commandScripts.add(script)
  if (!hasScripts) { continue }
  if (script in rootScripts) { continue }
  // pnpm/yarn/npm also run a local binary of that name; `pnpm tsc` is valid
  // with no `tsc` script. Only report when we can see that no binary exists.
  if (existsSync(join(root, 'node_modules', '.bin', script))) { continue }
  if (!hasNodeModules) {
    skip(`commands.${cmdName}`, `"${cmdVal}" names no package.json script, and node_modules is absent so a local binary cannot be ruled out`)
    continue
  }
  add('high', 'command-missing', `commands.${cmdName} runs "${cmdVal}" but there is no "${script}" script and no node_modules/.bin/${script}`, {
    line: lineFor(doc.commands, cmdName),
    evidence: `node -p "Object.keys(require('./package.json').scripts||{})"`,
    fix: 'correct the command, or drop it if the script is gone',
  })
}

// database, root_config, agent, ai_docs
for (const [key, val] of entriesOf(doc.database)) { checkLeafPath('database', doc.database, key, val, 'high') }
for (const [key, val] of entriesOf(doc.root_config)) { checkLeafPath('root_config', doc.root_config, key, val, 'medium') }
for (const [key, val] of entriesOf(doc.agent)) { checkLeafPath('agent', doc.agent, key, val, 'medium') }
checkAiDocs(doc.ai_docs, 'ai_docs')

// boundaries: a protected path that no longer exists is protection that silently
// stopped applying, and a stale entry also mutes liveness for anything under it.
for (const [listKey, sev] of [['never_modify', 'medium'], ['generated_do_not_edit', 'medium']]) {
  const list = doc.boundaries?.[listKey]
  for (const entry of arrayOf(list)) {
    if (typeof entry !== 'string' || looksLikePattern(entry)) { continue }
    const p = normalizeRel(entry)
    if (p === '' || existsSync(join(root, p))) { continue }
    // Only a path INTO the repo can go stale in a way worth reporting. Bare
    // filenames like the blueprint's default `.env` are absent on purpose, and
    // so is anything gitignored — flagging those would fire on every project.
    if (!p.includes('/')) { continue }
    if (isGitIgnored(p)) { continue }
    add(sev, 'boundary-missing', `boundaries.${listKey} protects "${entry}", which does not exist — the protection covers nothing, and the entry still mutes liveness for that path`, {
      line: lineFor(doc.boundaries, listKey),
      evidence: `ls ${shq(p)}`,
      fix: 'repoint it if the directory moved, or remove the entry',
    })
  }
}

// workspace_config
if (typeof doc.workspace_config === 'string' && doc.workspace_config !== '' && !isPending(doc, 'workspace_config')) {
  const wc = normalizeRel(doc.workspace_config)
  if (!existsSync(join(root, wc))) {
    add('high', 'workspace-config-missing', `workspace_config names "${doc.workspace_config}", which does not exist — the MISSING sweep cannot enumerate workspace members from it`, {
      line: lineFor(doc, 'workspace_config'),
      evidence: `ls ${shq(wc)}`,
      fix: 'correct the path, or remove the key if the project is not a workspace',
    })
  }
}

function checkAiDocs(node, prefix) {
  for (const [key, val] of entriesOf(node)) {
    if (isMap(val)) { checkAiDocs(val, `${prefix}.${key}`); continue }
    checkLeafPath(prefix, node, key, val, 'medium')
  }
}

function checkLeafPath(prefix, container, key, val, severity) {
  if (typeof val !== 'string' || val === '' || isPending(container, key)) { return }
  if (looksLikePattern(val)) { return }
  if (!existsSync(join(root, normalizeRel(val)))) {
    add(severity, 'declared-path-missing', `${prefix}.${key} points at "${val}", which does not exist`, {
      line: lineFor(container, key),
      evidence: `ls ${shq(normalizeRel(val))}`,
      fix: 'correct the path, or remove the key',
    })
  }
}

// ═════════════════ sweep 2 — missing (disk -> backbone) ═════════════════

const workspace = readWorkspaceGlobs()
const workspaceMembers = expandWorkspaceMembers(workspace.globs)

if (workspace.globs.length === 0) {
  skip('undocumented workspace members',
    'no workspace globs found (no pnpm-workspace.yaml and no "workspaces" in package.json) — lerna, nx, rush, go.work, cargo workspaces and non-JS services are not enumerated',
    'check for new units by hand, or add them to audit.ignore once reviewed')
} else if (workspaceMembers.length === 0) {
  skip('undocumented workspace members', `the globs in ${workspace.source} (${workspace.globs.join(', ')}) matched no directory containing a package.json`)
}

if (!onlyFilter) {
  for (const member of workspaceMembers) {
    if (declaredPaths.has(member)) { continue }
    if (isIgnored(member)) { continue }
    const manifest = readJson(join(root, member, 'package.json'))
    add('high', 'workspace-member-unlisted', `workspace member "${member}"${manifest?.name ? ` (${manifest.name})` : ''} is not in the topology file`, {
      sweep: 'missing',
      evidence: `cat ${shq(member)}/package.json`,
      fix: `add it under apps: or packages: with path: ${member}`,
    })
  }

  for (const script of Object.keys(rootScripts)) {
    if (isLifecycleScript(script, rootScripts)) { continue }
    if (commandScripts.has(script)) { continue }
    if (isIgnored(script)) { continue }
    add('low', 'command-unlisted', `package.json script "${script}" is not in commands:`, {
      sweep: 'missing',
      evidence: `${packageManager ?? 'npm run'} ${script}`,
      fix: `add ${script}: "${packageManager ? `${packageManager} ${script}` : `npm run ${script}`}" under commands:, or record the omission under audit.ignore`,
    })
  }

  for (const file of KNOWN_ROOT_CONFIG) {
    if (!existsSync(join(root, file))) { continue }
    if (isIgnored(file)) { continue }
    const listed = Object.values(isMap(doc.root_config) ? doc.root_config : {})
      .some(v => typeof v === 'string' && normalizeRel(v) === file)
    if (!listed) {
      add('low', 'root-config-unlisted', `${file} exists at the project root but is not in root_config:`, {
        sweep: 'missing',
        fix: 'add it under root_config:, or record the omission under audit.ignore',
      })
    }
  }

  if (!isMap(doc.database)) {
    const schemaHint = ['prisma/schema.prisma', 'apps/api/prisma/schema.prisma', 'db/schema.sql', 'drizzle.config.ts']
      .find(p => existsSync(join(root, p)))
    if (schemaHint) {
      add('medium', 'database-unlisted', `${schemaHint} exists but the topology file has no database: block`, {
        sweep: 'missing',
        fix: 'add a database: block with schema, migrations and client paths',
      })
    }
  }

  // An ignore entry matching nothing mutes forever, including anything created
  // at that path later.
  for (const pat of ignorePatterns) {
    const clean = normalizeRel(pat)
    if (clean.includes('*')) { continue }
    if (existsSync(join(root, clean))) { continue }
    if (clean in rootScripts) { continue }
    add('low', 'ignore-stale', `audit.ignore lists "${pat}", which matches nothing on disk and no package.json script — it will silently mute anything created there later`, {
      sweep: 'missing',
      line: lineFor(auditCfg, 'ignore'),
      fix: 'remove the entry',
    })
  }
}

for (const unit of selected) {
  const declPath = typeof unit.node?.path === 'string' ? normalizeRel(unit.node.path) : null
  if (!declPath || !existsSync(join(root, declPath))) { continue }

  const declaredSrc = new Set(Object.keys(isMap(unit.node.src) ? unit.node.src : {}).map(k => normalizeRel(k)))

  // The blueprint's `src:` keys are unit-relative (`src/services/`), but a unit
  // does not have to keep its code under `src/` — Go uses cmd/ and internal/, a
  // Next app-router package uses app/.
  for (const srcRootName of SOURCE_ROOTS) {
    const srcRoot = join(root, declPath, srcRootName)
    if (!isDir(srcRoot)) { continue }
    for (const child of listDirs(srcRoot, SKIP_DIRS)) {
      const rel = `${srcRootName}/${child}`
      if (declaredSrc.has(rel) || declaredSrc.has(child)) { continue }
      if (isIgnored(`${declPath}/${rel}`)) { continue }
      const count = countSourceFiles(join(srcRoot, child))
      if (count < MIN_SOURCE_FILES) { continue }
      add('low', 'src-unlisted', `${unit.kind} "${unit.name}": ${rel}/ holds ${count} source files but is not listed under src:`, {
        sweep: 'missing',
        evidence: `ls ${shq(`${declPath}/${rel}`)}`,
        fix: `add "${rel}/: <purpose>" under src:, or add it to audit.ignore`,
      })
    }
  }
}

// ═════════════════ sweep 3 — liveness (signals, not verdicts) ═════════════════

if (liveness) {
  const repoActive = commitsSince(staleDays, '.') > 0
  if (!repoActive) {
    skip('staleness signals', `the whole repository has no commit in the last ${staleDays} days, so "stale" would flag everything`)
  }

  for (const unit of selected) {
    const { kind, name, node } = unit
    const declPath = typeof node?.path === 'string' ? normalizeRel(node.path) : null
    if (!declPath || !existsSync(join(root, declPath))) { continue }
    if (isInert(declPath) || isIgnored(declPath)) { continue }

    const last = lastCommitDate(declPath)
    if (repoActive && last && daysSince(last) > staleDays) {
      add('medium', 'stale-signal', `${kind} "${name}" (${declPath}) has no commit since ${last} — ${Math.floor(daysSince(last))} days`, {
        sweep: 'liveness',
        evidence: `git log -1 --format=%cs -- ${shq(declPath)}`,
        fix: 'confirm it is still live before acting — a dormant unit may still be load-bearing',
      })
    }

    // `path: .` is the single-app template pointing at the repo root, which is
    // the workspace ROOT and never one of its members.
    if (declPath !== '.' && workspaceMembers.length > 0 && !workspaceMembers.includes(declPath)) {
      add('medium', 'outside-workspace', `${kind} "${name}" (${declPath}) is outside every glob in ${workspace.source} — the package manager does not build it`, {
        sweep: 'liveness',
        evidence: `cat ${shq(workspace.source)}`,
        fix: 'add it to the workspace config, or confirm another build tool owns it and record that in purpose:',
      })
    }

    if (typeof node.package === 'string' && !isPending(node, 'package')) {
      const importers = gitGrepFiles(node.package)
        .map(normalizeRel)
        .filter(f => !f.startsWith(declPath + '/') && f !== declPath)
        .filter(f => f !== normalizeRel(topologyLabel))
        .filter(f => !/(^|\/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb)$/.test(f))

      if (kind === 'package' && importers.length === 0) {
        add('medium', 'no-importers', `package "${name}" (${node.package}) has no inbound references outside its own directory`, {
          sweep: 'liveness',
          evidence: `grep -rIl --exclude-dir=node_modules --exclude-dir=.git -F ${shq(node.package)} .`,
          fix: 'verify with the working-tree grep above before removing — git grep misses untracked, gitignored and submodule code, and none of it catches path aliases or relative imports',
        })
      }

      for (const consumer of arrayOf(node.used_by)) {
        if (typeof consumer !== 'string') { continue }
        const consumerPath = normalizeRel(consumer)
        if (!existsSync(join(root, consumerPath))) { continue }
        if (importers.some(f => f.startsWith(consumerPath + '/'))) { continue }
        add('medium', 'used-by-stale', `${kind} "${name}" lists consumer "${consumer}", but nothing tracked under it references ${node.package}`, {
          sweep: 'liveness',
          line: lineFor(node, 'used_by'),
          evidence: `grep -rIl --exclude-dir=node_modules -F ${shq(node.package)} ${shq(consumerPath)}`,
          fix: 'verify with the working-tree grep before editing — an alias or relative import does not name the package',
        })
      }
    }
  }
}

report()

// ───────────────────────── reporting ─────────────────────────

function report() {
  // Severity filters the DISPLAY. Exit codes are computed from every finding,
  // so `--severity=critical` can never turn a high-severity run into a success.
  const totals = { critical: 0, high: 0, medium: 0, low: 0 }
  for (const i of issues) { totals[i.severity] = (totals[i.severity] ?? 0) + 1 }
  const threshold = SEVERITY_ORDER[minSeverity]
  const shown = issues.filter(i => SEVERITY_ORDER[i.severity] >= threshold)

  if (jsonMode) {
    writeOut(JSON.stringify({
      topologyFile: topologyLabel,
      units: selected.map(u => ({ kind: u.kind, name: u.name, path: u.node?.path ?? null })),
      liveness,
      notChecked,
      totals,
      shownCount: shown.length,
      issues: shown,
    }, null, 2) + '\n')
    exit(exitCode(totals))
  }

  const lines = []
  const out = s => lines.push(s)

  out('')
  out('Backbone Audit')
  out('='.repeat(40))
  out(`topology file:   ${topologyLabel}`)
  out(`apps/packages:   ${selected.length}${onlyFilter ? ` (--only=${onlyFilter})` : ''}`)
  out(`liveness sweep:  ${liveness ? `ran (stale after ${staleDays} days)` : 'DID NOT RUN'}`)
  out(`issue counts:    critical=${totals.critical} high=${totals.high} medium=${totals.medium} low=${totals.low}`)
  if (minSeverity !== 'low') { out(`shown:           ${shown.length} of ${issues.length} (--severity=${minSeverity}; exit code still reflects all)`) }
  out('')

  for (const sweep of ['stale', 'missing', 'liveness']) {
    const group = shown.filter(i => i.sweep === sweep)
    if (group.length === 0) { continue }
    out(`${SWEEP_TITLE[sweep]} (${group.length})`)
    out('-'.repeat(80))
    for (const i of group) {
      out(`${pad(i.severity.toUpperCase(), 9)}${i.message}`)
      if (i.line) { out(`         at ${topologyLabel}:${i.line}`) }
      if (i.evidence) { out(`         check: ${i.evidence}`) }
      if (i.fix) { out(`         fix:   ${i.fix}`) }
    }
    out('')
  }

  // Printed last and unconditionally: a check that could not run is the one
  // thing a reader must not mistake for a clean result.
  if (notChecked.length > 0) {
    out(`NOT CHECKED (${notChecked.length}) — these say nothing about the topology file either way`)
    out('-'.repeat(80))
    for (const n of notChecked) {
      out(`         ${n.check}: ${n.reason}`)
      if (n.remedy) { out(`         → ${n.remedy}`) }
    }
    out('')
  }

  if (shown.length === 0) {
    out(notChecked.length > 0
      ? `No issues from the checks that ran. ${notChecked.length} check(s) did not run — see NOT CHECKED above before calling this clean.`
      : `No issues at or above severity ${minSeverity}.`)
    out('')
  }

  writeOut(lines.join('\n') + '\n')
  exit(exitCode(totals))
}

function exitCode(totals) {
  if (totals.critical > 0) { return 2 }
  if (totals.high > 0) { return 1 }
  return 0
}

// ───────────────────────── helpers ─────────────────────────

function isMap(v) { return v !== null && typeof v === 'object' && !Array.isArray(v) }
function entriesOf(v) { return isMap(v) ? Object.entries(v) : [] }
function arrayOf(v) { return Array.isArray(v) ? v : [] }
function looksLikePattern(v) { return /[*?]/.test(v) }
function normalizeRel(p) { return String(p).replace(/^\.\//, '').replace(/\/+$/, '') }
function truncate(s, n) { return s.length > n ? s.slice(0, n) + '…' : s }

// A value is pending when the author marked it TODO — either as the value or in
// a trailing comment, which is how the blueprint ships its guesses.
function isPending(container, key) {
  if (todoAt(container, key)) { return true }
  const v = container?.[key]
  return typeof v === 'string' && /^\s*TODO/i.test(v)
}

function isDir(p) { try { return statSync(p).isDirectory() } catch { return false } }

// Unit-relative first. A root-relative form is accepted only when it points
// INSIDE the unit — the blueprint writes `config.tsconfig: {path}/tsconfig.json`
// that way. Accepting any root-relative hit made a repo-root `src/` or
// `tsconfig.json` satisfy every app's declaration and silenced the whole sweep.
function resolveUnder(base, rel) {
  const clean = normalizeRel(rel)
  if (existsSync(join(root, base, clean))) { return true }
  if (base !== '.' && !clean.startsWith(base + '/')) { return false }
  return existsSync(join(root, clean))
}

function isIgnored(p) {
  return ignorePatterns.some(pat => {
    const clean = normalizeRel(pat)
    if (clean === p) { return true }
    if (clean.includes('*')) { return globToRegExp(clean).test(p) }
    return p.startsWith(clean + '/')
  })
}

function isInert(p) {
  return inertPrefixes.some(prefix => {
    if (prefix.includes('*')) { return globToRegExp(prefix).test(p) }
    return p === prefix || p.startsWith(prefix + '/')
  })
}

function readJson(p) {
  try { return JSON.parse(readFileSync(p, 'utf8')) } catch { return null }
}

// npm lifecycle scripts run themselves; `pre<x>`/`post<x>` only count as
// lifecycle when the <x> they wrap actually exists, so `preview` stays a script.
function isLifecycleScript(name, scripts) {
  if (/^(prepare|prepublish|prepublishOnly|prepack|postpack|install|preinstall|postinstall)$/.test(name)) { return true }
  const m = /^(pre|post)(.+)$/.exec(name)
  return m !== null && m[2] in scripts
}

function scriptNameOf(cmd) {
  // "pnpm dev" / "pnpm run dev" / "npm run test" -> the script or binary name.
  // Anything with a flag, a filter or a shell operator returns null and is
  // reported as unverified rather than guessed at.
  const parts = cmd.trim().split(/\s+/)
  if (parts.length === 0) { return null }
  if (/[|&;><$`]/.test(cmd)) { return null }
  const managers = new Set([packageManager, 'pnpm', 'npm', 'yarn', 'bun'].filter(Boolean))
  if (!managers.has(parts[0])) { return null }
  const rest = parts.slice(1).filter(p => p !== 'run')
  if (rest.length !== 1) { return null }
  if (rest[0].startsWith('-')) { return null }
  return rest[0]
}

function readWorkspaceGlobs() {
  const declared = typeof doc.workspace_config === 'string' ? normalizeRel(doc.workspace_config) : null
  for (const f of [declared, 'pnpm-workspace.yaml', 'pnpm-workspace.yml'].filter(Boolean)) {
    const p = join(root, f)
    if (!existsSync(p) || !/\.ya?ml$/.test(f)) { continue }
    let parsed
    try { parsed = parseYaml(readFileSync(p, 'utf8')) } catch {
      skip('workspace globs', `${f} could not be parsed by this tool, so workspace members were not enumerated`)
      return { globs: [], source: f }
    }
    const globs = arrayOf(parsed.packages).filter(g => typeof g === 'string')
    if (globs.length > 0) { return { globs, source: f } }
  }
  const ws = rootManifest?.workspaces
  const globs = (Array.isArray(ws) ? ws : arrayOf(ws?.packages)).filter(g => typeof g === 'string')
  return { globs, source: 'package.json' }
}

function expandWorkspaceMembers(globs) {
  const includes = globs.filter(g => !g.startsWith('!'))
  const excludes = globs.filter(g => g.startsWith('!')).map(g => globToRegExp(normalizeRel(g.slice(1))))
  const found = new Set()
  for (const g of includes) {
    for (const dir of expandDirGlob(normalizeRel(g))) {
      if (!existsSync(join(root, dir, 'package.json'))) { continue }
      if (excludes.some(re => re.test(dir))) { continue }
      found.add(dir)
    }
  }
  return [...found].sort()
}

function expandDirGlob(pattern) {
  const segments = pattern.split('/')
  let current = ['']
  for (const seg of segments) {
    const next = []
    for (const base of current) {
      const abs = base === '' ? root : join(root, base)
      if (seg === '**') {
        next.push(base, ...walkDirs(abs, base))
        continue
      }
      if (seg.includes('*') || seg.includes('?') || seg.includes('{')) {
        const re = globToRegExp(seg)
        for (const child of listDirs(abs, GLOB_SKIP_DIRS)) {
          if (re.test(child)) { next.push(base === '' ? child : `${base}/${child}`) }
        }
        continue
      }
      const candidate = base === '' ? seg : `${base}/${seg}`
      if (isDir(join(root, candidate))) { next.push(candidate) }
    }
    current = [...new Set(next)]
  }
  return current.filter(Boolean)
}

function walkDirs(abs, base, depth = 0) {
  if (depth > 6) { return [] }
  const out = []
  for (const child of listDirs(abs, GLOB_SKIP_DIRS)) {
    const rel = base === '' ? child : `${base}/${child}`
    out.push(rel, ...walkDirs(join(abs, child), rel, depth + 1))
  }
  return out
}

function listDirs(abs, skipSet) {
  try {
    return readdirSync(abs, { withFileTypes: true })
      .filter(e => (e.isDirectory() || e.isSymbolicLink()) && isDir(join(abs, e.name)))
      .filter(e => !skipSet.has(e.name) && !e.name.startsWith('.'))
      .map(e => e.name)
  } catch { return [] }
}

function countSourceFiles(abs, depth = 0) {
  if (depth > 3) { return 0 }
  let n = 0
  let entries
  try { entries = readdirSync(abs, { withFileTypes: true }) } catch { return 0 }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) { continue }
      n += countSourceFiles(join(abs, e.name), depth + 1)
    } else if (SOURCE_EXT.test(e.name)) { n++ }
    if (n >= 50) { return n }
  }
  return n
}

function globFiles(absBase, pattern, limit = Infinity) {
  // A pattern with no slash matches at any depth, the way test runners mean it.
  const p = normalizeRel(pattern)
  const re = globToRegExp(p.includes('/') ? p : `**/${p}`)
  let n = 0
  const walk = (abs, rel, depth) => {
    if (depth > 8 || n >= limit) { return }
    let entries
    try { entries = readdirSync(abs, { withFileTypes: true }) } catch { return }
    for (const e of entries) {
      const childRel = rel === '' ? e.name : `${rel}/${e.name}`
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name)) { continue }
        walk(join(abs, e.name), childRel, depth + 1)
      } else if (re.test(childRel)) { n++ }
      if (n >= limit) { return }
    }
  }
  walk(absBase, '', 0)
  return n
}

// Supports *, **, ?, and {a,b} brace alternation — vitest's own default include
// pattern uses braces, and escaping them reported every such pattern as empty.
function globToRegExp(pattern) {
  let out = ''
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i]
    if (c === '*') {
      if (pattern[i + 1] === '*') {
        const slash = pattern[i + 2] === '/'
        out += slash ? '(?:.*/)?' : '.*'
        i += slash ? 2 : 1
        continue
      }
      out += '[^/]*'
      continue
    }
    if (c === '?') { out += '[^/]'; continue }
    if (c === '{') {
      const close = pattern.indexOf('}', i)
      if (close !== -1) {
        const alts = pattern.slice(i + 1, close).split(',')
        out += `(?:${alts.map(a => a.replace(/[.+^${}()|[\]\\*?]/g, '\\$&')).join('|')})`
        i = close
        continue
      }
    }
    if (c === '@' && pattern[i + 1] === '(') {
      const close = pattern.indexOf(')', i)
      if (close !== -1) {
        const alts = pattern.slice(i + 2, close).split('|')
        out += `(?:${alts.map(a => a.replace(/[.+^${}()|[\]\\*?]/g, '\\$&')).join('|')})`
        i = close
        continue
      }
    }
    out += c.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp(`^${out}$`)
}

// --- git ---------------------------------------------------------------------

function git(argsList) {
  try {
    return execFileSync('git', argsList, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 })
  } catch { return null }
}

function isGitRepo() { return git(['rev-parse', '--is-inside-work-tree'])?.trim() === 'true' }
function commitCount() { return Number(git(['rev-list', '--count', 'HEAD'])?.trim() ?? 0) || 0 }

function lastCommitDate(path) {
  const v = git(['log', '-1', '--format=%cs', '--', path])?.trim()
  return v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null
}

function commitsSince(days, path) {
  const t = git(['log', `--since=${days}.days.ago`, '--oneline', '--', path])
  return t ? t.trim().split('\n').filter(Boolean).length : 0
}

function daysSince(dateStr) {
  return (Date.now() - Date.parse(`${dateStr}T00:00:00Z`)) / 86400000
}

function isGitIgnored(path) {
  if (!isGitRepo()) { return false }
  try {
    execFileSync('git', ['check-ignore', '-q', '--', path], { cwd: root, stdio: 'ignore' })
    return true
  } catch { return false }
}

function gitGrepFiles(needle) {
  if (grepCache.has(needle)) { return grepCache.get(needle) }
  const t = git(['grep', '-l', '-I', '-F', '--', needle])
  const files = t ? t.trim().split('\n').filter(Boolean) : []
  grepCache.set(needle, files)
  return files
}

// --- output ------------------------------------------------------------------

function shq(s) {
  const str = String(s)
  return /^[A-Za-z0-9_./@:+-]+$/.test(str) ? str : `'${str.replace(/'/g, `'\\''`)}'`
}

function pad(s, n) {
  const str = String(s ?? '')
  return str.length >= n ? str.slice(0, n - 1) + ' ' : str + ' '.repeat(n - str.length)
}

// process.stdout.write is asynchronous on a pipe, and exit() does not drain it:
// anything past the 64 KB pipe buffer was silently lost, which turned --json
// into invalid JSON on large repos. Write to fd 1 synchronously instead.
function writeFd(fd, str) {
  const buf = Buffer.from(str, 'utf8')
  let off = 0
  while (off < buf.length) {
    try { off += writeSync(fd, buf, off, buf.length - off) } catch (err) {
      if (err.code === 'EAGAIN') { continue }
      if (err.code === 'EPIPE') { return }
      throw err
    }
  }
}

function writeOut(str) { writeFd(1, str) }

function fail(msg) {
  writeFd(2, `backbone-audit: ${msg}\n`)
  if (jsonMode) {
    writeOut(JSON.stringify({
      topologyFile: typeof topologyRel === 'string' ? topologyRel : null,
      error: msg,
      units: [],
      liveness: false,
      notChecked: [{ check: 'the entire audit', reason: msg, remedy: null }],
      totals: { critical: 0, high: 0, medium: 0, low: 0 },
      shownCount: 0,
      issues: [],
    }, null, 2) + '\n')
  }
  exit(3)
}
