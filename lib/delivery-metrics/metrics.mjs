#!/usr/bin/env node
// delivery-metrics: delivery and outcome metrics per feature, computed from git
// history plus the myspec feature docs. Read-only. Zero npm dependencies. No
// model calls. Any language stack: inventory paths are just paths.
//
// WHY: self-reported speed is unreliable (developers in the METR RCT believed
// they were faster while measuring slower), so these numbers come only from
// artifacts: the manifest's status history, the plans, the conformance reports
// and the commits that touched the feature's files.
//
// Dates. "Landed" means the committer date of the commit on the first-parent
// history of HEAD that made the change — for a merged branch that is the merge
// or squash commit, i.e. when the change reached the mainline. "Written" means
// the author date. All dates print in UTC.
//
// Definitions (each metric is null with a reason when its data is missing;
// nothing is estimated):
//
//   lead time      Days from the author date of the oldest commit that added the
//                  feature's spec.md (under any of its ids) to the landed date of
//                  the first manifest change that set the feature's status to
//                  `complete`. Null when the feature was first seen already
//                  complete (retroactive docs, decompose sub-features, a squash
//                  merge carrying the whole flow) or when spec.md landed in the
//                  completing commit: those numbers measure nothing, and in a
//                  real consumer repo they moved the median from 3d to 6.6d.
//                  A feature's ids: spec.md renames (--follow), manifest
//                  `renamedFrom:`, and manifest changes that swap exactly one
//                  entry for one other with the same status. Aggregate: median
//                  and P85 (nearest rank).
//   stage dwell    For each status the feature held on the first-parent history
//                  of its manifest (index.yaml, or the parent's sub-index), days
//                  from the landed date of the change that set it to the landed
//                  date of the change that replaced it. The current status has
//                  no dwell. Aggregate: median per status.
//   deferral rate  deferred / (checked + deferred) over the feature's plans
//                  (implementation-plan.md and plans/*.md, working tree). A task
//                  is a `### Task N:` / `### Task TN:` section (up to the next
//                  heading of level 1-3, fenced code ignored). It is deferred
//                  when its heading says "deferred" (any case) or a body line
//                  carries a marker (DEFERRED, or "deferred" leading the line or
//                  after "status:"); checked when not deferred and all of its
//                  list-item checkboxes are [x]; otherwise open. Each
//                  `## Spec Coverage` row whose cell reads DEFERRED (any case)
//                  is one deferred unit — the only deferral syntax feature-plan
//                  defines. Open tasks are outside the rate and reported beside
//                  it (`open`); on a complete feature they are unmarked scope
//                  cuts. Aggregate: pooled.
//   first-time pass  Whether the feature's first decisive conformance verdict
//                  was PASS (`conformant`) rather than FAIL (`divergent` or
//                  `gaps`); `not-verifiable` is neither. Read from the newest
//                  committed conformance-report.md. When it has a
//                  `## Verdict history` table (feature-implement-review appends
//                  one row per run, oldest first, and carries the rows across
//                  overwrites), the value is the first decisive row: exact,
//                  since the rows survive overwrites and squash merges. A table
//                  that cannot be read row by row is null with the reason, never
//                  repaired. A history not marked `verdict_history: complete`
//                  (`partial`: started on a report written before the section
//                  existed) is exact only for a FAIL; a PASS falls back to the
//                  committed versions.
//                  Fallback, a report without the section: committed versions
//                  only, a lower bound on failures, since the report is
//                  overwritten on every run and squash merges drop intermediate
//                  versions. false when the oldest committed decisive verdict is
//                  FAIL; true when it is PASS and the report has at least two
//                  committed versions; null when a PASS is its only committed
//                  version, since an overwritten failure cannot be ruled out.
//                  Each value names its `basis`. Aggregate: passes / features
//                  with a non-null value, with the count from each basis.
//   rework rate    fix commits / all commits (merges excluded) reachable from
//                  HEAD that touched a path in tech-spec.md's File Inventory
//                  with a committer date in the 30 days after the landed
//                  completion date. A fix commit is one whose subject matches
//                  the fix pattern (data: FIX_PATTERNS, or --fix-pattern). The
//                  default covers Conventional Commits `fix:` and common
//                  free-form prefixes; a repo with other conventions must pass
//                  its own. Null until the window has closed. Aggregate: pooled.
//   spec churn     Commits to spec.md (renames followed) that raised its
//                  `spec_version` and were committed after the landed
//                  completion date.
//
// Usage:
//   node metrics.mjs [--ai-dir=<path>] [--feature=<id>] [--since=<YYYY-MM-DD>]
//                    [--fix-pattern=<regex>] [--json]
//
//   --feature   one feature id (as in the manifest, `parent/child` for a
//               sub-feature); a parent id also selects its sub-features
//   --since     only features whose landed completion (or, when not complete,
//               whose spec.md was first written) is on or after this UTC date;
//               features with no dated history are left out
//
// Exit codes: 0 report written, 3 cannot run (not a git repository, shallow
// clone, no manifest, bad arguments). An empty repository is not an error:
// every history-based metric is null with the reason.

import { readFileSync, statSync, readdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, resolve, relative, sep } from 'node:path'
import { argv, cwd, exit, stdout, stderr } from 'node:process'
import { aiDirFor } from '../memory-files.mjs'

// Subject-line patterns that mark a commit as a fix (rework). Data, not code:
// extend it for a project's own convention, or replace it with --fix-pattern.
const FIX_PATTERNS = [
  '^(fix|bugfix|hotfix)(\\([^)]*\\))?!?:',          // Conventional Commits
  '^(fix|fixes|fixed|fixing|bugfix|hotfix)\\b',      // free-form "Fix the ..."
  '^revert\\b',                                       // "Revert ..." / git revert
  '^\\[?(bug|fix|hotfix)\\]',                         // "[fix] ..." / "[bug] ..."
]
const DONE_STATUSES = new Set(['complete'])
const WINDOW_DAYS = 30
const DAY = 86400
const PASS_VERDICTS = new Set(['conformant'])
const FAIL_VERDICTS = new Set(['divergent', 'gaps'])
// The verdict tokens feature-implement-review writes, in the frontmatter and in
// the `## Verdict history` Verdict column.
const VERDICTS = new Set([...PASS_VERDICTS, ...FAIL_VERDICTS, 'not-verifiable'])
const HISTORY = 'verdict-history'
const VERSIONS = 'committed-versions'

