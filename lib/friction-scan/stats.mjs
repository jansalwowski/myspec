#!/usr/bin/env node
// stats: summarise the field metrics friction-scan --emit recorded in
// <main checkout>/.claude/state/metrics/runs.jsonl. Read-only. No model calls.
//
// Usage:
//   node stats.mjs [--since=30d] [--json] [--file=<runs.jsonl>]
//
// --since takes <n>h, <n>d or <n>w, or an ISO date; default 30d. `all` reads
// everything. A record counts when its window ended inside the range.
//
// Per skill: runs, median and p90 active time, median input and output
// tokens, runs in which a subagent returned BLOCKED or PROBES_BLOCKED, fix
// rounds and hook blocks. Then sessions overall and the hook blocks that
// fired most, counted from session records so nested skill windows do not
// count one block twice.
//
// Exit codes: 0 summarised (or nothing recorded yet); 1 usage error.

import { readFileSync, existsSync } from 'node:fs'
import { resolve, relative, isAbsolute } from 'node:path'
import { argv, stdout, stderr, exit } from 'node:process'
import { projectRoot } from './scan.mjs'
import { mainRoot, defaultRunsPath, metricsDisabled } from './metrics.mjs'

const BLOCKED = ['BLOCKED', 'PROBES_BLOCKED']

export function parseSince(value, now = Date.now()) {
  if (value === undefined || value === true) { value = '30d' }
  if (value === 'all') { return null }
  const m = String(value).match(/^(\d+)([hdw])$/)
  if (m) { return now - Number(m[1]) * { h: 3600e3, d: 86400e3, w: 7 * 86400e3 }[m[2]] }
  const t = Date.parse(String(value))
  if (Number.isNaN(t)) { throw new Error(`--since: expected <n>h, <n>d, <n>w, an ISO date or "all", got ${value}`) }
  return t
}

// Latest record per id: a resumed session re-emits its growing windows under
// the same id with a later end.
export function readRecords(path) {
  const byId = new Map()
  let unreadable = 0
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (!line.trim()) { continue }
    let r
    try { r = JSON.parse(line) } catch { unreadable++; continue }
    if (!r || typeof r.id !== 'string' || typeof r.end !== 'string') { unreadable++; continue }
    const prev = byId.get(r.id)
    if (!prev || prev.end < r.end) { byId.set(r.id, r) }
  }
  return { records: [...byId.values()], unreadable }
}

export function percentile(values, p) {
  if (!values.length) { return null }
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.max(0, Math.ceil((p / 100) * sorted.length) - 1)]
}

const tokensIn = (t) => (t?.in ?? 0) + (t?.cache_read ?? 0) + (t?.cache_write ?? 0)
const sum = (o) => Object.values(o ?? {}).reduce((n, v) => n + (Number(v) || 0), 0)

export function summarise(records, since) {
  const inRange = records.filter((r) => since === null || Date.parse(r.end) >= since)
  const skills = new Map()
  for (const r of inRange.filter((x) => x.kind === 'skill')) {
    const name = r.skill ?? '?'
    if (!skills.has(name)) { skills.set(name, []) }
    skills.get(name).push(r)
  }
  const skillRows = [...skills].map(([skill, runs]) => {
    const blocked = runs.filter((r) => BLOCKED.some((s) => (r.subagent_status?.[s] ?? 0) > 0)).length
    return {
      skill,
      runs: runs.length,
      active_ms: { p50: percentile(runs.map((r) => r.active_ms ?? 0), 50), p90: percentile(runs.map((r) => r.active_ms ?? 0), 90) },
      tokens_in_p50: percentile(runs.map((r) => tokensIn(r.tokens)), 50),
      tokens_out_p50: percentile(runs.map((r) => r.tokens?.out ?? 0), 50),
      blocked_runs: blocked,
      blocked_rate: runs.length ? blocked / runs.length : 0,
      fix_rounds: runs.reduce((n, r) => n + (r.fix_rounds ?? 0), 0),
      hook_blocks: runs.reduce((n, r) => n + sum(r.hook_blocks), 0),
    }
  }).sort((a, b) => b.runs - a.runs || a.skill.localeCompare(b.skill))

  const sessions = inRange.filter((r) => r.kind === 'session')
  const blocks = {}
  for (const s of sessions) {
    for (const [k, v] of Object.entries(s.hook_blocks ?? {})) { blocks[k] = (blocks[k] ?? 0) + v }
  }
  return {
    since: since === null ? null : new Date(since).toISOString(),
    sessions: {
      count: sessions.length,
      active_ms_p50: percentile(sessions.map((s) => s.active_ms ?? 0), 50),
      tokens_in_p50: percentile(sessions.map((s) => tokensIn(s.tokens)), 50),
      tokens_out_p50: percentile(sessions.map((s) => s.tokens?.out ?? 0), 50),
      fix_rounds: sessions.reduce((n, s) => n + (s.fix_rounds ?? 0), 0),
    },
    skills: skillRows,
    hook_blocks: Object.entries(blocks).map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)),
  }
}

