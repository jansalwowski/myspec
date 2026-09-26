#!/usr/bin/env node
// feature-status-audit: cross-check feature manifest (index.yaml) against
// actual documentation files on disk. Read-only. Zero npm dependencies.
//
// Usage:
//   node audit.mjs [--ai-dir=<path>] [--json] [--only=<feature>] [--severity=<min>]
//
// Defaults:
//   --ai-dir       reads .myspec.json { "aiDir": "..." } or falls back to "ai"
//   --severity     critical|high|medium|low (default: low — show all)

import { readFileSync, existsSync, statSync, readdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, resolve, relative } from 'node:path'
import { argv, cwd, exit, stdout } from 'node:process'

// ───────────────────────── args ─────────────────────────

const args = {}
for (const raw of argv.slice(2)) {
  if (!raw.startsWith('--')) { continue }
  const [k, v] = raw.slice(2).split('=')
  args[k] = v ?? true
}

const cwdAbs = resolve(cwd())
const aiDir = resolve(cwdAbs, args['ai-dir'] ?? detectAiDir(cwdAbs))
const featuresDir = join(aiDir, 'features')
const jsonMode = args.json === true
const onlyFilter = typeof args.only === 'string' ? args.only : null
const minSeverity = typeof args.severity === 'string' ? args.severity : 'low'

if (!existsSync(featuresDir)) {
  fail(`features directory not found: ${featuresDir}`)
}

// ───────────────────── YAML mini-parser ─────────────────
// Purpose-built for index.yaml shape:
//   top-level key (features: or subfeatures:) followed by a list of entries
//   each entry is `  - name: x` with 4-space indented fields
//   fields: scalar | quoted string | inline list `[a, b]`
// Not a general YAML parser. Throws on unexpected shapes.

function parseManifest(filePath) {
  const text = readFileSync(filePath, 'utf8')
  const lines = text.split(/\r?\n/)
  const entries = []
  let current = null
  let topKey = null

  for (let i = 0; i < lines.length; i++) {
    const rawLine = lines[i]
    const line = stripComment(rawLine)
    if (line.trim() === '') { continue }

    // top-level key (unindented "features:" or "subfeatures:")
    const topMatch = /^([a-zA-Z_][\w-]*):\s*$/.exec(line)
    if (topMatch && !line.startsWith(' ')) {
      topKey = topMatch[1]
      continue
    }

    // list entry start: "  - name: xxx" or "  - key: xxx"
    const entryStart = /^ {2}- (\w[\w-]*):\s*(.*)$/.exec(line)
    if (entryStart) {
      if (current) { entries.push(current) }
      current = {}
      current[entryStart[1]] = parseScalar(entryStart[2])
      continue
    }

    // continuation field: "    key: value"
    const field = /^ {4}([\w-]+):\s*(.*)$/.exec(line)
    if (field && current) {
      current[field[1]] = parseScalar(field[2])
      continue
    }
  }
  if (current) { entries.push(current) }

  return { topKey, entries }
}

function stripComment(line) {
  // strip `#` comments but respect `#` inside quotes
  let inStr = null
  let out = ''
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (inStr) {
      if (c === inStr) { inStr = null }
      out += c
      continue
    }
    if (c === '"' || c === "'") { inStr = c; out += c; continue }
    if (c === '#') { break }
    out += c
  }
  return out
}

function parseScalar(raw) {
  const v = raw.trim()
  if (v === '') { return '' }
  if (v === 'true') { return true }
  if (v === 'false') { return false }
  if (v === 'null' || v === '~') { return null }
  if (/^-?\d+$/.test(v)) { return Number(v) }
  if (/^".*"$|^'.*'$/.test(v)) { return v.slice(1, -1) }
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.slice(1, -1).trim()
    if (inner === '') { return [] }
    return inner.split(',').map(s => parseScalar(s.trim()))
  }
  return v
}

// ───────────────────────── core ─────────────────────────

function detectAiDir(root) {
  const cfg = join(root, '.myspec.json')
  if (existsSync(cfg)) {
    try {
      const parsed = JSON.parse(readFileSync(cfg, 'utf8'))
      if (typeof parsed.aiDir === 'string') { return parsed.aiDir }
    } catch { /* ignore */ }
  }
  return 'ai'
}

function fileExists(p) {
  try { return statSync(p).isFile() } catch { return false }
}
function dirExists(p) {
  try { return statSync(p).isDirectory() } catch { return false }
}