const DEFINITIONS = {
  leadTime: 'days from the author date of the oldest commit adding the feature\'s spec.md (under any former id: spec.md renames, manifest renamedFrom, or a one-for-one manifest swap) to the landed date of the first manifest change setting status complete; null when first seen already complete or when spec.md landed in the completing commit; aggregate median and P85 (nearest rank)',
  stageDwell: 'days each status was held on the first-parent history of the feature\'s manifest, from the landed change that set it to the landed change that replaced it; the current status has no dwell; aggregate median per status',
  deferralRate: 'deferred / (checked + deferred) over implementation-plan.md and plans/*.md: a `### Task N:`/`### Task TN:` section is deferred when its heading says deferred (any case) or a body line carries a deferral marker, checked when all its list-item checkboxes are [x], otherwise open (outside the rate, reported as `open`); each DEFERRED `## Spec Coverage` row is one deferred unit; aggregate pooled',
  firstTimePass: 'first decisive conformance verdict (conformant = pass; divergent/gaps = fail; not-verifiable skipped), from the newest committed conformance-report.md. basis verdict-history: the first decisive row of its `## Verdict history` table, exact (rows survive overwrites and squash merges); an unreadable table is null; a history not marked `verdict_history: complete` is exact only for a fail, a pass falls back to committed-versions. basis committed-versions (no history section): a lower bound on failures, false when the oldest committed decisive verdict fails, true when it passes and the report has 2+ committed versions, null when a pass is its only committed version; aggregate passes / non-null features',
  reworkRate: `fix commits / all non-merge commits reachable from HEAD touching a tech-spec.md File Inventory path with a committer date within ${WINDOW_DAYS} days after the landed completion; fix = subject matches the fix pattern; null until the window closes; aggregate pooled`,
  specChurn: 'commits raising spec.md spec_version (renames followed) committed after the landed completion',
  landed: 'committer date of the first-parent commit of HEAD that made the change (the merge or squash commit for merged branches); all dates UTC',
}

// ───────────────────────── args ─────────────────────────

const args = {}
for (const raw of argv.slice(2)) {
  if (!raw.startsWith('--')) { fail(`unexpected argument: ${raw}`) }
  const body = raw.slice(2)
  const eq = body.indexOf('=')
  if (eq === -1) { args[body] = true } else { args[body.slice(0, eq)] = body.slice(eq + 1) }
}
for (const k of ['ai-dir', 'feature', 'since', 'fix-pattern']) {
  if (args[k] === true || args[k] === '') { fail(`--${k} needs a value: --${k}=<value>`) }
}
const jsonMode = args.json === true
const onlyFeature = args.feature ? args.feature.replace(/\/+$/, '') : null
let sinceTs = null
if (args.since) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(args.since)) { fail(`--since must be YYYY-MM-DD (got ${args.since})`) }
  sinceTs = Date.parse(`${args.since}T00:00:00Z`) / 1000
  if (Number.isNaN(sinceTs)) { fail(`--since is not a date: ${args.since}`) }
}
let fixRegexes
let fixPatternSource
try {
  if (args['fix-pattern']) {
    fixRegexes = [new RegExp(args['fix-pattern'], 'i')]
    fixPatternSource = '--fix-pattern'
  } else {
    fixRegexes = FIX_PATTERNS.map(p => new RegExp(p, 'i'))
    fixPatternSource = 'default (Conventional Commits fix: plus common free-form prefixes; pass --fix-pattern for other conventions)'
  }
} catch (e) {
  fail(`--fix-pattern is not a valid regular expression: ${e.message}`)
}
const isFix = subject => fixRegexes.some(r => r.test(subject))

// ───────────────────────── git ─────────────────────────

const cwdAbs = resolve(cwd())
// Every path handed to git is repo-root relative, so git runs from the root
// once it is known (a run from a subdirectory would otherwise misresolve them).
let gitDir = cwdAbs

function gitRaw(gitArgs, { input, dir = gitDir } = {}) {
  // core.quotePath=false: --name-status would otherwise C-quote non-ASCII
  // paths ("caf\303\251/spec.md") and they would match nothing.
  // --literal-pathspecs: inventory paths are paths, not globs — `web/[id].php`
  // must not also match `web/i.php`.
  return execFileSync('git', ['-c', 'core.quotePath=false', '--literal-pathspecs', '-C', dir, ...gitArgs], {
    input, maxBuffer: 1024 * 1024 * 1024, stdio: ['pipe', 'pipe', 'ignore'],
  })
}
function git(gitArgs, opts) {
  try { return gitRaw(gitArgs, opts).toString('utf8') } catch { return null }
}

const top = git(['rev-parse', '--show-toplevel'])?.trim()
if (!top) { fail('not a git repository — delivery metrics are computed from history') }
if (git(['rev-parse', '--is-shallow-repository'])?.trim() === 'true') {
  fail('shallow clone (git clone --depth) — history is truncated, so lead times, dwell and rework cannot be measured. Run `git fetch --unshallow` or use a full clone')
}
const hasCommits = git(['rev-parse', '--verify', '-q', 'HEAD']) !== null
const NO_COMMITS = 'the repository has no commits yet'

const aiDir = resolve(cwdAbs, args['ai-dir'] ?? aiDirFor(cwdAbs))
const featuresDir = join(aiDir, 'features')
const mainManifest = join(featuresDir, 'index.yaml')
if (!isFile(mainManifest)) { fail(`feature manifest not found: ${relative(cwdAbs, mainManifest) || mainManifest}`) }
const topReal = resolve(top)
gitDir = topReal
const featuresRel = relative(topReal, featuresDir).split(sep).join('/')
if (featuresRel.startsWith('..')) { fail(`features directory ${featuresDir} is outside the repository ${topReal}`) }

// `git log` records: RS before each commit, fields split by US, then any
// --name-status lines.
function logRecords(gitArgs) {
  const out = hasCommits ? git(['log', '--format=%x1e%H%x1f%at%x1f%ct%x1f%s', ...gitArgs]) : null
  if (!out) { return [] }
  return out.split('\x1e').slice(1).map(chunk => {
    const [head, ...rest] = chunk.split('\n')
    const [sha, at, ct, subject] = head.split('\x1f')
    const files = rest.filter(l => l.trim() !== '').map(l => l.split('\t'))
    return { sha, at: Number(at), ct: Number(ct), subject: subject ?? '', files }
  })
}