function dur(ms) {
  if (ms === null) { return '-' }
  if (ms < 60000) { return `${Math.round(ms / 1000)}s` }
  const m = Math.round(ms / 60000)
  return m >= 60 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m` : `${m}m`
}

function num(n) {
  if (n === null) { return '-' }
  if (n >= 1e6) { return `${(n / 1e6).toFixed(1)}M` }
  if (n >= 1e3) { return `${Math.round(n / 1e3)}k` }
  return String(n)
}

export function renderText(summary, file) {
  const lines = []
  const range = summary.since ? `since ${summary.since.slice(0, 10)}` : 'all time'
  const runs = summary.skills.reduce((n, s) => n + s.runs, 0)
  lines.push(`myspec field metrics, ${range}: ${summary.sessions.count} sessions, ${runs} skill runs (${file})`)
  if (!summary.sessions.count && !runs) { return lines.join('\n') + '\n' }
  lines.push('')
  lines.push(`Sessions: active p50 ${dur(summary.sessions.active_ms_p50)}, tokens p50 ${num(summary.sessions.tokens_in_p50)} in / ${num(summary.sessions.tokens_out_p50)} out, ${summary.sessions.fix_rounds} fix rounds`)
  if (summary.skills.length) {
    lines.push('')
    lines.push('| Skill | Runs | Active p50 | Active p90 | Tokens in p50 | Tokens out p50 | Blocked | Fix rounds | Hook blocks |')
    lines.push('|---|---|---|---|---|---|---|---|---|')
    for (const s of summary.skills) {
      lines.push(`| ${s.skill} | ${s.runs} | ${dur(s.active_ms.p50)} | ${dur(s.active_ms.p90)} | ${num(s.tokens_in_p50)} | ${num(s.tokens_out_p50)} | ${s.blocked_runs}/${s.runs} | ${s.fix_rounds} | ${s.hook_blocks} |`)
    }
  }
  if (summary.hook_blocks.length) {
    lines.push('')
    lines.push(`Hook blocks: ${summary.hook_blocks.slice(0, 5).map((b) => `${b.name} ${b.count}`).join(', ')}`)
  }
  return lines.join('\n') + '\n'
}

function main() {
  const args = {}
  for (const raw of argv.slice(2)) {
    if (!raw.startsWith('--')) { continue }
    const i = raw.indexOf('=')
    args[i === -1 ? raw.slice(2) : raw.slice(2, i)] = i === -1 ? true : raw.slice(i + 1)
  }
  let since
  try { since = parseSince(args.since) } catch (err) { stderr.write(`stats: ${err.message}\n`); exit(1) }

  const here = projectRoot()
  const root = mainRoot(here)
  const file = typeof args.file === 'string' ? resolve(args.file) : defaultRunsPath(root)
  // Shown repo-relative when it sits in the checkout, so the output pastes cleanly.
  const rel = relative(root, file)
  const shown = rel && !rel.startsWith('..') && !isAbsolute(rel) ? rel : file
  const off = metricsDisabled(here) ?? metricsDisabled(root)
  const json = args.json === true

  if (!existsSync(file)) {
    if (json) { stdout.write(JSON.stringify({ file, recording: off ? `off (${off})` : 'on', records: 0 }) + '\n'); return }
    stdout.write(`No field metrics recorded yet (${shown}). ${off ? `Recording is off: ${off}.` : 'The SessionEnd hook records one line per skill run and session.'}\n`)
    return
  }
  const { records, unreadable } = readRecords(file)
  const summary = summarise(records, since)
  if (json) {
    stdout.write(JSON.stringify({ file, recording: off ? `off (${off})` : 'on', unreadable, ...summary }, null, 2) + '\n')
    return
  }
  let out = renderText(summary, shown)
  if (unreadable) { out += `\n${unreadable} unreadable line(s) skipped.\n` }
  if (off) { out += `\nRecording is off: ${off}.\n` }
  stdout.write(out)
}

if (import.meta.url === `file://${argv[1]}` || argv[1]?.endsWith('/stats.mjs')) { main() }