// doc expectations by status
// status → { required:[], expected:[], forbidden:[] }
// required: must be present; absence is Critical (if impl-level status) or High
// expected: should be present; absence is Medium
// forbidden: presence is suspicious; presence is Medium
const EXPECTATIONS = {
  planned: {
    required: [],
    expected: [],
    forbiddenIfAlone: [], // a planned feature can be fine with only an index entry
    aheadSignals: ['tech-spec.md', 'implementation-plan.md'],
  },
  draft: {
    required: ['spec.md'],
    expected: ['dependencies.md'],
    aheadSignals: ['implementation-plan.md'],
  },
  'in-progress': {
    required: ['spec.md'],
    expected: ['tech-spec.md', 'dependencies.md'],
    aheadSignals: [],
  },
  complete: {
    required: ['spec.md', 'tech-spec.md'],
    expected: [],
    aheadSignals: [],
    postSignals: [], // CHANGELOG.md / plans/ archive — informational only
  },
  deprecated: {
    required: [],
    expected: [],
    aheadSignals: [],
  },
}

// ─────────────── checkbox + frontmatter readers ───────────────
// Plan tasks are list items carrying `[ ]` todo, `[~]` in progress, `[x]` done
// (feature-plan's Task Status table). Only list-item checkboxes count: table
// cells and fenced code blocks quote the syntax without being tasks.