// Batch-read blobs: one `git cat-file --batch` for any number of `rev:path`.
function readBlobs(specs) {
  const result = new Map()
  if (specs.length === 0) { return result }
  let buf
  try { buf = gitRaw(['cat-file', '--batch'], { input: specs.join('\n') + '\n' }) } catch { return result }
  let pos = 0
  for (const spec of specs) {
    const nl = buf.indexOf(0x0a, pos)
    if (nl === -1) { break }
    const header = buf.toString('utf8', pos, nl)
    pos = nl + 1
    const m = /^\S+ \S+ (\d+)$/.exec(header)
    if (!m) { result.set(spec, null); continue }  // "<spec> missing"
    const size = Number(m[1])
    result.set(spec, buf.toString('utf8', pos, pos + size))
    pos += size + 1
  }
  return result
}

// ───────────────────── manifest parsing ─────────────────
// Same manifest shape feature-status-audit reads: a top-level key followed by
// `- name: x` entries with indented scalar fields. Not a general YAML parser.

function parseManifest(text) {
  const entries = []
  let current = null
  let entryIndent = -1
  for (const rawLine of text.split(/\r?\n/)) {
    const line = stripComment(rawLine)
    if (line.trim() === '') { continue }
    const start = /^(\s*)- ([\w][\w-]*):\s*(.*)$/.exec(line)
    if (start) {
      if (current) { entries.push(current) }
      current = { [start[2]]: parseScalar(start[3]) }
      entryIndent = start[1].length
      continue
    }
    const field = /^(\s+)([\w-]+):\s*(.*)$/.exec(line)
    if (field && current && field[1].length > entryIndent) {
      current[field[2]] = parseScalar(field[3])
      continue
    }
    if (!/^\s/.test(line)) { if (current) { entries.push(current) } current = null }
  }
  if (current) { entries.push(current) }
  return entries.filter(e => typeof e.name === 'string' && e.name !== '')
}

function stripComment(line) {
  let inStr = null
  let out = ''
  for (const c of line) {
    if (inStr) { if (c === inStr) { inStr = null } out += c; continue }
    if (c === '"' || c === "'") { inStr = c; out += c; continue }
    if (c === '#') { break }
    out += c
  }
  return out
}

function parseScalar(raw) {
  const v = raw.trim()
  if (v === 'true') { return true }
  if (v === 'false') { return false }
  if (/^-?\d+$/.test(v)) { return Number(v) }
  if (/^".*"$|^'.*'$/.test(v)) { return v.slice(1, -1) }
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.slice(1, -1).trim()
    return inner === '' ? [] : inner.split(',').map(s => parseScalar(s))
  }
  return v
}

// `renamedFrom: old` or `renamedFrom: [a, b]` on a manifest entry.
function renamedFromOf(entry) {
  const v = entry.renamedFrom ?? entry['renamed-from']
  if (typeof v === 'string' && v !== '') { return [v] }
  return Array.isArray(v) ? v.filter(x => typeof x === 'string' && x !== '') : []
}

function frontmatterField(text, key) {
  if (!text) { return null }
  const lines = text.split(/\r?\n/)
  if (lines[0]?.trim() !== '---') { return null }
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === '---') { break }
    const m = new RegExp(`^${key}:\\s*(.*)$`).exec(lines[i])
    if (m) { return parseScalar(stripComment(m[1])) }
  }
  return null
}

// ───────────────────── feature list ─────────────────────

const features = []
for (const entry of parseManifest(readFileSync(mainManifest, 'utf8'))) {
  features.push({ id: entry.name, status: String(entry.status ?? 'unknown'), manifest: `${featuresRel}/index.yaml`, parent: null, renamedFrom: renamedFromOf(entry) })
  if (entry.subfeatures === true) {
    const sub = join(featuresDir, entry.name, 'index.yaml')
    if (!isFile(sub)) { continue }
    for (const s of parseManifest(readFileSync(sub, 'utf8'))) {
      const id = s.name.includes('/') ? s.name : `${entry.name}/${s.name}`
      features.push({ id, status: String(s.status ?? 'unknown'), manifest: `${featuresRel}/${entry.name}/index.yaml`, parent: entry.name, renamedFrom: renamedFromOf(s).map(o => idOf(entry.name, o)) })
    }
  }
}
const selected = onlyFeature
  ? features.filter(f => f.id === onlyFeature || f.id.startsWith(`${onlyFeature}/`))
  : features
if (onlyFeature && selected.length === 0) { fail(`feature not in the manifest: ${onlyFeature}`) }

// ───────────────────── manifest history ─────────────────

// Manifest renames. A renamed entry would otherwise look like a new feature
// first seen at the rename — its lead time ending at the rename, its early
// stages lost. Two sources, both mapped to feature ids:
//   explicit  an entry's `renamedFrom:` (any committed version, or the working tree)
//   detected  a first-parent manifest change that removes exactly one entry and
//             adds exactly one, with the same status on both sides
// Anything looser (two entries added in the rename commit) needs renamedFrom.
const renameLinks = new Map()  // new id -> Set(old ids)
function link(newId, oldId) {
  if (newId === oldId) { return }
  if (!renameLinks.has(newId)) { renameLinks.set(newId, new Set()) }
  renameLinks.get(newId).add(oldId)
}
function idOf(parent, name) { return parent && !name.includes('/') ? `${parent}/${name}` : name }

const manifestCache = new Map()
function manifestHistory(manifestRel, parent) {
  if (manifestCache.has(manifestRel)) { return manifestCache.get(manifestRel) }
  const commits = logRecords(['--first-parent', '--', manifestRel]).reverse()
  const blobs = readBlobs(commits.map(c => `${c.sha}:${manifestRel}`))
  const versions = commits.map(c => {
    const text = blobs.get(`${c.sha}:${manifestRel}`)
    const statuses = new Map()
    if (text) {
      for (const e of parseManifest(text)) {
        statuses.set(e.name, String(e.status ?? 'unknown'))
        for (const old of renamedFromOf(e)) { link(idOf(parent, e.name), idOf(parent, old)) }
      }
    }
    return { sha: c.sha, ct: c.ct, statuses }
  })
  for (let i = 1; i < versions.length; i++) {
    const prev = versions[i - 1].statuses
    const cur = versions[i].statuses
    const removed = [...prev.keys()].filter(n => !cur.has(n))
    const added = [...cur.keys()].filter(n => !prev.has(n))
    if (removed.length === 1 && added.length === 1 && prev.get(removed[0]) === cur.get(added[0])) {
      link(idOf(parent, added[0]), idOf(parent, removed[0]))
    }
  }
  manifestCache.set(manifestRel, versions)
  return versions
}

// Every id the feature has had: itself, spec.md renames, manifest renames,
// transitively.
function expandAliases(aliases) {
  const queue = [...aliases]
  while (queue.length > 0) {
    for (const old of renameLinks.get(queue.pop()) ?? []) {
      if (!aliases.has(old)) { aliases.add(old); queue.push(old) }
    }
  }
  return aliases
}

function statusTimeline(feature, aliases) {
  const transitions = []
  let last = null
  for (const v of manifestHistory(feature.manifest, feature.parent)) {
    let status = null
    for (const [name, st] of v.statuses) {
      if (aliases.has(idOf(feature.parent, name))) { status = st; break }
    }
    if (status === null || status === last) { continue }  // absent: no observation
    transitions.push({ status, at: v.ct, sha: v.sha })
    last = status
  }
  return transitions
}

// ───────────────────── plan parsing ─────────────────────