const CHECKBOX = /^\s*(?:[-*+]|\d+[.)])\s+\[([ xX~])\]/
const FENCE = /^\s*(```|~~~)/

function countCheckboxes(text, { section = null } = {}) {
  const counts = { checked: 0, inProgress: 0, unchecked: 0, total: 0 }
  let fence = null
  let inSection = section === null
  let sectionLevel = 0
  for (const line of text.split(/\r?\n/)) {
    const f = FENCE.exec(line)
    if (f) {
      if (fence === null) { fence = f[1] } else if (f[1] === fence) { fence = null }
      continue
    }
    if (fence !== null) { continue }
    if (section !== null) {
      const h = /^(#{1,6})\s+(.*)$/.exec(line)
      if (h) {
        if (section.test(h[2])) { inSection = true; sectionLevel = h[1].length; continue }
        if (inSection && h[1].length <= sectionLevel) { inSection = false }
      }
      if (!inSection) { continue }
    }
    const m = CHECKBOX.exec(line)
    if (!m) { continue }
    counts.total++
    if (m[1] === 'x' || m[1] === 'X') { counts.checked++ } else if (m[1] === '~') { counts.inProgress++ } else { counts.unchecked++ }
  }
  return counts
}

function readText(p) {
  try { return readFileSync(p, 'utf8') } catch { return null }
}

function frontmatterField(text, key) {
  if (text === null) { return null }
  const lines = text.split(/\r?\n/)
  if (lines[0]?.trim() !== '---') { return null }
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === '---') { break }
    const m = new RegExp(`^${key}:\\s*(.*)$`).exec(lines[i])
    if (m) { return String(parseScalar(stripComment(m[1]))) }
  }
  return null
}

function planCounts(p) {
  const text = readText(p)
  return text === null ? null : countCheckboxes(text)
}

function ratio(c) { return `${c.checked}/${c.total}` }

// Merged work whose feature-complete never ran usually left a commit naming
// the feature. Best-effort: silent outside a git repo or when git is absent.
function gitHint(name) {
  const term = name.split('/').pop()
  try {
    const log = execFileSync('git', ['log', '--oneline', '-i', '-F', `--grep=${term}`, '-n', '3'], {
      cwd: cwdAbs, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    return log === '' ? null : log.split('\n')
  } catch { return null }
}

const SEVERITY_ORDER = { critical: 4, high: 3, medium: 2, low: 1, info: 0 }

function inspect(feature, { parent = null } = {}) {
  const name = feature.name
  const status = feature.status ?? 'unknown'
  // Sub-feature names may already be prefixed (e.g. "search/core") or bare
  // (e.g. "map-surface-adapter"). Prefix with parent only when needed.
  const relDir = parent
    ? (name.includes('/') ? name : `${parent}/${name}`)
    : name
  const dir = join(featuresDir, relDir)

  const docs = {
    dir: dirExists(dir),
    spec: fileExists(join(dir, 'spec.md')),
    techSpec: fileExists(join(dir, 'tech-spec.md')),
    dependencies: fileExists(join(dir, 'dependencies.md')),
    scenarios: fileExists(join(dir, 'scenarios.md')),
    implementationPlan: fileExists(join(dir, 'implementation-plan.md')),
    plansArchive: dirExists(join(dir, 'plans')),
    changelog: fileExists(join(dir, 'CHANGELOG.md')),
    subIndex: fileExists(join(dir, 'index.yaml')),
  }
  docs.planProgress = docs.implementationPlan ? planCounts(join(dir, 'implementation-plan.md')) : null
  docs.archivedPlans = docs.plansArchive
    ? readdirSync(join(dir, 'plans')).filter(f => f.endsWith('.md')).sort()
      .map(f => ({ file: `plans/${f}`, ...planCounts(join(dir, 'plans', f)) }))
    : []
  docs.specStatus = docs.spec ? frontmatterField(readText(join(dir, 'spec.md')), 'status') : null
  docs.techSpecStatus = docs.techSpec ? frontmatterField(readText(join(dir, 'tech-spec.md')), 'status') : null

  const issues = []
  const rule = EXPECTATIONS[status]

  // Directory existence — unless status is 'planned', we expect a dir
  if (!docs.dir && status !== 'planned') {
    issues.push({
      severity: status === 'complete' || status === 'in-progress' ? 'critical' : 'high',
      message: `directory missing: features/${relDir}/`,
    })
  }

  if (!rule) {
    issues.push({ severity: 'medium', message: `unknown status: "${status}"` })
  } else {
    for (const file of rule.required ?? []) {
      const present = fileMatch(docs, file)
      if (!present) {
        const sev = (status === 'complete' || status === 'in-progress') ? 'critical' : 'high'
        issues.push({ severity: sev, message: `required doc missing for status=${status}: ${file}` })
      }
    }
    for (const file of rule.expected ?? []) {
      if (!fileMatch(docs, file)) {
        issues.push({ severity: 'medium', message: `expected doc missing for status=${status}: ${file}` })
      }
    }
    for (const file of rule.aheadSignals ?? []) {
      if (fileMatch(docs, file)) {
        issues.push({
          severity: 'medium',
          message: `${file} present but status=${status} (docs ahead of status — bump status?)`,
        })
      }
    }
  }

  // Suspicious-draft: draft with zero docs
  if (status === 'draft' && docs.dir && !docs.spec && !docs.techSpec && !docs.dependencies && !docs.scenarios) {
    issues.push({ severity: 'medium', message: 'draft with no documentation files — stale entry?' })
  }

  // subfeatures: true but no sub-index.yaml
  if (feature.subfeatures === true && !docs.subIndex) {
    issues.push({ severity: 'high', message: 'subfeatures: true but no index.yaml in feature dir' })
  }

  // Status drift: the plan's checkbox ratio and the docs' own frontmatter
  // status disagree with the manifest. Happens whenever work merges without
  // feature-complete.
  const plan = docs.planProgress
  let hint = null
  if (status === 'complete' && docs.implementationPlan) {
    if (plan && plan.total > 0 && plan.checked < plan.total) {
      issues.push({ severity: 'medium', message: `status=complete but implementation-plan.md is ${ratio(plan)} [x] (open tasks, unarchived)` })
    } else {
      issues.push({ severity: 'low', message: 'implementation-plan.md still present though status=complete (should be archived)' })
    }
  }
  if (['planned', 'draft', 'in-progress'].includes(status) && plan && plan.total > 0 && plan.checked === plan.total) {
    issues.push({ severity: 'medium', message: `implementation-plan.md is ${ratio(plan)} [x] but status=${status} (merged without feature-complete?)` })
    hint = gitHint(relDir)
  }
  if (status === 'complete') {
    for (const a of docs.archivedPlans) {
      if (a.total > 0 && a.checked === 0) {
        issues.push({ severity: 'medium', message: `archived ${a.file} is ${ratio(a)} [x] though status=complete` })
      }
    }
    for (const [file, docStatus] of [['spec.md', docs.specStatus], ['tech-spec.md', docs.techSpecStatus]]) {
      if (docStatus === 'draft') {
        issues.push({ severity: 'medium', message: `${file} frontmatter status: draft but manifest status=complete` })
      }
    }
  }

  return {
    name: relDir,
    status,
    priority: feature.priority ?? null,
    phase: feature.phase ?? null,
    subfeatures: feature.subfeatures === true,
    docs,
    issues,
    ...(hint ? { gitHint: hint } : {}),
  }
}

function fileMatch(docs, name) {
  switch (name) {
    case 'spec.md': return docs.spec
    case 'tech-spec.md': return docs.techSpec
    case 'dependencies.md': return docs.dependencies
    case 'scenarios.md': return docs.scenarios
    case 'implementation-plan.md': return docs.implementationPlan
    case 'CHANGELOG.md': return docs.changelog
    default: return false
  }
}

// ───────────────────── walk the manifest ─────────────────

const mainManifestPath = join(featuresDir, 'index.yaml')
if (!fileExists(mainManifestPath)) {
  fail(`main manifest not found: ${mainManifestPath}`)
}

const { entries: topEntries } = parseManifest(mainManifestPath)
const results = []

for (const entry of topEntries) {
  if (onlyFilter && entry.name !== onlyFilter && !entry.name?.startsWith(`${onlyFilter}/`)) { continue }
  const r = inspect(entry)
  results.push(r)

  if (entry.subfeatures === true) {
    const subPath = join(featuresDir, entry.name, 'index.yaml')
    if (fileExists(subPath)) {
      const { entries: subs } = parseManifest(subPath)
      for (const sub of subs) {
        results.push(inspect(sub, { parent: entry.name }))
      }
      checkParentAcs(r, subs, entry.name)
    }
  }
}

// Every sub-feature complete while the parent spec still has unticked
// acceptance criteria. Only judged when the spec ticks at least one AC:
// a spec that never ticks its ACs uses a different convention, not drift.
function checkParentAcs(parentResult, subs, parentName) {
  if (subs.length === 0 || !subs.every(s => s.status === 'complete')) { return }
  const text = readText(join(featuresDir, parentName, 'spec.md'))
  if (text === null) { return }
  const acs = countCheckboxes(text, { section: /acceptance criteria/i })
  const open = acs.unchecked + acs.inProgress
  parentResult.docs.specAcceptance = acs
  if (acs.checked > 0 && open > 0) {
    parentResult.issues.push({
      severity: 'medium',
      message: `all ${subs.length} sub-features complete but spec.md acceptance criteria are ${ratio(acs)} [x] (${open} unticked)`,
    })
  }
}

// Orphan check: top-level directories in features/ not registered in main manifest
const topLevelListed = new Set(results.map(r => r.name.split('/')[0]))
const orphans = []
try {
  for (const entry of readdirSync(featuresDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) { continue }
    if (!topLevelListed.has(entry.name)) { orphans.push(entry.name) }
  }
} catch { /* ignore */ }

// ───────────────────────── output ─────────────────────────

if (jsonMode) {
  stdout.write(JSON.stringify({
    aiDir: relative(cwdAbs, aiDir) || '.',
    featureCount: results.length,
    orphans,
    results,
  }, null, 2) + '\n')
  exit(results.some(r => r.issues.some(i => i.severity === 'critical')) ? 2 : 0)
}

printReport(results, orphans)

function printReport(rs, orph) {
  const threshold = SEVERITY_ORDER[minSeverity] ?? 0
  const filtered = rs.map(r => ({
    ...r,
    issues: r.issues.filter(i => SEVERITY_ORDER[i.severity] >= threshold),
  }))

  const totals = { critical: 0, high: 0, medium: 0, low: 0 }
  for (const r of filtered) {
    for (const i of r.issues) { totals[i.severity] = (totals[i.severity] ?? 0) + 1 }
  }

  const hasIssues = r => r.issues.length > 0
  const healthy = filtered.filter(r => !hasIssues(r))
  const unhealthy = filtered.filter(hasIssues)

  // Summary
  out('')
  out(`Feature Documentation Status Audit`)
  out(`=`.repeat(40))
  out(`ai dir:          ${relative(cwdAbs, aiDir) || '.'}`)
  out(`features total:  ${rs.length}`)
  out(`healthy:         ${healthy.length}`)
  out(`with issues:     ${unhealthy.length}`)
  out(`issue counts:    critical=${totals.critical} high=${totals.high} medium=${totals.medium} low=${totals.low}`)
  if (orph.length > 0) {
    out(`orphan dirs:     ${orph.length} (directories not in any index.yaml)`)
  }
  out('')

  // Issue table
  if (unhealthy.length > 0) {
    out(`Issues`)
    out(`-`.repeat(40))
    out(pad('Feature', 38) + pad('Status', 14) + 'Sev  Message')
    out(`-`.repeat(100))
    for (const r of unhealthy) {
      for (const i of r.issues) {
        out(pad(r.name, 38) + pad(r.status, 14) + pad(i.severity.toUpperCase(), 5) + i.message)
      }
      for (const h of r.gitHint ?? []) { out(' '.repeat(57) + `git log: ${h}`) }
    }
    out('')
  }

  // Orphans
  if (orph.length > 0) {
    out(`Orphan directories (present on disk, not in any manifest):`)
    for (const o of orph) { out(`  - features/${o}/`) }
    out('')
  }

  // Healthy roll-up (compact)
  if (healthy.length > 0 && minSeverity === 'low') {
    out(`Healthy features (${healthy.length}):`)
    const names = healthy.map(r => r.name).join(', ')
    out(`  ${names}`)
    out('')
  }

  const exitCode = totals.critical > 0 ? 2 : (totals.high > 0 ? 1 : 0)
  exit(exitCode)
}

function pad(s, n) {
  const str = String(s ?? '')
  if (str.length >= n) { return str.slice(0, n - 1) + ' ' }
  return str + ' '.repeat(n - str.length)
}

function out(s) { stdout.write(s + '\n') }

function fail(msg) {
  process.stderr.write(`feature-status-audit: ${msg}\n`)
  exit(3)
}