const FENCE = /^\s*(`{3,}|~{3,})/
const BOX = /^\s*(?:[-*+]|\d+[.)])\s+\[([ xX~])\]/
// `### Task 3:`, `### Task T3:`, `### T3:`
const TASK_HEADING = /^###\s+(?:Task\s+T?|T)\d+(?:[^0-9A-Za-z]|$)/
// feature-plan and feature-complete name no task-level deferral syntax (only
// the Spec Coverage `DEFERRED` cell), so any spelling of "deferred" in a task
// heading counts. In the body only a marker counts — DEFERRED in capitals
// anywhere, or "deferred" leading a line or following "status:" — because a
// step like "add deferred job loading" is work, not a deferral.
const DEFERRED_HEADING = /\bdeferred\b/i
const DEFERRED_CAPS = /\bDEFERRED\b/
const DEFERRED_LEAD = /^\s*(?:[-*+]\s+)?(?:\[[ xX~]\]\s+)?[*_]*(?:status:?[*_]*\s*)?deferred\b/i
const DEFERRED_CELL = /^\s*[*_]*deferred\b/i

function planTally(text) {
  const tally = { tasks: 0, checked: 0, deferredTasks: 0, open: 0, deferredCoverageRows: 0 }
  let fence = null
  let task = null
  let inCoverage = false
  const closeTask = () => {
    if (!task) { return }
    tally.tasks++
    if (task.deferred) { tally.deferredTasks++ } else if (task.boxes > 0 && task.done === task.boxes) { tally.checked++ } else { tally.open++ }
    task = null
  }
  for (const line of text.split(/\r?\n/)) {
    const f = FENCE.exec(line)
    if (f) {
      if (fence === null) { fence = f[1][0] } else if (f[1][0] === fence) { fence = null }
      continue
    }
    if (fence !== null) { continue }
    const h = /^(#{1,6})\s+(.*)$/.exec(line)
    if (h && h[1].length <= 3) {
      closeTask()
      inCoverage = h[1].length <= 2 && /^spec coverage\b/i.test(h[2].trim())
      if (TASK_HEADING.test(line)) { task = { boxes: 0, done: 0, deferred: DEFERRED_HEADING.test(line) } }
      continue
    }
    if (task) {
      if (DEFERRED_CAPS.test(line) || DEFERRED_LEAD.test(line)) { task.deferred = true }
      const b = BOX.exec(line)
      if (b) { task.boxes++; if (b[1] === 'x' || b[1] === 'X') { task.done++ } }
    }
    if (inCoverage && /^\s*\|/.test(line) && line.split('|').some(cell => DEFERRED_CELL.test(cell))) {
      tally.deferredCoverageRows++
    }
  }
  closeTask()
  return tally
}

function deferralRate(dir) {
  const files = []
  if (isFile(join(dir, 'implementation-plan.md'))) { files.push('implementation-plan.md') }
  if (isDir(join(dir, 'plans'))) {
    for (const f of readdirSync(join(dir, 'plans')).filter(n => n.endsWith('.md')).sort()) { files.push(`plans/${f}`) }
  }
  if (files.length === 0) { return nullMetric('no implementation-plan.md or plans/*.md') }
  const sum = { checked: 0, deferredTasks: 0, open: 0, deferredCoverageRows: 0, tasks: 0 }
  for (const f of files) {
    const t = planTally(readFileSync(join(dir, f), 'utf8'))
    for (const k of Object.keys(sum)) { sum[k] += t[k] }
  }
  const deferred = sum.deferredTasks + sum.deferredCoverageRows
  // open: tasks neither all-[x] nor deferred. Outside the rate by definition,
  // reported beside it — on a complete feature they are unmarked scope cuts.
  const detail = { checked: sum.checked, deferred, open: sum.open, deferredTasks: sum.deferredTasks, deferredCoverageRows: sum.deferredCoverageRows, tasks: sum.tasks, plans: files }
  if (sum.checked + deferred === 0) { return nullMetric('no checked or deferred tasks in the plans yet', detail) }
  return { value: round(deferred / (sum.checked + deferred), 4), reason: null, ...detail }
}

// ───────────────────── inventory parsing ────────────────

function inventoryPaths(text) {
  const paths = new Set()
  let fence = null
  let inSection = false
  let level = 0
  for (const line of text.split(/\r?\n/)) {
    const f = FENCE.exec(line)
    if (f) { if (fence === null) { fence = f[1][0] } else if (f[1][0] === fence) { fence = null } continue }
    if (fence !== null) { continue }
    const h = /^(#{1,6})\s+(.*)$/.exec(line)
    if (h) {
      if (/file inventory/i.test(h[2])) { inSection = true; level = h[1].length; continue }
      if (inSection && h[1].length <= level) { inSection = false }
      continue
    }
    if (!inSection || !/^\s*\|/.test(line)) { continue }
    const cell = line.split('|')[1]?.trim() ?? ''
    if (cell === '' || /^:?-{2,}:?$/.test(cell) || /^file$/i.test(cell)) { continue }
    const ticked = /`([^`]+)`/.exec(cell)
    let p = (ticked ? ticked[1] : cell).trim().replace(/^\.\//, '')
    // Placeholders and absolute or home paths are not repo paths.
    if (p === '' || /\s/.test(p) || /[{}<>$]/.test(p) || /^[/~]/.test(p)) { continue }
    p = p.replace(/\/+$/, '')
    paths.add(p)
  }
  return [...paths].sort()
}

// ───────────────────── per-feature metrics ──────────────

function nullMetric(reason, detail = {}) { return { value: null, reason, ...detail } }

// --follow also reports copies (`C069 other/spec.md this/spec.md`), and every
// spec.md starts from the same template, so a new feature would inherit an
// unrelated feature's history. A copy is where this file was born: keep the
// copy commit, drop everything older.
function followLog(pathRel) {
  const log = logRecords(['--follow', '--name-status', '--', pathRel])
  const born = log.findIndex(r => r.files.some(row => row[0].startsWith('C')))
  if (born === -1) { return log }
  const copy = log[born]
  copy.files = copy.files.map(row => row[0].startsWith('C') ? ['A', row[row.length - 1]] : row)
  return log.slice(0, born + 1)
}

// The path a --follow record touched in its commit (the new side of a rename).
function recordPath(rec) {
  const row = rec.files[rec.files.length - 1]
  return row ? row[row.length - 1] : null
}

// First-time pass from the committed versions of conformance-report.md, oldest
// first. The newest one's `## Verdict history`, when it has one, holds every
// run, including those overwritten before a commit or dropped by a squash.
function firstTimePass(texts) {
  const newest = texts[texts.length - 1]
  const history = verdictHistory(newest)
  if (history === null) { return fromCommittedVersions(texts) }
  if (history.error) {
    return nullMetric(`the committed verdict history is unreadable: ${history.error}`, { basis: HISTORY, committedVersions: texts.length })
  }
  const verdicts = history.rows
  const partial = String(frontmatterField(newest, 'verdict_history') ?? '').toLowerCase() !== 'complete'
  const detail = { basis: HISTORY, verdicts, partial, committedVersions: texts.length }
  const first = verdicts.find(v => PASS_VERDICTS.has(v) || FAIL_VERDICTS.has(v))
  if (first === undefined) { return nullMetric('no conformant/divergent/gaps row in the verdict history yet', detail) }
  if (FAIL_VERDICTS.has(first)) { return { value: false, reason: null, ...detail } }
  if (!partial) { return { value: true, reason: null, ...detail } }
  // A partial history was started on a report that already existed, so runs
  // before its first row may have been overwritten: its PASS proves no more
  // than the committed versions do.
  return { ...fromCommittedVersions(texts), historyVerdicts: verdicts }
}

// Fallback without a verdict history: the committed versions' frontmatter
// verdicts. A lower bound on failures, since the report is overwritten on
// every run and a squash merge keeps only its last version.
function fromCommittedVersions(texts) {
  const verdicts = texts.map(t => String(frontmatterField(t, 'verdict') ?? '').toLowerCase()).filter(v => v !== '')
  const decisive = verdicts.filter(v => PASS_VERDICTS.has(v) || FAIL_VERDICTS.has(v))
  const detail = { basis: VERSIONS, verdicts, committedVersions: texts.length }
  if (decisive.length === 0) { return nullMetric('no committed conformant/divergent/gaps verdict yet', detail) }
  if (FAIL_VERDICTS.has(decisive[0])) { return { value: false, reason: null, ...detail } }
  if (texts.length === 1) { return nullMetric('only one committed version (conformant) and no complete verdict history — earlier overwritten failures cannot be ruled out', detail) }
  return { value: true, reason: null, ...detail }
}

// The `## Verdict history` section feature-implement-review keeps in
// conformance-report.md: one markdown table whose header names a Verdict
// column, one row per run, oldest first. Returns null when there is no such
// section, the verdicts when every row reads, { error } otherwise. Nothing is
// repaired: skipping an unreadable row could skip the first run.
function verdictHistory(text) {
  if (typeof text !== 'string') { return null }
  const lines = text.split(/\r?\n/)
  let i = 0
  if (lines[0]?.trim() === '---') {
    const end = lines.findIndex((l, k) => k > 0 && l.trim() === '---')
    i = end === -1 ? lines.length : end + 1
  }
  const sections = []
  let current = null
  let fence = null
  for (; i < lines.length; i++) {
    const line = lines[i]
    const f = /^\s*(`{3,}|~{3,})/.exec(line)
    if (f) {
      if (fence === null) { fence = f[1] } else if (f[1][0] === fence[0] && f[1].length >= fence.length) { fence = null }
    } else if (fence === null && /^#{1,6}\s/.test(line)) {
      // a deeper heading inside the section ends it too: the table comes first
      current = /^##\s+verdict history\s*#*\s*$/i.test(line) ? [] : null
      if (current) { sections.push(current) }
      continue
    }
    if (current) { current.push(line) }
  }
  if (sections.length === 0) { return null }
  if (sections.length > 1) { return { error: `${sections.length} "## Verdict history" sections` } }
  const tables = []
  let block = null
  for (const line of sections[0]) {
    if (!line.trim().startsWith('|')) { block = null; continue }
    if (block === null) { block = []; tables.push(block) }
    block.push(line)
  }
  if (tables.length !== 1) { return { error: tables.length === 0 ? 'the section has no table' : `the section has ${tables.length} tables` } }
  const [headerLine, sepLine, ...rowLines] = tables[0]
  const header = tableCells(headerLine).map(c => c.toLowerCase())
  const sep = sepLine === undefined ? [] : tableCells(sepLine)
  if (sep.length !== header.length || !sep.every(c => /^:?-+:?$/.test(c))) { return { error: 'the table header has no matching separator row' } }
  const col = header.indexOf('verdict')
  if (col === -1) { return { error: `the table has no Verdict column (columns: ${header.join(', ')})` } }
  if (rowLines.length === 0) { return { error: 'the table has no rows' } }
  const rows = []
  for (const [n, line] of rowLines.entries()) {
    const cells = tableCells(line)
    if (cells.length !== header.length) { return { error: `row ${n + 1} has ${cells.length} cells, the header ${header.length}` } }
    const verdict = cells[col].replace(/^`([^`]*)`$/, '$1').trim().toLowerCase()
    if (!VERDICTS.has(verdict)) { return { error: `row ${n + 1} verdict "${cells[col]}" is not one of ${[...VERDICTS].join(', ')}` } }
    rows.push(verdict)
  }
  return { rows }
}

// The cells of one markdown table row; `\|` is a literal pipe.
function tableCells(line) {
  let body = line.trim()
  if (body.startsWith('|')) { body = body.slice(1) }
  if (body.endsWith('|') && !body.endsWith('\\|')) { body = body.slice(0, -1) }
  return body.split(/(?<!\\)\|/).map(c => c.trim())
}

const nowTs = Math.floor(Date.now() / 1000)

function compute(feature) {
  const dir = join(featuresDir, feature.id)
  const specRel = `${featuresRel}/${feature.id}/spec.md`
  const out = { id: feature.id, status: feature.status }

  // spec history (renames followed) gives the feature's former ids too
  const specLog = hasCommits ? followLog(specRel) : []
  const aliases = new Set([feature.id])
  const prefix = `${featuresRel}/`
  const specIdsIn = log => {
    for (const rec of log) {
      for (const row of rec.files) {
        for (const p of row.slice(1)) {
          if (p.startsWith(prefix) && p.endsWith('/spec.md')) { aliases.add(p.slice(prefix.length, -'/spec.md'.length)) }
        }
      }
    }
  }
  specIdsIn(specLog)
  // Manifest renames join the alias set; a former id whose spec.md history
  // --follow did not reach (rewritten while moved) is read on its own.
  if (hasCommits) {
    manifestHistory(feature.manifest, feature.parent)
    for (const old of feature.renamedFrom) { link(feature.id, old) }
    expandAliases(aliases)
  }
  const seen = new Set(specLog.map(r => r.sha))
  const specRecords = [...specLog]
  for (const a of [...aliases].sort()) {
    if (a === feature.id) { continue }
    for (const r of followLog(`${featuresRel}/${a}/spec.md`)) {
      if (!seen.has(r.sha)) { seen.add(r.sha); specRecords.push(r) }
    }
  }
  out.formerIds = [...aliases].filter(a => a !== feature.id).sort()
  const firstSpec = specRecords.reduce((m, r) => (m === null || r.at < m.at ? r : m), null)
  const specStart = firstSpec ? firstSpec.at : null
  out.specFirstWritten = iso(specStart)

  const transitions = hasCommits ? statusTimeline(feature, aliases) : []
  const done = transitions.find(t => DONE_STATUSES.has(t.status))
  const completedAt = done ? done.at : null
  out.completed = iso(completedAt)
  // A feature whose first manifest status is already complete never shows its
  // delivery: retroactive docs, a decompose sub-feature, a squash merge that
  // carried the whole flow. Its completion date is only "first seen".
  out.firstSeenComplete = done !== undefined && done === transitions[0]
  out.sortKey = completedAt ?? specStart

  // lead time
  if (!hasCommits) { out.leadTime = nullMetric(NO_COMMITS) }
  else if (specStart === null) { out.leadTime = nullMetric('spec.md was never committed') }
  else if (completedAt === null) { out.leadTime = nullMetric('status never became complete on the first-parent history of HEAD') }
  else if (out.firstSeenComplete) { out.leadTime = nullMetric('first seen already complete (retroactive docs, decomposed sub-feature, or a squash merge carrying the whole flow)') }
  else if (firstSpec.sha === done.sha) { out.leadTime = nullMetric('spec.md landed in the same commit that set complete (squash merge or retroactive docs)') }
  else if (completedAt < specStart) { out.leadTime = nullMetric('spec.md was first committed after completion (documented retroactively)') }
  else { out.leadTime = { value: days(completedAt - specStart), reason: null, start: iso(specStart), end: iso(completedAt) } }

  // stage dwell
  if (!hasCommits) { out.stageDwell = nullMetric(NO_COMMITS) }
  else if (transitions.length === 0) { out.stageDwell = nullMetric('the feature never appears in a committed version of its manifest') }
  else {
    const stages = transitions.slice(0, -1).map((t, i) => ({
      status: t.status, from: iso(t.at), to: iso(transitions[i + 1].at), days: days(transitions[i + 1].at - t.at),
    }))
    const cur = transitions[transitions.length - 1]
    out.stageDwell = { value: stages, reason: null, current: { status: cur.status, since: iso(cur.at) } }
  }

  // plan deferral rate (working tree)
  out.deferralRate = deferralRate(dir)

  // conformance first-time pass
  const confRel = `${featuresRel}/${feature.id}/conformance-report.md`
  if (!hasCommits) { out.firstTimePass = nullMetric(NO_COMMITS) }
  else {
    const confLog = followLog(confRel).reverse()
    if (confLog.length === 0) {
      out.firstTimePass = nullMetric(isFile(join(dir, 'conformance-report.md')) ? 'conformance-report.md exists but was never committed' : 'no conformance-report.md in history')
    } else {
      const specs = confLog.map(r => `${r.sha}:${recordPath(r) ?? confRel}`)
      const blobs = readBlobs(specs)
      // A version whose blob is gone (the file's deletion) has no text.
      const texts = specs.map(sp => blobs.get(sp)).filter(t => typeof t === 'string')
      out.firstTimePass = firstTimePass(texts)
    }
  }

  // rework rate
  const techSpec = readText(join(dir, 'tech-spec.md'))
  const inventory = techSpec ? inventoryPaths(techSpec) : []
  if (!hasCommits) { out.reworkRate = nullMetric(NO_COMMITS) }
  else if (completedAt === null) { out.reworkRate = nullMetric('status never became complete') }
  else if (techSpec === null) { out.reworkRate = nullMetric('no tech-spec.md') }
  else if (inventory.length === 0) { out.reworkRate = nullMetric('tech-spec.md has no File Inventory paths') }
  else if (completedAt + WINDOW_DAYS * DAY > nowTs) {
    out.reworkRate = nullMetric(`the ${WINDOW_DAYS}-day window is still open (closes ${iso(completedAt + WINDOW_DAYS * DAY)})`, { paths: inventory })
  } else {
    const end = completedAt + WINDOW_DAYS * DAY
    const inWindow = logRecords(['--no-merges', '--', ...inventory]).filter(c => c.ct > completedAt && c.ct <= end)
    const fixes = inWindow.filter(c => isFix(c.subject))
    const detail = { fix: fixes.length, total: inWindow.length, windowEnd: iso(end), paths: inventory, fixCommits: fixes.map(c => `${c.sha.slice(0, 12)} ${c.subject}`) }
    out.reworkRate = inWindow.length === 0
      ? nullMetric('no commits touched the File Inventory paths in the window', detail)
      : { value: round(fixes.length / inWindow.length, 4), reason: null, ...detail }
  }

  // spec churn
  if (!hasCommits) { out.specChurn = nullMetric(NO_COMMITS) }
  else if (completedAt === null) { out.specChurn = nullMetric('status never became complete') }
  else {
    const chron = [...specLog].reverse().filter(r => (r.files[r.files.length - 1]?.[0] ?? '') !== 'D')
    const specs = chron.map(r => `${r.sha}:${recordPath(r) ?? specRel}`)
    const blobs = readBlobs(specs)
    let prev = null
    let bumps = 0
    let seenVersion = false
    chron.forEach((r, i) => {
      const v = Number(frontmatterField(blobs.get(specs[i]), 'spec_version'))
      if (!Number.isFinite(v)) { return }
      seenVersion = true
      if (prev !== null && v > prev && r.ct > completedAt) { bumps++ }
      prev = v
    })
    out.specChurn = seenVersion ? { value: bumps, reason: null } : nullMetric('spec.md never carried a numeric spec_version')
  }
  return out
}

// ───────────────────────── run ──────────────────────────

let results = selected.map(compute)
if (sinceTs !== null) { results = results.filter(r => r.sortKey !== null && r.sortKey >= sinceTs) }
for (const r of results) { delete r.sortKey }

const aggregate = aggregateOf(results)

if (jsonMode) {
  stdout.write(JSON.stringify({
    aiDir: relative(cwdAbs, aiDir) || '.',
    head: hasCommits ? git(['rev-parse', 'HEAD'])?.trim() ?? null : null,
    filters: { feature: onlyFeature, since: args.since ?? null },
    assumptions: {
      fixPattern: fixRegexes.map(r => r.source),
      fixPatternSource,
      fixMatch: 'commit subject, case-insensitive',
      windowDays: WINDOW_DAYS,
      completeStatuses: [...DONE_STATUSES],
    },
    definitions: DEFINITIONS,
    aggregate,
    features: results,
  }, null, 2) + '\n')
  exit(0)
}

printReport()
exit(0)

// ───────────────────────── aggregate ────────────────────

function aggregateOf(rs) {
  const lead = rs.map(r => r.leadTime.value).filter(v => v !== null).sort((a, b) => a - b)
  const dwell = {}
  for (const r of rs) {
    for (const s of r.stageDwell.value ?? []) { (dwell[s.status] ??= []).push(s.days) }
  }
  const def = rs.filter(r => r.deferralRate.value !== null)
  const defD = sumOf(def, r => r.deferralRate.deferred)
  const defC = sumOf(def, r => r.deferralRate.checked)
  const ftp = rs.filter(r => r.firstTimePass.value !== null)
  const rw = rs.filter(r => r.reworkRate.value !== null)
  const rwFix = sumOf(rw, r => r.reworkRate.fix)
  const rwAll = sumOf(rw, r => r.reworkRate.total)
  const churn = rs.filter(r => r.specChurn.value !== null)
  const firstSeen = rs.filter(r => r.firstSeenComplete).length
  const openOnComplete = sumOf(rs.filter(r => DONE_STATUSES.has(r.status) && r.deferralRate.open !== undefined), r => r.deferralRate.open)
  return {
    features: rs.length,
    leadTime: lead.length === 0 ? nullMetric('no feature has a lead time', { firstSeenComplete: firstSeen })
      : { median: median(lead), p85: lead[Math.ceil(0.85 * lead.length) - 1], n: lead.length, firstSeenComplete: firstSeen },
    stageDwell: Object.fromEntries(Object.entries(dwell).sort().map(([k, v]) => [k, { median: median(v.sort((a, b) => a - b)), n: v.length }])),
    deferralRate: def.length === 0 ? nullMetric('no feature has checked or deferred tasks', { openOnComplete })
      : { value: round(defD / (defD + defC), 4), deferred: defD, checked: defC, openOnComplete, n: def.length },
    firstTimePass: ftp.length === 0 ? nullMetric('no feature has a decisive conformance verdict')
      : firstTimePassAggregate(ftp),
    reworkRate: rw.length === 0 ? nullMetric('no feature has a closed rework window with commits in it')
      : { value: round(rwFix / rwAll, 4), fix: rwFix, total: rwAll, n: rw.length },
    specChurn: churn.length === 0 ? nullMetric('no complete feature with a spec_version history')
      : { bumps: sumOf(churn, r => r.specChurn.value), featuresWithBumps: churn.filter(r => r.specChurn.value > 0).length, n: churn.length },
  }
}

function firstTimePassAggregate(ftp) {
  const passed = ftp.filter(r => r.firstTimePass.value).length
  const fromVersions = ftp.filter(r => r.firstTimePass.basis === VERSIONS).length
  return {
    value: round(passed / ftp.length, 4), passed, n: ftp.length,
    fromHistory: ftp.length - fromVersions, fromCommittedVersions: fromVersions,
    basis: fromVersions === 0
      ? 'every value from a verdict history'
      : `${fromVersions} of ${ftp.length} from committed report versions only, a lower bound on failures for those`,
  }
}

// ───────────────────────── text report ──────────────────

function printReport() {
  const a = aggregate
  out('')
  out('Delivery Metrics')
  out('='.repeat(40))
  out(`ai dir:       ${relative(cwdAbs, aiDir) || '.'}`)
  out(`features:     ${results.length}${onlyFeature ? ` (--feature=${onlyFeature})` : ''}${args.since ? ` (--since=${args.since})` : ''}`)
  out(`fix pattern:  ${fixRegexes.map(r => r.source).join(' | ')}`)
  out(`              ${fixPatternSource}`)
  if (!hasCommits) { out(`history:      ${NO_COMMITS} — history-based metrics are null`) }
  out('')

  if (results.length > 0) {
    // Ids are never truncated: two long ids sharing a prefix would print as
    // the same row.
    const idW = Math.max('Feature'.length, ...results.map(r => r.id.length)) + 2
    const stW = Math.max('Status'.length, ...results.map(r => r.status.length)) + 2
    out(pad('Feature', idW) + pad('Status', stW) + pad('Lead(d)', 9) + pad('Deferral', 14) + pad('Open', 6) + pad('1st pass', 10) + pad('Rework', 14) + 'Churn')
    out('-'.repeat(idW + stW + 58))
    for (const r of results) {
      out(pad(r.id, idW) + pad(r.status, stW)
        + pad(fmt(r.leadTime.value), 9)
        + pad(r.deferralRate.value === null ? '-' : `${r.deferralRate.deferred}/${r.deferralRate.checked + r.deferralRate.deferred} ${pct(r.deferralRate.value)}`, 14)
        + pad(DONE_STATUSES.has(r.status) && r.deferralRate.open !== undefined ? r.deferralRate.open : '-', 6)
        + pad(r.firstTimePass.value === null ? '-' : (r.firstTimePass.value ? 'yes' : 'no'), 10)
        + pad(r.reworkRate.value === null ? '-' : `${r.reworkRate.fix}/${r.reworkRate.total} ${pct(r.reworkRate.value)}`, 14)
        + fmt(r.specChurn.value))
    }
    out('')
    out('Stage dwell (days)')
    for (const r of results) {
      const d = r.stageDwell
      if (d.value === null) { out(`  ${r.id}: -`); continue }
      const parts = d.value.map(s => `${s.status} ${s.days}`)
      parts.push(`${d.current.status} (since ${d.current.since.slice(0, 10)})`)
      out(`  ${r.id}: ${parts.join(' -> ')}`)
    }
    out('')
  }

  out('Aggregate')
  out(`  lead time:        ${a.leadTime.median === undefined ? `- (${a.leadTime.reason})` : `median ${a.leadTime.median}d, P85 ${a.leadTime.p85}d (n=${a.leadTime.n})`}${a.leadTime.firstSeenComplete > 0 ? `; ${a.leadTime.firstSeenComplete} first seen already complete, excluded` : ''}`)
  const dw = Object.entries(a.stageDwell).map(([k, v]) => `${k} ${v.median}d (n=${v.n})`)
  out(`  stage dwell:      ${dw.length === 0 ? '-' : `median ${dw.join(', ')}`}`)
  out(`  deferral rate:    ${a.deferralRate.value == null ? `- (${a.deferralRate.reason})` : `${pct(a.deferralRate.value)} (${a.deferralRate.deferred}/${a.deferralRate.deferred + a.deferralRate.checked}, n=${a.deferralRate.n})`}${a.deferralRate.openOnComplete > 0 ? `; ${a.deferralRate.openOnComplete} task(s) left open on complete features, not in the rate` : ''}`)
  out(`  first-time pass:  ${a.firstTimePass.value == null ? `- (${a.firstTimePass.reason})` : `${pct(a.firstTimePass.value)} (${a.firstTimePass.passed}/${a.firstTimePass.n}) — ${a.firstTimePass.basis}`}`)
  out(`  rework rate:      ${a.reworkRate.value == null ? `- (${a.reworkRate.reason})` : `${pct(a.reworkRate.value)} (${a.reworkRate.fix}/${a.reworkRate.total}, n=${a.reworkRate.n})`}`)
  out(`  spec churn:       ${a.specChurn.bumps === undefined ? `- (${a.specChurn.reason})` : `${a.specChurn.bumps} bump(s) across ${a.specChurn.featuresWithBumps} of ${a.specChurn.n} complete feature(s)`}`)
  out('')

  const reasons = []
  for (const r of results) {
    for (const [k, label] of [['leadTime', 'lead time'], ['stageDwell', 'stage dwell'], ['deferralRate', 'deferral'], ['firstTimePass', '1st pass'], ['reworkRate', 'rework'], ['specChurn', 'churn']]) {
      if (r[k].value === null) { reasons.push(`  ${r.id} ${label}: ${r[k].reason}`) }
    }
  }
  if (reasons.length > 0) {
    out('Not computed (null)')
    for (const l of reasons) { out(l) }
    out('')
  }

  out('Definitions')
  for (const [k, v] of Object.entries(DEFINITIONS)) { out(`  ${k}: ${v}`) }
  out('')
}

// ───────────────────────── helpers ──────────────────────

function isFile(p) { try { return statSync(p).isFile() } catch { return false } }
function isDir(p) { try { return statSync(p).isDirectory() } catch { return false } }
function readText(p) { try { return readFileSync(p, 'utf8') } catch { return null } }
function iso(ts) { return ts === null || ts === undefined ? null : new Date(ts * 1000).toISOString().replace('.000Z', 'Z') }
function days(sec) { return round(sec / DAY, 1) }
function round(n, d) { const f = 10 ** d; return Math.round(n * f) / f }
function median(sorted) {
  const n = sorted.length
  return n % 2 === 1 ? sorted[(n - 1) / 2] : round((sorted[n / 2 - 1] + sorted[n / 2]) / 2, 1)
}
function sumOf(xs, f) { return xs.reduce((s, x) => s + f(x), 0) }
function pct(v) { return `${Math.round(v * 100)}%` }
function fmt(v) { return v === null || v === undefined ? '-' : String(v) }
function pad(s, n) {
  const str = String(s ?? '')
  return str.length >= n ? str.slice(0, n - 1) + ' ' : str + ' '.repeat(n - str.length)
}
function out(s) { stdout.write(s + '\n') }
function fail(msg) {
  stderr.write(`delivery-metrics: ${msg}\n`)
  exit(3)
}
